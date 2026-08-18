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

  ## Lifecycle: instances live in memory only

  Instances are registered in an ETS table and supervised under PushX's own
  supervision tree. They are **not persisted**: after a node restart (deploy,
  crash, scale-out to a new node) no instances exist until your application
  starts them again. The idiomatic pattern is to load tenant credentials from
  your database and call `start/3` for each on boot — e.g. from a small
  worker in your supervision tree placed after your `Repo` — and again
  whenever a tenant is provisioned. `start/3` is idempotent enough for this:
  it returns `{:error, :already_started}` for a name that is running, so a
  re-run is safe. Each node in a cluster starts its own instances (they are
  per-VM processes, not cluster-wide).

  Stopping an instance (`stop/1`) or reconfiguring it invalidates its cached
  APNS JWT; per-instance circuit-breaker state is keyed by name and survives
  a `reconfigure/2` (it is process-independent) but not a node restart.

  """

  require Logger

  alias PushX.{HTTP, JWTCache, Message, Response, Retry, SendGate, Telemetry, URLs}

  @table :pushx_instances
  @reserved_names [:apns, :fcm]

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
    * `:private_key` - (required) PEM string, `{:file, path}`, or `{:system, "ENV_VAR"}`.
      Must be a P-256 (`prime256v1`) EC key — APNS signs with ES256, and a key
      on any other curve is rejected at start time.
    * `:mode` - `:prod` or `:sandbox` (default: `:prod`)
    * `:pool_size` - Finch pool size (default: 2)
    * `:pool_count` - Finch pool count (default: 1)

  ## FCM Config Keys

    * `:project_id` - (required) Firebase project ID
    * `:credentials` - (required unless `:token_fetcher` is set) Service account
      credentials map or JSON string. Must contain `"private_key"` (an RSA PEM
      able to sign RS256) and `"client_email"`; anything else is rejected at
      start time. PushX starts a Goth process for the instance from them.
    * `:token_fetcher` - (optional) bring your own OAuth for *this* instance:
      an `{module, function, args}` tuple invoked as
      `apply(module, function, [goth_name | args])` that returns
      `{:ok, %{token: access_token}}` or `{:error, reason}`. When set, no Goth
      process is started for the instance and `:credentials` becomes optional.
      The global `:fcm_token_fetcher` config never applies to instances.
    * `:pool_size` - Finch pool size (default: 2)
    * `:pool_count` - Finch pool count (default: 1)

  ## Returns

    * `{:ok, name}` on success
    * `{:error, :reserved_name}` if name is `:apns` or `:fcm`
    * `{:error, :already_started}` if instance already exists
    * `{:error, {:missing_config, keys}}` if required config is missing
    * `{:error, {:invalid_private_key, reason}}` if an APNS `:private_key`
      cannot sign — a malformed PEM, a key on the wrong curve, a `{:file, path}`
      whose file is missing, or a `{:system, VAR}` that is unset
    * `{:error, {:invalid_credentials, reason}}` if FCM `:credentials` are not
      a service-account map (or its JSON), lack `"private_key"`/`"client_email"`,
      or hold a key that cannot sign RS256
    * `{:error, {:invalid_token_fetcher, reason}}` if an FCM `:token_fetcher` is
      not an `{module, function, args}` tuple

  Credentials are verified with a test signature before the instance starts,
  so a bad key fails here rather than on the first push (APNS) or by crashing
  the OAuth process after start (FCM).

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

  The merged config is validated *before* the running instance is stopped, so
  a rotation to an unusable APNS key (`{:error, {:invalid_private_key, reason}}`)
  or unusable FCM credentials (`{:error, {:invalid_credentials, reason}}`)
  leaves the current instance serving traffic.

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

        # Validate before stopping so a bad new credential leaves the
        # running instance untouched instead of tearing it down.
        with :ok <- validate_config(provider, merged),
             :ok <- stop(name) do
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

    Retry.maybe_with_retry(
      :apns,
      opts,
      fn -> apns_send_once(info, device_token, payload, opts) end,
      reconnect_fn: fn -> reconnect(name) end,
      reconnect_key: name
    )
  end

  defp apns_send_once(info, device_token, payload, opts) do
    # Same breaker/limiter gate as the static path, keyed by instance name
    # so one tenant's failing pool doesn't open the breaker for others.
    case SendGate.check(info.name, :apns) do
      :ok ->
        result = do_apns_send_once(info, device_token, payload, opts)
        SendGate.record(info.name, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  defp do_apns_send_once(info, device_token, payload, opts) do
    opts = merge_message_options(payload, opts)
    mode = Keyword.get(opts, :mode, Keyword.get(info.config, :mode, :prod))

    cond do
      mode not in [:prod, :sandbox] ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "Invalid :mode #{inspect(mode)} (expected :prod or :sandbox)"
         )}

      Keyword.get(opts, :topic) in [nil, ""] ->
        {:error, Response.error(:apns, :invalid_request, ":topic option is required")}

      not is_binary(device_token) ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "APNS delivers to device tokens only (topics/conditions are FCM features)"
         )}

      not safe_token?(device_token) ->
        {:error,
         Response.error(:apns, :invalid_token, "Device token contains invalid characters")}

      true ->
        with {:ok, body} <- encode_apns_payload_safe(payload),
             :ok <- check_apns_payload_size(body, opts) do
          apns_send_authenticated(info, device_token, body, opts, mode)
        else
          {:error, reason} when is_binary(reason) ->
            {:error,
             Response.error(:apns, :invalid_request, "Failed to encode payload: #{reason}")}

          {:error, %Response{} = response} ->
            {:error, response}
        end
    end
  end

  # Mirrors PushX.APNS: reasons that mean the cached provider JWT is stale
  # and a fresh one may succeed. TooManyProviderTokenUpdates is excluded —
  # regenerating faster is exactly what Apple is complaining about.
  @stale_jwt_reasons ["ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken"]

  defp apns_send_authenticated(info, device_token, body, opts, mode, jwt_refreshed? \\ false) do
    topic = Keyword.fetch!(opts, :topic)

    case get_instance_jwt(info) do
      {:ok, jwt} ->
        case do_apns_send(info, device_token, body, opts, topic, jwt, mode) do
          {:error, %Response{status: :auth_error, reason: reason}} = error
          when reason in @stale_jwt_reasons ->
            if jwt_refreshed? do
              error
            else
              Logger.warning(
                "[PushX.Instance] Apple rejected provider token for #{inspect(info.name)} (#{reason}); regenerating JWT and retrying once"
              )

              JWTCache.invalidate({:apns_jwt, info.name})
              apns_send_authenticated(info, device_token, body, opts, mode, true)
            end

          result ->
            result
        end

      {:error, reason} ->
        {:error, Response.error(:apns, :auth_error, reason)}
    end
  end

  @safe_token_regex ~r/\A[A-Za-z0-9_\-]+\z/

  defp safe_token?(token) when is_binary(token), do: Regex.match?(@safe_token_regex, token)

  # Message delivery fields (priority/ttl/collapse_key) become send options;
  # explicit call-site opts win over struct-derived ones.
  defp merge_message_options(%Message{} = message, opts),
    do: Keyword.merge(Message.to_apns_options(message), opts)

  defp merge_message_options(_payload, opts), do: opts

  defp do_apns_send(info, device_token, body, opts, topic, jwt, mode) do
    url = "#{URLs.apns(mode)}/3/device/#{device_token}"

    # Shared with the static path so header rules (e.g. background pushes
    # defaulting to apns-priority 5) can't drift.
    headers = PushX.APNS.build_headers(jwt, topic, opts)

    send_apns_instance_request(info, device_token, url, headers, body)
  end

  defp send_apns_instance_request(info, device_token, url, headers, body) do
    Telemetry.start(:apns, device_token)
    start_time = System.monotonic_time()

    request_opts = [
      receive_timeout: Keyword.get(info.config, :receive_timeout, 15_000),
      pool_timeout: Keyword.get(info.config, :pool_timeout, 5_000)
    ]

    # HTTP.finch_request carries the shared NimblePool CaseClauseError
    # rescue — the same hardening the static path has.
    case HTTP.finch_request(
           Finch.build(:post, url, headers, body),
           info.finch_name,
           request_opts,
           "PushX.Instance"
         ) do
      {:ok, %{status: 200, headers: resp_headers}} ->
        apns_id = HTTP.get_header(resp_headers, "apns-id")
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

    Retry.maybe_with_retry(
      :fcm,
      opts,
      fn -> fcm_send_once(info, device_token, payload, opts) end,
      reconnect_fn: fn -> reconnect(name) end,
      reconnect_key: name
    )
  end

  defp fcm_send_once(info, device_token, payload, opts) do
    case SendGate.check(info.name, :fcm) do
      :ok ->
        result = do_fcm_send_once(info, device_token, payload, opts)
        SendGate.record(info.name, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  defp do_fcm_send_once(info, device_token, payload, opts) do
    with :ok <- PushX.FCM.validate_target(device_token),
         message = build_fcm_message(device_token, payload, opts),
         {:ok, body} <- HTTP.safe_encode(message),
         :ok <- check_fcm_payload_size(body) do
      fcm_send_authenticated(info, device_token, body)
    else
      {:error, reason} when is_binary(reason) ->
        {:error, Response.error(:fcm, :invalid_request, "Failed to encode payload: #{reason}")}

      {:error, %Response{} = response} ->
        {:error, response}
    end
  end

  defp fcm_send_authenticated(info, device_token, body) do
    # A global :fcm_token_fetcher never applies here — an instance's OAuth
    # comes from its own :credentials (Goth) or its own :token_fetcher.
    case PushX.FCM.fetch_access_token(info.goth_name, Keyword.get(info.config, :token_fetcher)) do
      {:ok, access_token} ->
        project_id = Keyword.fetch!(info.config, :project_id)
        url = URLs.fcm_send_url(project_id)

        headers = [
          {"authorization", "Bearer #{access_token}"},
          {"content-type", "application/json"}
        ]

        send_fcm_instance_request(info, device_token, url, headers, body)

      {:error, reason} ->
        PushX.FCM.oauth_error_response(reason)
    end
  end

  defp send_fcm_instance_request(info, device_token, url, headers, body) do
    Telemetry.start(:fcm, device_token)
    start_time = System.monotonic_time()

    request_opts = [
      receive_timeout: Keyword.get(info.config, :receive_timeout, 15_000),
      pool_timeout: Keyword.get(info.config, :pool_timeout, 5_000)
    ]

    # HTTP.finch_request carries the shared NimblePool CaseClauseError
    # rescue — the same hardening the static path has.
    case HTTP.finch_request(
           Finch.build(:post, url, headers, body),
           info.finch_name,
           request_opts,
           "PushX.Instance"
         ) do
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
      [] -> validate_private_key(config)
      keys -> {:error, {:missing_config, keys}}
    end
  end

  defp validate_config(:fcm, config) do
    fetcher = Keyword.get(config, :token_fetcher)
    # With a per-instance token fetcher the instance never talks to Goth, so
    # service-account credentials are optional (validated if present).
    required = if fetcher, do: [:project_id], else: [:project_id, :credentials]
    missing = Enum.reject(required, &Keyword.has_key?(config, &1))

    with [] <- missing,
         :ok <- validate_token_fetcher(fetcher) do
      case Keyword.get(config, :credentials) do
        nil -> :ok
        credentials -> validate_fcm_credentials(credentials)
      end
    else
      keys when is_list(keys) -> {:error, {:missing_config, keys}}
      {:error, _} = error -> error
    end
  end

  defp validate_token_fetcher(nil), do: :ok

  defp validate_token_fetcher({mod, fun, args})
       when is_atom(mod) and is_atom(fun) and is_list(args),
       do: :ok

  defp validate_token_fetcher(other) do
    {:error,
     {:invalid_token_fetcher,
      ":token_fetcher must be an {module, function, args} tuple, got: #{inspect(other)}"}}
  end

  # Goth eagerly exchanges the service-account credentials with Google when
  # it starts. A credentials map without "private_key"/"client_email", or
  # with a PEM that cannot sign RS256, makes Goth raise on that prefetch and
  # crash-loop; the restarts escalate through the instance supervisor to
  # PushX.Instance.DynamicSupervisor, which takes down *every* named
  # instance — while start/3 has already reported {:ok, name}. Reject such
  # credentials here, before anything is started, with a test sign
  # (mirrors validate_private_key/1 for APNS).
  @credentials_shape_error "credentials must be a decoded service-account map (or its JSON string)"

  defp validate_fcm_credentials(credentials) do
    with {:ok, creds} <- decode_credentials(credentials),
         {:ok, pem} <- fetch_credential(creds, "private_key"),
         {:ok, _email} <- fetch_credential(creds, "client_email"),
         %JOSE.JWK{} = jwk <- JOSE.JWK.from_pem(pem) do
      {_, _compact} =
        JOSE.JWT.sign(jwk, %{"alg" => "RS256"}, %{"iss" => "pushx-validate"})
        |> JOSE.JWS.compact()

      :ok
    else
      {:error, _} = error -> error
      _not_a_key -> {:error, {:invalid_credentials, "\"private_key\" is not a valid PEM"}}
    end
  rescue
    e -> {:error, {:invalid_credentials, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:invalid_credentials, {kind, reason}}}
  end

  defp decode_credentials(%{} = map), do: {:ok, map}

  defp decode_credentials(json) when is_binary(json) do
    case JSON.decode(json) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:invalid_credentials, @credentials_shape_error}}
    end
  end

  defp decode_credentials(_other), do: {:error, {:invalid_credentials, @credentials_shape_error}}

  defp fetch_credential(creds, key) do
    case creds do
      %{^key => value} when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:invalid_credentials, "missing #{inspect(key)}"}}
    end
  end

  # Resolves the key and performs a test sign so a garbage PEM (or a missing
  # file / unset env var) is rejected at start/reconfigure time instead of
  # raising inside the shared JWTCache on the first push.
  defp validate_private_key(config) do
    key_id = Keyword.fetch!(config, :key_id)
    private_key = resolve_private_key(Keyword.fetch!(config, :private_key))
    signer = Joken.Signer.create("ES256", %{"pem" => private_key}, %{"kid" => key_id})

    case Joken.encode_and_sign(%{"iss" => "pushx-validate"}, signer) do
      {:ok, _token, _claims} -> :ok
      {:error, reason} -> {:error, {:invalid_private_key, reason}}
    end
  rescue
    e -> {:error, {:invalid_private_key, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:invalid_private_key, {kind, reason}}}
  end

  defp encode_apns_payload_safe(%Message{} = message),
    do: HTTP.safe_encode(Message.to_apns_payload(message))

  defp encode_apns_payload_safe(payload) when is_map(payload), do: HTTP.safe_encode(payload)

  # APNS / FCM payload size limits per provider docs.
  @apns_alert_max_bytes 4096
  @apns_voip_max_bytes 5120
  @fcm_max_bytes 4096

  defp check_apns_payload_size(body, opts) do
    push_type = Keyword.get(opts, :push_type, "alert")
    max_bytes = if push_type == "voip", do: @apns_voip_max_bytes, else: @apns_alert_max_bytes

    if byte_size(body) > max_bytes do
      {:error,
       Response.error(
         :apns,
         :payload_too_large,
         "Payload #{byte_size(body)} bytes exceeds APNS limit of #{max_bytes}"
       )}
    else
      :ok
    end
  end

  defp check_fcm_payload_size(body) do
    if byte_size(body) > @fcm_max_bytes do
      {:error,
       Response.error(
         :fcm,
         :payload_too_large,
         "Payload #{byte_size(body)} bytes exceeds FCM limit of #{@fcm_max_bytes}"
       )}
    else
      :ok
    end
  end

  defp handle_apns_error(status, body, response_headers) do
    reason =
      case JSON.decode(body) do
        {:ok, %{"reason" => reason}} -> reason
        _ -> "HTTP #{status}"
      end

    error_status = Response.apns_reason_to_status(reason)
    retry_after = HTTP.parse_retry_after(response_headers)

    {:error, Response.error(:apns, error_status, reason, body, retry_after)}
  end

  defp handle_fcm_error(status, body, response_headers) do
    {error_code, error_message} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{"status" => code, "message" => msg}} = decoded} ->
          {Response.extract_fcm_error_code(decoded) || code, msg}

        {:ok, %{"error" => %{"code" => code, "message" => msg}} = decoded} ->
          {Response.extract_fcm_error_code(decoded) || to_string(code), msg}

        _ ->
          {"UNKNOWN", "HTTP #{status}"}
      end

    error_status = Response.fcm_error_to_status(error_code)
    retry_after = HTTP.parse_retry_after(response_headers)

    {:error, Response.error(:fcm, error_status, error_message, body, retry_after)}
  end

  # -- JWT Token Management (per-instance) --
  # Backed by PushX.JWTCache so a killed refresher can't leave a lock held.

  defp get_instance_jwt(info) do
    JWTCache.get_or_generate(
      {:apns_jwt, info.name},
      fn -> generate_instance_jwt(info) end,
      @jwt_cache_ttl_ms
    )
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
  rescue
    # A malformed PEM makes JOSE raise (badarg) instead of returning an error
    # tuple; surface it as the documented error so the caller and the shared
    # JWTCache never crash on tenant-supplied credentials.
    e ->
      Logger.error("[PushX.Instance] JWT generation raised: #{Exception.message(e)}")
      {:error, "JWT generation failed: #{Exception.message(e)}"}
  end

  defp resolve_private_key({:file, path}), do: File.read!(path)

  defp resolve_private_key({:system, env_var}) do
    System.get_env(env_var) || raise "Environment variable #{env_var} not set"
  end

  defp resolve_private_key(pem) when is_binary(pem), do: pem

  defp resolve_private_key(other) do
    raise ArgumentError,
          ":private_key must be a PEM string, {:file, path} or {:system, \"ENV_VAR\"}, got: #{inspect(other)}"
  end

  # -- FCM message builder --

  # Delegates to the static builder so the two paths cannot drift (the
  # instance copy used to silently drop the `apns` override key).
  defp build_fcm_message(token, payload, opts) do
    PushX.FCM.build_message(token, payload, opts)
  end
end
