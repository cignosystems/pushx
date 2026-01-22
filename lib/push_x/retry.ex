defmodule PushX.Retry do
  @moduledoc """
  Retry logic for push notification delivery following Apple and Google best practices.

  ## Retry Strategy

  Based on official Apple APNS and Google FCM documentation:

  - **Connection errors**: Retry with exponential backoff (10s, 20s, 40s)
  - **Server errors (5xx)**: Retry with exponential backoff
  - **Rate limited (429)**: Respect `retry-after` header, or default to 60 seconds
  - **Permanent failures**: Do not retry (bad token, payload too large, etc.)

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

  alias PushX.{Config, Response, Telemetry}

  @default_rate_limit_delay_ms 60_000

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
      max_attempts = Keyword.get(opts, :max_attempts, config_max_attempts())
      base_delay = Keyword.get(opts, :base_delay_ms, config_base_delay())
      max_delay = Keyword.get(opts, :max_delay_ms, config_max_delay())

      do_retry(fun, 1, max_attempts, base_delay, max_delay)
    else
      fun.()
    end
  end

  defp do_retry(fun, attempt, max_attempts, base_delay, max_delay) do
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
            delay = calculate_delay(response, attempt, base_delay, max_delay)

            Logger.info(
              "[PushX.Retry] Attempt #{attempt}/#{max_attempts} failed for #{response.provider} " <>
                "(#{response.status}), retrying in #{delay}ms"
            )

            Telemetry.retry_attempt(response.provider, response.status, attempt, delay)
            Process.sleep(delay)
            do_retry(fun, attempt + 1, max_attempts, base_delay, max_delay)
        end
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
  def retryable?(%Response{status: status}) do
    status in [:connection_error, :rate_limited, :server_error]
  end

  @doc """
  Calculates the delay before the next retry attempt.

  - For rate limiting: Uses retry_after value or 60 seconds default
  - For other errors: Exponential backoff with jitter

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

  def calculate_delay(_response, attempt, base_delay, max_delay) do
    # Exponential backoff: base * 2^(attempt-1)
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
