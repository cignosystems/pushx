defmodule PushX.Instance do
  @moduledoc """
  Runtime management of named push notification instances.

  Allows starting, stopping, and reconfiguring APNS and FCM instances
  at runtime, enabling multi-provider setups from a database-backed admin panel.

  ## Usage

      # Start an APNS instance
      PushX.Instance.start(:apns_prod, :apns,
        key_id: "ABC123",
        team_id: "TEAM456",
        private_key: "-----BEGIN EC PRIVATE KEY-----\\n...",
        mode: :prod
      )

      # Start an FCM instance
      PushX.Instance.start(:my_fcm, :fcm,
        project_id: "my-project",
        credentials: %{"type" => "service_account", ...}
      )

      # Send via instance
      PushX.push(:apns_prod, token, msg, topic: "com.example.app")

      # Lifecycle management
      PushX.Instance.disable(:apns_prod)
      PushX.Instance.enable(:apns_prod)
      PushX.Instance.reconfigure(:apns_prod, mode: :sandbox)
      PushX.Instance.stop(:apns_prod)

  ## Credential Rotation Without Restart

  Use `reconfigure/2` to hot-swap credentials (e.g., after revoking an APNS
  .p8 key or rotating an FCM service account). It stops the old pool and
  starts a fresh one with new credentials. In-flight requests on the old pool
  get connection errors, which the retry logic handles automatically.

      # Load new key from database/file/env
      new_key = MyApp.Repo.get_latest_apns_key()

      PushX.Instance.reconfigure(:apns_prod,
        key_id: "NEW_KEY_ID",
        private_key: new_key
      )

  """

  require Logger

  alias PushX.{Message, Response, Retry, Telemetry}

  @table :pushx_instances
  @reserved_names [:apns, :fcm]

  @apns_prod_url "https://api.push.apple.com"
  @apns_sandbox_url "https://api.sandbox.push.apple.com"
  @fcm_base_url "https://fcm.googleapis.com/v1/projects"
  @jwt_cache_ttl_ms 50 * 60 * 1000

  # -- Lifecycle API --

  @doc """
  Starts a named instance.

  ## Arguments

    * `name` - Unique atom name for this instance (e.g., `:apns_prod`)
    * `provider` - `:apns` or `:fcm`
    * `config` - Provider-specific configuration (keyword list)

  ## APNS Config Keys

    * `:key_id` - (required) Apple Key ID
    * `:team_id` - (required) Apple Team ID
    * `:private_key` - (required) PEM string, `{:file, path}`, or `{:system, "ENV_VAR"}`
    * `:mode` - `:prod` or `:sandbox` (default: `:prod`)
    * `:pool_size` - Finch pool size (default: 2)
    * `:pool_count` - Finch pool count (default: 1)

  ## FCM Config Keys

    * `:project_id` - (required) Firebase project ID
    * `:credentials` - (required) Service account credentials map or JSON string
    * `:pool_size` - Finch pool size (default: 2)
    * `:pool_count` - Finch pool count (default: 1)

  ## Returns

    * `{:ok, name}` on success
    * `{:error, :reserved_name}` if name is `:apns` or `:fcm`
    * `{:error, :already_started}` if instance already exists
    * `{:error, {:missing_config, keys}}` if required config is missing

  """
  @spec start(atom(), :apns | :fcm, keyword()) :: {:ok, atom()} | {:error, term()}
  def start(name, provider, config)
      when is_atom(name) and provider in [:apns, :fcm] and is_list(config) do
    if name in @reserved_names do
      {:error, :reserved_name}
    else
      with :ok <- validate_config(provider, config) do
        case DynamicSupervisor.start_child(
               PushX.Instance.DynamicSupervisor,
               {PushX.Instance.Supervisor, name: name, provider: provider, config: config}
             ) do
          {:ok, _pid} -> {:ok, name}
          {:error, {:already_started, _pid}} -> {:error, :already_started}
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end

  @doc """
  Stops a named instance and cleans up all resources.
  """
  @spec stop(atom()) :: :ok | {:error, :not_found}
  def stop(name) when is_atom(name) do
    sup_name = PushX.Instance.Supervisor.sup_name(name)

    case Process.whereis(sup_name) do
      nil ->
        {:error, :not_found}

      pid ->
        DynamicSupervisor.terminate_child(PushX.Instance.DynamicSupervisor, pid)
    end
  end

  @doc """
  Stops and restarts an instance with updated config.

  Merges `new_config` into the existing config. Use this to hot-swap
  credentials (e.g., after revoking an APNS .p8 key) without restarting
  the application. The old Finch pool is terminated and a new one starts
  with fresh connections. In-flight requests on the old pool receive
  connection errors, which the retry logic handles automatically.

  ## Examples

      # Rotate APNS key
      PushX.Instance.reconfigure(:apns_prod,
        key_id: "NEW_KEY_ID",
        private_key: new_pem_string
      )

      # Switch APNS environment
      PushX.Instance.reconfigure(:apns_prod, mode: :sandbox)

  """
  @spec reconfigure(atom(), keyword()) :: {:ok, atom()} | {:error, term()}
  def reconfigure(name, new_config) when is_atom(name) and is_list(new_config) do
    case lookup(name) do
      {:ok, info} ->
        provider = info.provider
        merged = Keyword.merge(info.config, new_config)

        with :ok <- stop(name) do
          start(name, provider, merged)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Disables an instance. New pushes are rejected, but the pool stays warm.
  """
  @spec disable(atom()) :: :ok | {:error, :not_found}
  def disable(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] ->
        :ets.insert(@table, {name, %{info | enabled: false}})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Re-enables a disabled instance.
  """
  @spec enable(atom()) :: :ok | {:error, :not_found}
  def enable(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] ->
        :ets.insert(@table, {name, %{info | enabled: true}})
        :ok

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Returns the status of a named instance.
  """
  @spec status(atom()) :: {:ok, map()} | {:error, :not_found}
  def status(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] ->
        {:ok, %{provider: info.provider, enabled: info.enabled}}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Lists all running instances.
  """
  @spec list() :: [map()]
  def list do
    :ets.tab2list(@table)
    |> Enum.map(fn {name, info} ->
      %{name: name, provider: info.provider, enabled: info.enabled}
    end)
  end

  @doc """
  Resolves an instance name to its info for sending.

  Returns `{:error, :disabled}` if the instance exists but is disabled,
  `{:error, :not_found}` if it doesn't exist.
  """
  @spec resolve(atom()) :: {:ok, map()} | {:error, :not_found | :disabled}
  def resolve(name) do
    case :ets.lookup(@table, name) do
      [{^name, %{enabled: false}}] ->
        {:error, :disabled}

      [{^name, info}] ->
        {:ok, Map.put(info, :name, name)}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Restarts the Finch HTTP pool for a named instance.
  """
  @spec reconnect(atom()) :: :ok | {:error, term()}
  def reconnect(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] ->
        sup_name = PushX.Instance.Supervisor.sup_name(name)

        with :ok <- Supervisor.terminate_child(sup_name, info.finch_name),
             {:ok, _pid} <- Supervisor.restart_child(sup_name, info.finch_name) do
          Logger.info("[PushX.Instance] Reconnected #{name} HTTP pools")
          :ok
        else
          {:error, :running} ->
            :ok

          {:error, reason} ->
            Logger.error("[PushX.Instance] Failed to reconnect #{name}: #{inspect(reason)}")
            {:error, reason}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # -- Send --

  @doc false
  def send(instance_info, device_token, payload, opts) do
    case instance_info.provider do
      :apns -> apns_send(instance_info, device_token, payload, opts)
      :fcm -> fcm_send(instance_info, device_token, payload, opts)
    end
  end

  # -- APNS Send --

  defp apns_send(info, device_token, payload, opts) do
    name = info.name

    Retry.with_retry(
      fn -> apns_send_once(info, device_token, payload, opts) end,
      reconnect_fn: fn -> reconnect(name) end
    )
  end

  defp apns_send_once(info, device_token, payload, opts) do
    case Keyword.get(opts, :topic) do
      nil ->
        {:error, Response.error(:apns, :invalid_request, ":topic option is required")}

      topic ->
        case get_instance_jwt(info) do
          {:ok, jwt} ->
            do_apns_send(info, device_token, payload, opts, topic, jwt)

          {:error, reason} ->
            {:error, Response.error(:apns, :auth_error, reason)}
        end
    end
  end

  defp do_apns_send(info, device_token, payload, opts, topic, jwt) do
    mode = Keyword.get(opts, :mode, Keyword.get(info.config, :mode, :prod))

    url = "#{apns_base_url(mode)}/3/device/#{device_token}"

    headers =
      [
        {"authorization", "bearer #{jwt}"},
        {"apns-topic", topic},
        {"apns-push-type", Keyword.get(opts, :push_type, "alert")},
        {"apns-priority", to_string(Keyword.get(opts, :priority, 10))}
      ]
      |> maybe_add_header("apns-expiration", Keyword.get(opts, :expiration))
      |> maybe_add_header("apns-collapse-id", Keyword.get(opts, :collapse_id))

    body = encode_apns_payload(payload)

    Telemetry.start(:apns, device_token)
    start_time = System.monotonic_time()

    request_opts = [
      receive_timeout: Keyword.get(info.config, :receive_timeout, 15_000),
      pool_timeout: Keyword.get(info.config, :pool_timeout, 5_000)
    ]

    case Finch.build(:post, url, headers, body)
         |> Finch.request(info.finch_name, request_opts) do
      {:ok, %{status: 200, headers: resp_headers}} ->
        apns_id = get_header(resp_headers, "apns-id")
        response = Response.success(:apns, apns_id)
        Telemetry.stop(:apns, device_token, start_time, response)
        {:ok, response}

      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        {:error, response} = handle_apns_error(status, resp_body, resp_headers)
        Telemetry.error(:apns, device_token, start_time, response)
        {:error, response}

      {:error, reason} ->
        Logger.error("[PushX.Instance] APNS connection error: #{inspect(reason)}")
        response = Response.error(:apns, :connection_error, inspect(reason))
        Telemetry.error(:apns, device_token, start_time, response)
        {:error, response}
    end
  end

  # -- FCM Send --

  defp fcm_send(info, device_token, payload, opts) do
    name = info.name

    Retry.with_retry(
      fn -> fcm_send_once(info, device_token, payload, opts) end,
      reconnect_fn: fn -> reconnect(name) end
    )
  end

  defp fcm_send_once(info, device_token, payload, opts) do
    case Goth.fetch(info.goth_name) do
      {:ok, %{token: access_token}} ->
        fcm_send_with_token(info, device_token, payload, opts, access_token)

      {:error, reason} ->
        Logger.error("[PushX.Instance] FCM OAuth token error: #{inspect(reason)}")
        {:error, Response.error(:fcm, :connection_error, "OAuth token error: #{inspect(reason)}")}
    end
  end

  defp fcm_send_with_token(info, device_token, payload, opts, access_token) do
    project_id = Keyword.fetch!(info.config, :project_id)
    url = "#{@fcm_base_url}/#{project_id}/messages:send"

    message = build_fcm_message(device_token, payload, opts)

    headers = [
      {"authorization", "Bearer #{access_token}"},
      {"content-type", "application/json"}
    ]

    body = JSON.encode!(message)

    Telemetry.start(:fcm, device_token)
    start_time = System.monotonic_time()

    request_opts = [
      receive_timeout: Keyword.get(info.config, :receive_timeout, 15_000),
      pool_timeout: Keyword.get(info.config, :pool_timeout, 5_000)
    ]

    case Finch.build(:post, url, headers, body)
         |> Finch.request(info.finch_name, request_opts) do
      {:ok, %{status: 200, body: resp_body}} ->
        response =
          case JSON.decode(resp_body) do
            {:ok, %{"name" => message_id}} -> Response.success(:fcm, message_id)
            _ -> Response.success(:fcm)
          end

        Telemetry.stop(:fcm, device_token, start_time, response)
        {:ok, response}

      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        {:error, response} = handle_fcm_error(status, resp_body, resp_headers)
        Telemetry.error(:fcm, device_token, start_time, response)
        {:error, response}

      {:error, reason} ->
        Logger.error("[PushX.Instance] FCM connection error: #{inspect(reason)}")
        response = Response.error(:fcm, :connection_error, inspect(reason))
        Telemetry.error(:fcm, device_token, start_time, response)
        {:error, response}
    end
  end

  # -- Private Helpers --

  defp lookup(name) do
    case :ets.lookup(@table, name) do
      [{^name, info}] -> {:ok, Map.put(info, :name, name)}
      [] -> {:error, :not_found}
    end
  end

  defp validate_config(:apns, config) do
    required = [:key_id, :team_id, :private_key]
    missing = Enum.reject(required, &Keyword.has_key?(config, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_config, keys}}
    end
  end

  defp validate_config(:fcm, config) do
    required = [:project_id, :credentials]
    missing = Enum.reject(required, &Keyword.has_key?(config, &1))

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_config, keys}}
    end
  end

  defp apns_base_url(:prod), do: @apns_prod_url
  defp apns_base_url(:sandbox), do: @apns_sandbox_url

  defp encode_apns_payload(%Message{} = message),
    do: JSON.encode!(Message.to_apns_payload(message))

  defp encode_apns_payload(payload) when is_map(payload), do: JSON.encode!(payload)

  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, key, value), do: [{key, to_string(value)} | headers]

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp handle_apns_error(status, body, response_headers) do
    reason =
      case JSON.decode(body) do
        {:ok, %{"reason" => reason}} -> reason
        _ -> "HTTP #{status}"
      end

    error_status = Response.apns_reason_to_status(reason)
    retry_after = parse_retry_after(response_headers)

    {:error, Response.error(:apns, error_status, reason, body, retry_after)}
  end

  defp handle_fcm_error(status, body, response_headers) do
    {error_code, error_message} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{"status" => code, "message" => msg}}} ->
          {code, msg}

        {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
          {to_string(code), msg}

        _ ->
          {"UNKNOWN", "HTTP #{status}"}
      end

    error_status = Response.fcm_error_to_status(error_code)
    retry_after = parse_retry_after(response_headers)

    {:error, Response.error(:fcm, error_status, error_message, body, retry_after)}
  end

  defp parse_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {seconds, ""} -> seconds
          _ -> nil
        end
    end
  end

  # -- JWT Token Management (per-instance) --

  defp get_instance_jwt(info) do
    cache_key = {:apns_jwt_cache, info.name}
    now = System.system_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {token, expires_at} when is_integer(expires_at) and expires_at > now ->
        {:ok, token}

      _ ->
        refresh_instance_jwt(info, cache_key)
    end
  end

  @max_jwt_refresh_retries 10

  defp refresh_instance_jwt(info, cache_key, retries \\ 0)

  defp refresh_instance_jwt(_info, _cache_key, retries)
       when retries >= @max_jwt_refresh_retries do
    {:error, "JWT refresh timeout after #{retries} attempts"}
  end

  defp refresh_instance_jwt(info, cache_key, retries) do
    lock = :persistent_term.get({:apns_jwt_lock, info.name})

    case :atomics.compare_exchange(lock, 1, 0, 1) do
      :ok ->
        try do
          now = System.system_time(:millisecond)

          case :persistent_term.get(cache_key, nil) do
            {token, expires_at} when is_integer(expires_at) and expires_at > now ->
              {:ok, token}

            _ ->
              case generate_instance_jwt(info) do
                {:ok, token} ->
                  :persistent_term.put(cache_key, {token, now + @jwt_cache_ttl_ms})
                  {:ok, token}

                {:error, _} = error ->
                  error
              end
          end
        after
          :atomics.put(lock, 1, 0)
        end

      _current ->
        Process.sleep(50)
        now = System.system_time(:millisecond)

        case :persistent_term.get(cache_key, nil) do
          {token, expires_at} when is_integer(expires_at) and expires_at > now ->
            {:ok, token}

          _ ->
            refresh_instance_jwt(info, cache_key, retries + 1)
        end
    end
  end

  defp generate_instance_jwt(info) do
    key_id = Keyword.fetch!(info.config, :key_id)
    team_id = Keyword.fetch!(info.config, :team_id)
    private_key = resolve_private_key(Keyword.fetch!(info.config, :private_key))

    signer = Joken.Signer.create("ES256", %{"pem" => private_key}, %{"kid" => key_id})

    claims = %{
      "iss" => team_id,
      "iat" => System.system_time(:second)
    }

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _claims} ->
        {:ok, token}

      {:error, reason} ->
        Logger.error("[PushX.Instance] JWT generation failed: #{inspect(reason)}")
        {:error, "JWT generation failed: #{inspect(reason)}"}
    end
  end

  defp resolve_private_key({:file, path}), do: File.read!(path)

  defp resolve_private_key({:system, env_var}) do
    System.get_env(env_var) || raise "Environment variable #{env_var} not set"
  end

  defp resolve_private_key(pem) when is_binary(pem), do: pem

  # -- FCM message builder --

  defp build_fcm_message(token, %Message{} = message, opts) do
    base = %{
      "token" => token,
      "notification" => Message.to_fcm_payload(message)["notification"]
    }

    base
    |> maybe_put("data", stringify_map(Keyword.get(opts, :data) || message.data))
    |> maybe_put("android", Keyword.get(opts, :android))
    |> maybe_put("webpush", Keyword.get(opts, :webpush))
    |> then(&%{"message" => &1})
  end

  defp build_fcm_message(token, payload, opts) when is_map(payload) do
    base = %{"token" => token}

    base =
      if Map.has_key?(payload, "notification") do
        Map.put(base, "notification", payload["notification"])
      else
        Map.put(base, "notification", payload)
      end

    base
    |> maybe_put("data", stringify_map(Keyword.get(opts, :data)))
    |> maybe_put("android", Keyword.get(opts, :android))
    |> maybe_put("webpush", Keyword.get(opts, :webpush))
    |> then(&%{"message" => &1})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, data) when data == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_map(nil), do: nil
  defp stringify_map(map) when map == %{}, do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end
end
