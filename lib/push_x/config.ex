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
      get(:fcm_credentials) != nil
  end

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
