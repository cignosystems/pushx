defmodule PushX.Retry do
  @moduledoc """
  Retry logic for push notification delivery following Apple and Google best practices.

  ## Retry Strategy

  Based on official Apple APNS and Google FCM documentation:

  - **Connection errors**: Retry with exponential backoff (10s, 20s, 40s)
  - **Server errors (5xx)**: Retry with exponential backoff
  - **Rate limited (429)**: Respect `retry-after` header, or default to 60 seconds
  - **Permanent failures**: Do not retry (bad token, payload too large, etc.)

  Backoff runs **in the calling process** via `Process.sleep/1` — a single
  send can block its caller for the sum of all retry delays (tens of
  seconds with default config). Inside `push_batch/4` this competes with
  the per-task `:timeout`; see the batch docs for sizing guidance.

  ## Configuration

      config :pushx,
        retry_enabled: true,
        retry_max_attempts: 3,
        retry_base_delay_ms: 10_000,  # 10 seconds (Google recommends minimum 10s)
        retry_max_delay_ms: 60_000    # 60 seconds max

  ## References

  - Apple: https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server
  - Google: https://firebase.google.com/docs/cloud-messaging/scale-fcm
  """

  require Logger

  alias PushX.{Config, ReconnectGuard, Response, Telemetry}

  @default_rate_limit_delay_ms 60_000

  @doc """
  Runs `fun` under the retry policy selected by the caller's `:retry` option.

  Every send function accepts `retry: :blocking | :none` (default `:blocking`):

    * `:blocking` — `with_retry/2`: retryable failures are retried in the
      calling process with backoff (subject to the `:retry_enabled` config).
    * `:none` — a single attempt; retryable failures are returned as-is with
      `retry_after` set when the provider supplied it, so the caller can
      requeue on its own schedule. Useful for large batches, where a blocking
      backoff would otherwise hold a concurrency slot for up to a minute. A
      `:connection_error` still triggers the (coalesced) automatic pool
      reconnect, exactly as the first retry of the blocking path would — only
      the retry itself is skipped.

  `true` / `false` are accepted as aliases for `:blocking` / `:none` (older
  docs described the option as a boolean). Any other value returns
  `{:error, %Response{status: :invalid_request}}` for `provider` without
  calling `fun`.
  """
  @spec maybe_with_retry(
          :apns | :fcm | :webpush,
          keyword(),
          (-> {:ok, Response.t()} | {:error, Response.t()}),
          keyword()
        ) :: {:ok, Response.t()} | {:error, Response.t()}
  def maybe_with_retry(provider, send_opts, fun, retry_opts \\ []) do
    # Validate the option first so a typo fails the same way in test delivery
    # mode as in production; only then does test mode (PushX.Test) replace the
    # policy with a single attempt — never sleep in a user's suite because a
    # stubbed response happened to be retryable.
    policy = Keyword.get(send_opts, :retry, :blocking)
    test_mode? = policy in [:blocking, true, :none, false] and PushX.Test.active?()

    case policy do
      _valid when test_mode? ->
        fun.()

      blocking when blocking in [:blocking, true] ->
        with_retry(fun, retry_opts)

      none when none in [:none, false] ->
        result = fun.()

        # Single attempt — but a connection error still means the pool's
        # HTTP/2 sockets are probably dead (cloud LBs drop them silently), so
        # do the coalesced pool reconnect the blocking path would have done
        # on its first retry. Nothing is retried; the error is returned as-is.
        with {:error, %Response{status: :connection_error}} <- result do
          maybe_reconnect(reconnect_opts(retry_opts))
          result
        end

      other ->
        {:error,
         Response.error(
           provider,
           :invalid_request,
           "Invalid :retry option #{inspect(other)} (expected :blocking or :none)"
         )}
    end
  end

  @doc """
  Executes a function with retry logic.

  The function should return `{:ok, response}` or `{:error, response}`.
  Retries are only attempted for retryable errors.

  ## Options

    * `:max_attempts` - Maximum number of attempts (default: 3)
    * `:base_delay_ms` - Base delay in milliseconds (default: 10_000)
    * `:max_delay_ms` - Maximum delay in milliseconds (default: 60_000)

  ## Examples

      PushX.Retry.with_retry(fn -> PushX.APNS.send_once(token, payload, opts) end)

  """
  @spec with_retry((-> {:ok, Response.t()} | {:error, Response.t()}), keyword()) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def with_retry(fun, opts \\ []) do
    if retry_enabled?() do
      retry_opts = %{
        max_attempts: Keyword.get(opts, :max_attempts, config_max_attempts()),
        base_delay: Keyword.get(opts, :base_delay_ms, config_base_delay()),
        max_delay: Keyword.get(opts, :max_delay_ms, config_max_delay()),
        reconnect_fn: Keyword.get(opts, :reconnect_fn, &PushX.reconnect/0),
        reconnect_key: Keyword.get(opts, :reconnect_key, :default)
      }

      do_retry(fun, 1, retry_opts)
    else
      fun.()
    end
  end

  defp do_retry(fun, attempt, retry_opts) do
    %{max_attempts: max_attempts, base_delay: base_delay, max_delay: max_delay} = retry_opts

    case fun.() do
      {:ok, response} ->
        {:ok, response}

      {:error, %Response{} = response} ->
        cond do
          # Don't retry permanent failures
          not retryable?(response) ->
            {:error, response}

          # Max attempts reached
          attempt >= max_attempts ->
            Logger.warning(
              "[PushX.Retry] Max attempts (#{max_attempts}) reached for #{response.provider}"
            )

            {:error, response}

          # Retry with appropriate delay
          true ->
            if response.status == :connection_error and attempt == 1 do
              maybe_reconnect(retry_opts)
            end

            delay = calculate_delay(response, attempt, base_delay, max_delay)

            Logger.info(
              "[PushX.Retry] Attempt #{attempt}/#{max_attempts} failed for #{response.provider} " <>
                "(#{response.status}), retrying in #{delay}ms"
            )

            Telemetry.retry_attempt(response.provider, response.status, attempt, delay)
            Process.sleep(delay)
            do_retry(fun, attempt + 1, retry_opts)
        end
    end
  end

  defp reconnect_opts(retry_opts) do
    %{
      reconnect_fn: Keyword.get(retry_opts, :reconnect_fn, &PushX.reconnect/0),
      reconnect_key: Keyword.get(retry_opts, :reconnect_key, :default)
    }
  end

  # On the first connection error, restart the Finch pool to discard stale
  # HTTP/2 connections — retrying on the same dead connection is futile.
  # Restarts are coalesced through PushX.ReconnectGuard: the pool is shared,
  # so N concurrent requests observing a blip must trigger at most one
  # restart per cooldown window, not N restarts that kill each other's
  # healthy in-flight requests.
  defp maybe_reconnect(%{reconnect_fn: reconnect_fn, reconnect_key: key}) do
    if ReconnectGuard.acquire(key) do
      case reconnect_fn.() do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("[PushX.Retry] Failed to reconnect HTTP pool: #{inspect(reason)}")
      end
    else
      Logger.debug(fn ->
        "[PushX.Retry] Pool #{inspect(key)} was reconnected recently; skipping"
      end)
    end
  end

  @doc """
  Returns true if the error is retryable.

  Retryable errors:
  - `:connection_error` - Network/connection failure
  - `:rate_limited` - Too many requests (with backoff)
  - `:server_error` - Provider server error (5xx)

  Non-retryable (permanent) errors:
  - `:invalid_token` - Device token is invalid
  - `:expired_token` - Device token has expired
  - `:unregistered` - Device is no longer registered
  - `:payload_too_large` - Payload exceeds size limit
  - `:unknown_error` - Unrecognized error (could be client-side issue)
  """
  @spec retryable?(Response.t()) :: boolean()
  defdelegate retryable?(response), to: Response

  # Base delay for connection errors (faster than rate limits)
  @connection_error_base_delay_ms 1_000

  @doc """
  Calculates the delay before the next retry attempt.

  - For rate limiting: Uses retry_after value or 60 seconds default
  - For connection errors: Faster retry (1s base) since these are transient
  - For server errors: Standard exponential backoff from config

  ## Exponential Backoff Formula

      delay = min(base_delay * 2^(attempt-1) + jitter, max_delay)

  """
  @spec calculate_delay(Response.t(), pos_integer(), pos_integer(), pos_integer()) ::
          pos_integer()
  def calculate_delay(
        %Response{status: :rate_limited, retry_after: retry_after},
        _attempt,
        _base,
        _max
      )
      when is_integer(retry_after) and retry_after > 0 do
    # Use the server-specified retry-after value
    retry_after * 1000
  end

  def calculate_delay(%Response{status: :rate_limited}, _attempt, _base, _max) do
    # Default rate limit delay (Google recommends 60s if no retry-after header)
    @default_rate_limit_delay_ms
  end

  def calculate_delay(%Response{status: :connection_error}, attempt, _base, max_delay) do
    # Connection errors get a faster retry (1s base instead of 10s) — they are
    # typically transient network issues, not provider throttling. "Full
    # jitter" (uniform between half and the full exponential) spreads a burst
    # of retries — e.g. every task of a batch after a pool reconnect — over
    # the window instead of landing them on the fresh connection at once and
    # saturating its stream limit.
    exponential = (@connection_error_base_delay_ms * :math.pow(2, attempt - 1)) |> round()
    half = div(exponential, 2)
    min(half + :rand.uniform(max(exponential - half, 1)), max_delay)
  end

  def calculate_delay(_response, attempt, base_delay, max_delay) do
    # Standard exponential backoff: base * 2^(attempt-1)
    exponential = (base_delay * :math.pow(2, attempt - 1)) |> round()

    # Add jitter (±10%) to prevent thundering herd
    jitter = round(exponential * 0.1 * (:rand.uniform() * 2 - 1))

    min(exponential + jitter, max_delay)
  end

  # Configuration helpers

  defp retry_enabled?, do: Config.retry_enabled?()
  defp config_max_attempts, do: Config.retry_max_attempts()
  defp config_base_delay, do: Config.retry_base_delay_ms()
  defp config_max_delay, do: Config.retry_max_delay_ms()
end
