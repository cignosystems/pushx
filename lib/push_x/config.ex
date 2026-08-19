defmodule PushX.Config do
  @moduledoc """
  Configuration management for PushX.

  ## Configuration Options

  ### APNS (Apple Push Notification Service)

    * `:apns_key_id` - The Key ID from Apple Developer Portal
    * `:apns_team_id` - Your Apple Developer Team ID
    * `:apns_private_key` - The private key, either:
      * A raw PEM string
      * `{:file, "/path/to/AuthKey.p8"}`
      * `{:system, "ENV_VAR_NAME"}`
    * `:apns_mode` - `:prod` or `:sandbox` (default: `:prod`)

  ### FCM (Firebase Cloud Messaging)

    * `:fcm_project_id` - Your Firebase project ID
    * `:fcm_credentials` - Service account credentials, either:
      * `{:file, "/path/to/service-account.json"}`
      * `{:json, "...json string..."}`
      * `{:system, "ENV_VAR_NAME"}` (expects JSON string)
    * `:fcm_token_fetcher` - *(optional, advanced)* bring your own OAuth:
      an `{module, function, args}` tuple that replaces the Goth process PushX
      would otherwise start. See `fcm_token_fetcher/0`.

  ### Testing

    * `:delivery` - `:live` (default) or `:test` — record sends locally
      instead of contacting APNS/FCM; see `PushX.Test`

  ### Finch Pool

    * `:finch_name` - Name of the Finch pool (default: `PushX.Finch`)
    * `:finch_pool_size` - Connections per pool (default: 25)
    * `:finch_pool_count` - Number of pools (default: 2)

  ### Request Timeouts

    * `:receive_timeout` - Timeout for receiving response in ms (default: `15_000`)
    * `:pool_timeout` - Timeout for acquiring connection from pool in ms (default: `5_000`)
    * `:connect_timeout` - TCP connection timeout in ms (default: `10_000`)

  ### Retry Settings

    * `:retry_enabled` - Enable automatic retry (default: `true`)
    * `:retry_max_attempts` - Maximum retry attempts (default: `3`)
    * `:retry_base_delay_ms` - Base delay in milliseconds (default: `10_000`)
    * `:retry_max_delay_ms` - Maximum delay in milliseconds (default: `60_000`)
    * `:reconnect_cooldown_ms` - Minimum time between *automatic* Finch pool
      restarts triggered by connection errors, per pool (default: `5_000`);
      see `PushX.ReconnectGuard`. Manual `PushX.reconnect/0` is not gated.

  ### Batch Sending

    * `:batch_concurrency` - Default `:concurrency` for `PushX.push_batch/4`,
      `push_batch_stream/4` and the provider `send_batch/3` functions
      (default: `50`)

  ### Circuit Breaker (opt-in)

    * `:circuit_breaker_enabled` - (default: `false`)
    * `:circuit_breaker_threshold` - consecutive failures that open the
      breaker (default: `5`)
    * `:circuit_breaker_cooldown_ms` - open → half-open delay (default: `30_000`)

    See `PushX.CircuitBreaker`.

  ### Rate Limiting (opt-in)

    * `:rate_limit_enabled` - (default: `false`)
    * `:rate_limit_apns`, `:rate_limit_fcm` - max sends per window per
      provider (default: `1_000`)
    * `:rate_limit_window_ms` - fixed window length (default: `1_000`)

    See `PushX.RateLimiter`.

  ### Token Cleanup

    * `:on_invalid_token` - `{module, function, args}` invoked asynchronously
      as `apply(module, function, [provider, token | args])` whenever a
      response says the token should be removed
      (`PushX.Response.should_remove_token?/1`); see the README's "Token
      Cleanup Callback".

  ### Internal / test-only

    * `:apns_url_override`, `:fcm_url_override` - point the real send paths at
      a local HTTP server. Used by PushX's own test suite; not for production.
      For testing *your* application use `:delivery` (`PushX.Test`) instead.

  ## Example Configuration

      config :pushx,
        apns_key_id: "ABC123DEFG",
        apns_team_id: "TEAM123456",
        apns_private_key: {:file, "priv/keys/AuthKey.p8"},
        apns_mode: :prod,
        fcm_project_id: "my-project-id",
        fcm_credentials: {:file, "priv/keys/firebase.json"}

  """

  @doc """
  Gets a configuration value.
  """
  @spec get(atom(), any()) :: any()
  def get(key, default \\ nil) do
    Application.get_env(:pushx, key, default)
  end

  @doc """
  Gets a required configuration value.
  Raises if the value is not configured.
  """
  @spec get!(atom()) :: any()
  def get!(key) do
    case get(key) do
      nil -> raise ArgumentError, "PushX configuration :#{key} is required but not set"
      value -> value
    end
  end

  @doc """
  Gets the APNS Key ID.
  """
  @spec apns_key_id() :: String.t()
  def apns_key_id, do: get!(:apns_key_id)

  @doc """
  Gets the APNS Team ID.
  """
  @spec apns_team_id() :: String.t()
  def apns_team_id, do: get!(:apns_team_id)

  @doc """
  Gets the APNS private key content.
  Supports file paths, environment variables, and raw strings.
  """
  @spec apns_private_key() :: String.t()
  def apns_private_key do
    case get!(:apns_private_key) do
      {:file, path} ->
        File.read!(path)

      {:system, env_var} ->
        System.get_env(env_var) || raise "Environment variable #{env_var} not set"

      pem when is_binary(pem) ->
        pem
    end
  end

  @doc """
  Gets the APNS mode (:prod or :sandbox).
  """
  @spec apns_mode() :: :prod | :sandbox
  def apns_mode, do: get(:apns_mode, :prod)

  @doc """
  Gets the FCM project ID.
  """
  @spec fcm_project_id() :: String.t()
  def fcm_project_id, do: get!(:fcm_project_id)

  @doc """
  Gets the FCM credentials for Goth.
  Returns a map suitable for Goth configuration.
  """
  @spec fcm_credentials() :: map() | {:file, String.t()}
  def fcm_credentials do
    case get!(:fcm_credentials) do
      {:file, path} ->
        {:file, path}

      {:json, json} ->
        JSON.decode!(json)

      {:system, env_var} ->
        System.get_env(env_var)
        |> then(fn
          nil -> raise "Environment variable #{env_var} not set"
          json -> JSON.decode!(json)
        end)

      map when is_map(map) ->
        map
    end
  end

  @doc """
  Gets the Finch pool name.
  """
  @spec finch_name() :: atom()
  def finch_name, do: get(:finch_name, PushX.Finch)

  @doc """
  Gets the Finch pool size (connections per pool).

  Default: 25 (increased from 10 in v0.6.0 to handle traffic bursts better)
  """
  @spec finch_pool_size() :: pos_integer()
  def finch_pool_size, do: get(:finch_pool_size, 25)

  @doc """
  Gets the Finch pool count (number of connection pools).

  Default: 2 (increased from 1 in v0.6.0 to handle traffic bursts better)
  """
  @spec finch_pool_count() :: pos_integer()
  def finch_pool_count, do: get(:finch_pool_count, 2)

  @doc """
  Checks if APNS is configured.
  """
  @spec apns_configured?() :: boolean()
  def apns_configured? do
    get(:apns_key_id) != nil and
      get(:apns_team_id) != nil and
      get(:apns_private_key) != nil
  end

  @doc """
  Checks if FCM is configured.
  """
  @spec fcm_configured?() :: boolean()
  def fcm_configured? do
    get(:fcm_project_id) != nil and
      (get(:fcm_credentials) != nil or get(:fcm_token_fetcher) != nil)
  end

  @doc """
  Delivery mode: `:live` (default) sends to the providers; `:test` records
  sends locally instead — see `PushX.Test`.
  """
  @spec delivery() :: :live | :test
  def delivery, do: get(:delivery, :live)

  @doc false
  # Whether Goth-style credentials are present (as opposed to a token fetcher).
  @spec fcm_credentials_configured?() :: boolean()
  def fcm_credentials_configured? do
    get(:fcm_project_id) != nil and get(:fcm_credentials) != nil
  end

  @doc """
  Returns the custom FCM OAuth token fetcher, if one is configured.

  By default PushX starts a [Goth](https://hexdocs.pm/goth) process
  (`PushX.Goth`) from `:fcm_credentials` and calls `Goth.fetch/1` before every
  FCM send. Set `:fcm_token_fetcher` to an `{module, function, args}` tuple to
  supply the OAuth access token yourself instead — for example to reuse a
  Goth process your application already runs, or to fetch tokens from a
  secrets service:

      # config/runtime.exs
      config :pushx,
        fcm_project_id: "my-project",
        fcm_token_fetcher: {MyApp.PushOAuth, :fetch, []}

      defmodule MyApp.PushOAuth do
        # PushX passes the Goth name it would have used as the first argument;
        # a fetcher that reuses your own Goth simply ignores it.
        def fetch(_goth_name), do: Goth.fetch(MyApp.Goth)
      end

  The function is invoked as `apply(module, function, [goth_name | args])`
  and must return `{:ok, %{token: access_token}}` or `{:error, reason}`. It
  runs on the send path, so keep it cheap (Goth caches; do the same). PushX
  guards the call: a fetcher that raises, exits, or returns `{:error, _}` is
  reported as a retryable `:connection_error`; one that returns any other
  shape as `:auth_error`. Neither escapes as an exception.

  When a fetcher is set, PushX starts **no** `PushX.Goth` process and
  `:fcm_credentials` becomes optional. This option applies to the **static**
  configuration only: named FCM instances (`PushX.Instance`) authenticate
  with their own `:credentials`, or their own per-instance `:token_fetcher`
  config key — a global fetcher never silently takes over a tenant's OAuth.
  The test suite uses this seam to exercise the real FCM send path without
  Google.
  """
  @spec fcm_token_fetcher() :: {module(), atom(), list()} | nil
  def fcm_token_fetcher, do: get(:fcm_token_fetcher)

  # Retry configuration

  @doc """
  Checks if retry is enabled.
  """
  @spec retry_enabled?() :: boolean()
  def retry_enabled?, do: get(:retry_enabled, true)

  @doc """
  Gets the maximum number of retry attempts.
  """
  @spec retry_max_attempts() :: pos_integer()
  def retry_max_attempts, do: get(:retry_max_attempts, 3)

  @doc """
  Gets the base delay for exponential backoff in milliseconds.
  Default: 10 seconds (Google's recommended minimum).
  """
  @spec retry_base_delay_ms() :: pos_integer()
  def retry_base_delay_ms, do: get(:retry_base_delay_ms, 10_000)

  @doc """
  Gets the maximum delay for exponential backoff in milliseconds.
  Default: 60 seconds.
  """
  @spec retry_max_delay_ms() :: pos_integer()
  def retry_max_delay_ms, do: get(:retry_max_delay_ms, 60_000)

  @batch_timeout_floor_ms 30_000
  # Rate-limited responses without a retry-after header sleep this long
  # (see PushX.Retry), which can exceed :retry_max_delay_ms.
  @rate_limit_delay_ms 60_000

  @doc """
  Default per-task timeout for batch sends, in milliseconds.

  Retries block the sending task (see `PushX.Retry`), so a batch task can
  legitimately outlive any flat timeout while it backs off between attempts.
  When retries are enabled this covers the worst-case retry budget:

      attempts × (receive_timeout + pool_timeout)
        + (attempts − 1) × max(retry_max_delay_ms, 60s rate-limit delay)

  With retries disabled — globally (`retry_enabled: false`) or for the call
  (`retry: :none`, see `batch_timeout_ms/1`) — it is 30 seconds. An explicit
  `:timeout` option on `PushX.push_batch/4` / `send_batch/3` always takes
  precedence.
  """
  @spec batch_timeout_ms() :: pos_integer()
  def batch_timeout_ms, do: batch_timeout_ms(retry: :blocking)

  @doc """
  Like `batch_timeout_ms/0`, but for a specific per-call retry policy:
  `retry: :none` means a single attempt, so the budget is the 30 s floor.
  """
  @spec batch_timeout_ms(retry: :blocking | :none) :: pos_integer()
  def batch_timeout_ms(retry: :none), do: @batch_timeout_floor_ms

  def batch_timeout_ms(retry: _blocking) do
    if retry_enabled?() do
      attempts = retry_max_attempts()
      per_attempt = receive_timeout() + pool_timeout()
      worst_delay = max(retry_max_delay_ms(), @rate_limit_delay_ms)

      max(@batch_timeout_floor_ms, attempts * per_attempt + (attempts - 1) * worst_delay)
    else
      @batch_timeout_floor_ms
    end
  end

  # Request timeout configuration

  @doc """
  Gets the overall request timeout in milliseconds.
  Default: 30 seconds.

  > Note: This value is not currently passed to Finch requests.
  > Use `:receive_timeout` and `:pool_timeout` instead.
  """
  @deprecated "Not used by Finch. Use receive_timeout/0 and pool_timeout/0 instead."
  @spec request_timeout() :: pos_integer()
  def request_timeout, do: get(:request_timeout, 30_000)

  @doc """
  Gets the receive timeout (time to wait for response data) in milliseconds.
  Default: 15 seconds.
  """
  @spec receive_timeout() :: pos_integer()
  def receive_timeout, do: get(:receive_timeout, 15_000)

  @doc """
  Gets the pool timeout (time to wait for a connection from pool) in milliseconds.
  Default: 5 seconds.
  """
  @spec pool_timeout() :: pos_integer()
  def pool_timeout, do: get(:pool_timeout, 5_000)

  @doc """
  Gets the TCP connection timeout in milliseconds.
  Default: 10 seconds.
  """
  @spec connect_timeout() :: pos_integer()
  def connect_timeout, do: get(:connect_timeout, 10_000)

  @doc """
  Returns the Finch request options with configured timeouts.
  """
  @spec finch_request_opts() :: keyword()
  def finch_request_opts do
    [
      receive_timeout: receive_timeout(),
      pool_timeout: pool_timeout()
    ]
  end

  # Circuit breaker configuration

  @doc """
  Checks if the circuit breaker is enabled.
  Default: `false` (opt-in feature).
  """
  @spec circuit_breaker_enabled?() :: boolean()
  def circuit_breaker_enabled?, do: get(:circuit_breaker_enabled, false)

  @doc """
  Gets the number of consecutive failures before the circuit opens.
  Default: 5.
  """
  @spec circuit_breaker_threshold() :: pos_integer()
  def circuit_breaker_threshold, do: get(:circuit_breaker_threshold, 5)

  @doc """
  Gets the cooldown time in milliseconds before the circuit transitions
  from `:open` to `:half_open`.
  Default: 30 seconds.
  """
  @spec circuit_breaker_cooldown_ms() :: pos_integer()
  def circuit_breaker_cooldown_ms, do: get(:circuit_breaker_cooldown_ms, 30_000)

  # Token cleanup callback

  @doc """
  Gets the callback for invalid token cleanup.

  When set, this MFA tuple is called asynchronously whenever a push
  returns `:invalid_token`, `:expired_token`, or `:unregistered`.

  The callback receives `(provider, token, ...extra_args)`.

  ## Example

      config :pushx,
        on_invalid_token: {MyApp.Push, :handle_invalid_token, []}

  """
  @spec on_invalid_token() :: {module(), atom(), list()} | nil
  def on_invalid_token, do: get(:on_invalid_token, nil)
end
