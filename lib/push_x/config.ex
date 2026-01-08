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
    * `:finch_pool_size` - Pool size per connection (default: 10)
    * `:finch_pool_count` - Number of pools (default: 1)

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
      {:file, path} -> File.read!(path)
      {:system, env_var} -> System.get_env(env_var) || raise "Environment variable #{env_var} not set"
      pem when is_binary(pem) -> pem
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
      {:file, path} -> {:file, path}
      {:json, json} -> JSON.decode!(json)
      {:system, env_var} ->
        System.get_env(env_var)
        |> then(fn
          nil -> raise "Environment variable #{env_var} not set"
          json -> JSON.decode!(json)
        end)
      map when is_map(map) -> map
    end
  end

  @doc """
  Gets the Finch pool name.
  """
  @spec finch_name() :: atom()
  def finch_name, do: get(:finch_name, PushX.Finch)

  @doc """
  Gets the Finch pool size.
  """
  @spec finch_pool_size() :: pos_integer()
  def finch_pool_size, do: get(:finch_pool_size, 10)

  @doc """
  Gets the Finch pool count.
  """
  @spec finch_pool_count() :: pos_integer()
  def finch_pool_count, do: get(:finch_pool_count, 1)

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
end
