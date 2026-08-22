defmodule PushX do
  @moduledoc since: "0.1.0"
  @moduledoc """
  Push notifications for Elixir: APNS, FCM and Web Push in one call.

  One API sends to iOS/macOS (Apple APNS, HTTP/2 + JWT), Android (Google FCM
  HTTP v1, HTTP/2 + OAuth2) and **every browser** via standards-based Web Push:

    * **RFC 8030** — Generic Event Delivery Using HTTP Push (the transport:
      `TTL`, `Urgency`, `Topic`, 201/404/410 semantics)
    * **RFC 8291** — Message Encryption for Web Push (`aes128gcm`, RFC 8188
      content coding; PushX reproduces the RFC's test vectors exactly)
    * **RFC 8292** — VAPID (Voluntary Application Server Identification; ES256
      JWTs signed with your application-server key)

  See `PushX.WebPush` for the compliance notes (what is implemented, what is
  optional and omitted).

  ## Features

    * HTTP/2 connections via Finch (Mint-based)
    * JWT authentication for APNS with automatic caching
    * OAuth2 authentication for FCM via Goth
    * VAPID + RFC 8291 encryption for Web Push, keys generated with `mix pushx.vapid`
    * Unified API with direct provider access
    * Structured response handling
    * Batch sending with configurable concurrency
    * Token validation
    * Client-side rate limiting
    * Test delivery mode (`PushX.Test`)

  ## Quick Start

      # Send to iOS
      PushX.push(:apns, device_token, "Hello World", topic: "com.example.app")

      # Send to Android
      PushX.push(:fcm, device_token, "Hello World")

      # With title and body
      PushX.push(:apns, token, %{title: "New Message", body: "You have a notification"}, topic: "...")

      # Notification with custom data (FCM)
      PushX.push(:fcm, token, %{
        "notification" => %{"title" => "Alert", "body" => "Event triggered"},
        "data" => %{"event_id" => "123"}
      })

      # Data-only (silent) message (FCM)
      PushX.push_data(:fcm, token, %{action: "sync", id: 123})

      # Batch send to multiple devices
      results = PushX.push_batch(:fcm, tokens, "Hello Everyone!")

  ## Configuration

      config :pushx,
        # APNS (Apple)
        apns_key_id: "ABC123DEFG",
        apns_team_id: "TEAM123456",
        apns_private_key: {:file, "priv/keys/AuthKey.p8"},
        apns_mode: :prod,

        # FCM (Firebase)
        fcm_project_id: "my-project-id",
        fcm_credentials: {:file, "priv/keys/firebase.json"},

        # Batch sending
        batch_concurrency: 50,

        # Rate limiting (optional)
        rate_limit_enabled: false,
        rate_limit_apns: 5000,
        rate_limit_fcm: 5000

  ## Direct Provider Access

  For more control, use the provider modules directly:

      # APNS
      PushX.APNS.send(token, payload, topic: "com.app.bundle", mode: :sandbox)

      # FCM
      PushX.FCM.send(token, payload, data: %{"key" => "value"})

  """

  require Logger

  alias PushX.{APNS, CircuitBreaker, Config, FCM, Message, RateLimiter, Response, Token}

  @type provider :: :apns | :fcm | :webpush
  @type instance_name :: atom()
  @type token :: String.t()
  @typedoc """
  A device token; for FCM also `{:topic, name}` / `{:condition, expr}` (see
  `t:PushX.FCM.target/0`); for Web Push the browser's subscription map (see
  `t:PushX.WebPush.subscription/0`).
  """
  @type target ::
          token() | {:topic, String.t()} | {:condition, String.t()} | PushX.WebPush.subscription()
  @type message :: String.t() | map() | Message.t()
  @type option :: APNS.option() | FCM.option()

  @doc """
  Sends a push notification to a device.

  ## Arguments

    * `provider` - `:apns` for iOS, `:fcm` for Android, `:webpush` for browsers
    * `device_token` - The device's push token. For FCM this may also be a
      topic (`{:topic, "news"}`) or a condition
      (`{:condition, "'news' in topics && 'sports' in topics"}`) — see
      `t:PushX.FCM.target/0`. For Web Push it is the browser's subscription
      map — see `t:PushX.WebPush.subscription/0`.
    * `message` - A string, map, or `PushX.Message` struct
    * `opts` - Provider-specific options

  ## Options

  ### APNS Options

    * `:topic` - Bundle ID (required for APNS)
    * `:mode` - `:prod` or `:sandbox` (default: from config)
    * `:push_type` - "alert", "background", "voip", ... (default: "alert")
    * `:priority` - 5 or 10 (default: 10; 5 for `push_type: "background"`)
    * `:expiration` - Unix timestamp after which APNS drops the notification
      (`0` = deliver now or never); a `PushX.Message` `ttl` sets this for you
    * `:collapse_id` - notifications sharing an id replace each other
    * `:apns_id` - your own UUID for the notification, echoed back by Apple
      (see `PushX.APNS.send/3`)

  ### FCM Options

    * `:project_id` - Firebase project ID (default: from config)
    * `:data` - Custom data payload map (values are stringified)
    * `:android`, `:apns`, `:webpush` - raw platform override blocks, deep-merged
      over what a `PushX.Message` derives (see `PushX.FCM.send/3`)
    * `:validate_only` - dry run: FCM validates without delivering (see `PushX.FCM.send/3`)

  ### Web Push Options

    * `:ttl`, `:urgency`, `:topic` - see `PushX.WebPush` (how long the push
      service holds the message, power hint, collapse key)

  ### Common options

    * `:receive_timeout`, `:pool_timeout` - per-call overrides of the config
      timeouts (static paths)
    * `:retry` - `:blocking` (default) retries retryable failures in the
      calling process with backoff; `:none` makes exactly one attempt and
      returns retryable failures as-is (with `retry_after` when the provider
      supplied it) so you can requeue on your own schedule — a connection
      error still triggers the automatic pool reconnect. `true`/`false` are
      accepted as aliases. See "Blocking and retries" below.

  ## Examples

      # Simple string message
      PushX.push(:apns, token, "Hello!", topic: "com.example.app")

      # Map with title and body
      PushX.push(:fcm, token, %{title: "Alert", body: "Something happened"})

      # Web Push: the browser's subscription object is the target
      PushX.push(:webpush, subscription, %{title: "Hi", body: "From the server"})

      # FCM topic / condition instead of a device token
      PushX.push(:fcm, {:topic, "news"}, "Breaking news")
      PushX.push(:fcm, {:condition, "'news' in topics && 'sports' in topics"}, "Match report")

      # Using Message struct
      message = PushX.Message.new()
        |> PushX.Message.title("Order Update")
        |> PushX.Message.body("Your order has been shipped!")
        |> PushX.Message.badge(1)

      PushX.push(:apns, token, message, topic: "com.example.app")

  ## Returns

      {:ok, %PushX.Response{provider: :apns, status: :sent, id: "..."}}
      {:error, %PushX.Response{provider: :apns, status: :invalid_token, reason: "BadDeviceToken"}}

  ## Blocking and retries

  Retries run **in the calling process** with `Process.sleep` backoff. With
  the default config (3 attempts, 10s base delay) a single call can block
  for ~30 seconds on repeated server errors, or ~60 seconds on a
  rate-limited response. Don't call this synchronously from a
  latency-sensitive process (e.g. a Phoenix request) unless you pass
  `retry: :none`, disable retries globally (`retry_enabled: false`), or wrap
  the call in your own task. Inside `push_batch/4` a retrying task holds one
  of the batch's concurrency slots for the whole backoff, so for large
  audiences prefer `retry: :none` and requeue failures yourself.

  """
  @doc since: "0.1.0"
  @spec push(provider() | instance_name(), target(), message(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def push(provider, device_token, message, opts \\ [])

  def push(provider, device_token, message, opts) when provider in [:apns, :fcm, :webpush] do
    payload = normalize_payload(message, provider)

    result =
      case provider do
        :apns -> APNS.send(device_token, payload, opts)
        :fcm -> FCM.send(device_token, payload, opts)
        :webpush -> PushX.WebPush.send(device_token, payload, opts)
      end

    maybe_notify_invalid_token(provider, device_token, result)
    result
  end

  def push(instance_name, device_token, message, opts) when is_atom(instance_name) do
    case PushX.Instance.resolve(instance_name) do
      {:ok, instance_info} ->
        payload = normalize_payload(message, instance_info.provider)
        result = PushX.Instance.send(instance_info, device_token, payload, opts)
        maybe_notify_invalid_token(instance_info.provider, device_token, result)
        result

      {:error, :not_found} ->
        {:error, Response.error(:unknown, :unknown_error, "Instance #{instance_name} not found")}

      {:error, :disabled} ->
        {:error,
         Response.error(
           :unknown,
           :provider_disabled,
           "Instance #{instance_name} is disabled"
         )}
    end
  end

  @doc """
  Sends a data-only (silent) push notification to a device.

  The message contains only a `data` payload with no visible notification.
  Useful for triggering background syncs or delivering structured data.

  ## Arguments

    * `provider` - `:fcm`, `:webpush`, or a named instance atom
    * `device_token` - The device's push token (for Web Push: the subscription map)
    * `data` - A map of key-value data (values are stringified for FCM; sent as
      JSON as-is for Web Push, where the payload is whatever your service worker reads)
    * `opts` - Provider-specific options

  ## Examples

      # Via default FCM config
      PushX.push_data(:fcm, token, %{action: "sync", id: 123})

      # Via named instance
      PushX.push_data(:my_fcm, token, %{action: "sync", id: 123})

  """
  @doc since: "0.10.0"
  @spec push_data(provider() | instance_name(), target(), map(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def push_data(provider_or_instance, device_token, data, opts \\ [])

  def push_data(:apns, _device_token, _data, _opts) do
    {:error,
     Response.error(
       :apns,
       :invalid_request,
       "push_data is only supported for FCM and Web Push. For APNS silent push, use push/4 with push_type: \"background\""
     )}
  end

  def push_data(:fcm, device_token, data, opts) do
    result = FCM.send_data(device_token, data, opts)
    maybe_notify_invalid_token(:fcm, device_token, result)
    result
  end

  # Web Push has no notification/data split: the payload *is* data for your
  # service worker, so send the map as-is.
  def push_data(:webpush, subscription, data, opts) do
    result = PushX.WebPush.send(subscription, data, opts)
    maybe_notify_invalid_token(:webpush, subscription, result)
    result
  end

  def push_data(instance_name, device_token, data, opts) when is_atom(instance_name) do
    case PushX.Instance.resolve(instance_name) do
      {:ok, %{provider: :apns}} ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "push_data is only supported for FCM and Web Push. For APNS silent push, use push/4 with push_type: \"background\""
         )}

      # Web Push: the map *is* the payload — same wire shape as push_data(:webpush, ...).
      {:ok, %{provider: :webpush}} ->
        push(instance_name, device_token, data, opts)

      _ ->
        push(instance_name, device_token, %{"data" => data}, opts)
    end
  end

  @doc """
  Subscribes device tokens to an FCM topic, through the static `:fcm`
  configuration or a named FCM instance.

  Delegates to `PushX.FCM.subscribe/3` (see there for results, chunking and
  options). Named APNS instances return `{:error, %Response{status: :invalid_request}}`.

  ## Examples

      {:ok, results} = PushX.subscribe(:fcm, tokens, "news")
      {:ok, results} = PushX.subscribe(:tenant_fcm, tokens, "news")

  """
  @doc since: "0.14.0"
  @spec subscribe(:fcm | instance_name(), [token()], String.t(), [option()]) ::
          {:ok, [PushX.FCM.topic_result()]} | {:error, Response.t()}
  def subscribe(target, tokens, topic, opts \\ []),
    do: manage_topic(:subscribe, target, tokens, topic, opts)

  @doc "Unsubscribes device tokens from an FCM topic. See `subscribe/4`."
  @doc since: "0.14.0"
  @spec unsubscribe(:fcm | instance_name(), [token()], String.t(), [option()]) ::
          {:ok, [PushX.FCM.topic_result()]} | {:error, Response.t()}
  def unsubscribe(target, tokens, topic, opts \\ []),
    do: manage_topic(:unsubscribe, target, tokens, topic, opts)

  defp manage_topic(action, :fcm, tokens, topic, opts) do
    if action == :subscribe,
      do: FCM.subscribe(tokens, topic, opts),
      else: FCM.unsubscribe(tokens, topic, opts)
  end

  defp manage_topic(_action, :apns, _tokens, _topic, _opts) do
    {:error, Response.error(:apns, :invalid_request, "Topics are an FCM feature")}
  end

  defp manage_topic(action, instance_name, tokens, topic, opts) when is_atom(instance_name) do
    case PushX.Instance.resolve(instance_name) do
      {:ok, info} ->
        PushX.Instance.manage_topic(info, action, tokens, topic, opts)

      {:error, :not_found} ->
        {:error, Response.error(:unknown, :unknown_error, "Instance #{instance_name} not found")}

      {:error, :disabled} ->
        {:error,
         Response.error(:unknown, :provider_disabled, "Instance #{instance_name} is disabled")}
    end
  end

  @doc """
  Sends a push notification and returns only `:ok` or `:error`.

  Useful when you don't need the full response details.

  ## Examples

      case PushX.push!(:apns, token, "Hello", topic: "com.app") do
        :ok -> Logger.info("Sent!")
        :error -> Logger.warning("Failed")
      end

  """
  @doc since: "0.1.0"
  @spec push!(provider() | instance_name(), target(), message(), [option()]) :: :ok | :error
  def push!(provider, device_token, message, opts \\ []) do
    case push(provider, device_token, message, opts) do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  end

  @doc """
  Creates a new message using the builder pattern.

  Alias for `PushX.Message.new/0`.

  ## Examples

      message = PushX.message()
        |> PushX.Message.title("Hello")
        |> PushX.Message.body("World")

  """
  @doc since: "0.1.0"
  @spec message() :: Message.t()
  def message, do: Message.new()

  @doc """
  Creates a new message with title and body.

  Alias for `PushX.Message.new/2`.

  ## Examples

      message = PushX.message("Hello", "World")

  """
  @doc since: "0.1.0"
  @spec message(String.t(), String.t()) :: Message.t()
  def message(title, body), do: Message.new(title, body)

  # Batch sending

  @doc """
  Sends a push notification to multiple devices concurrently.

  Uses `Task.async_stream` for parallel sending with configurable concurrency.
  Each result contains the token and the response.

  ## Arguments

    * `provider` - `:apns` for iOS or `:fcm` for Android
    * `device_tokens` - Enumerable of device tokens (for FCM, topic/condition
      targets are accepted too — see `t:target/0`)
    * `message` - A string, map, or `PushX.Message` struct
    * `opts` - Provider-specific options plus:
      * `:concurrency` - Max concurrent requests (default: 50)
      * `:timeout` - Timeout per request in ms. Defaults to
        `PushX.Config.batch_timeout_ms/0`, which covers the worst-case
        blocking-retry budget (3 minutes with default retry config;
        30 seconds when retries are disabled)
      * `:validate_tokens` - Validate tokens before sending (default: false). When
      `true`, invalid tokens get `{:error, %Response{status: :invalid_token}}`
      without ever leaving the local process — the result list always matches
      the input length.

  ## Timeout vs. retries

  Each batch task runs the full retry cycle (blocking backoff — see
  `push/4`), and a task that exceeds `:timeout` is **killed**, reported as
  `{:error, %Response{status: :connection_error, reason: "timeout"}}`. The
  default timeout is computed from the retry config so a retrying task is
  not cut short mid-backoff; if you pass an explicit `:timeout`, keep it
  above `retry_max_attempts × retry_max_delay_ms` or disable retries for
  batches (`retry_enabled: false`). Note that a killed task may have an
  HTTP request already in flight that the provider still delivers — see
  the "Delivery semantics" section in the README.

  ## Examples

      # Send to multiple iOS devices
      results = PushX.push_batch(:apns, tokens, "Hello!", topic: "com.example.app")

      # Process results
      Enum.each(results, fn
        {token, {:ok, response}} ->
          Logger.info("Sent to \#{token}: \#{response.id}")

        {token, {:error, response}} ->
          if PushX.Response.should_remove_token?(response) do
            MyApp.Tokens.delete(token)
          end
      end)

      # With higher concurrency
      PushX.push_batch(:fcm, tokens, "Alert!", concurrency: 100)

  ## Returns

  A list of `{token, result}` tuples where result is `{:ok, Response.t()}` or `{:error, Response.t()}`.

  ## Large audiences

  The whole result list is held in memory, so for very large audiences (tens
  of thousands of tokens and up) either chunk the input (`Enum.chunk_every/2`,
  ~10k per call) or use `push_batch_stream/4`, which yields results lazily
  with bounded memory. Also consider `retry: :none` (see `push/4`) so a
  provider blip doesn't park batch tasks in backoff.

  """
  @doc since: "0.4.0"
  @spec push_batch(provider() | instance_name(), Enumerable.t(), message(), [option()]) ::
          [{target(), {:ok, Response.t()} | {:error, Response.t()}}]
  def push_batch(provider, device_tokens, message, opts \\ []) do
    provider
    |> push_batch_stream(device_tokens, message, opts)
    |> Enum.to_list()
  end

  @doc """
  Lazy version of `push_batch/4`: returns a stream of `{token, result}` pairs
  instead of a list.

  Same options and semantics as `push_batch/4` — bounded concurrency,
  per-task timeout, optional local token validation, one result per input,
  in input order — but nothing runs until the stream is enumerated, and each
  result is yielded as soon as it (and everything before it) has completed
  rather than collected into a list. Use it for large audiences so memory
  stays bounded and you can act on results incrementally (or stop early).
  `device_tokens` can be any enumerable and is enumerated exactly once, so a
  one-shot source such as a `Repo.stream/2` works.

  The stream must be consumed in the process that will own the sends; the
  batch tasks are started under `PushX.TaskSupervisor` when enumeration
  begins.

  ## Examples

      MyApp.Repo.transaction(fn ->
        MyApp.Repo.stream(from t in Token, where: t.provider == :fcm, select: t.value)
        |> then(&PushX.push_batch_stream(:fcm, &1, "Server maintenance in 10m", concurrency: 100))
        |> Stream.each(fn
          {token, {:error, resp}} ->
            if PushX.Response.should_remove_token?(resp), do: MyApp.Tokens.delete(token)

          _ ->
            :ok
        end)
        |> Stream.run()
      end)

  """
  @doc since: "0.13.0"
  @spec push_batch_stream(provider() | instance_name(), Enumerable.t(), message(), [option()]) ::
          Enumerable.t()
  def push_batch_stream(provider, device_tokens, message, opts \\ []) do
    send_opts = Keyword.drop(opts, PushX.Batch.batch_option_keys())
    validate_provider = if provider in [:apns, :fcm, :webpush], do: provider

    PushX.Batch.stream(
      device_tokens,
      &push(provider, &1, message, send_opts),
      validate_provider,
      response_provider(provider),
      opts
    )
  end

  defp response_provider(provider) when provider in [:apns, :fcm, :webpush], do: provider
  defp response_provider(_instance_name), do: :unknown

  @doc """
  Sends a push notification to multiple devices and returns success count.

  Simplified version of `push_batch/4` that returns aggregate results.

  ## Returns

  A map with `:success`, `:failure`, and `:total` counts.

  ## Examples

      %{success: 95, failure: 5, total: 100} =
        PushX.push_batch!(:fcm, tokens, "Hello!")

  """
  @doc since: "0.4.0"
  @spec push_batch!(provider() | instance_name(), [token()], message(), [option()]) ::
          %{success: non_neg_integer(), failure: non_neg_integer(), total: non_neg_integer()}
  def push_batch!(provider, device_tokens, message, opts \\ []) do
    results = push_batch(provider, device_tokens, message, opts)

    success = Enum.count(results, fn {_, result} -> match?({:ok, _}, result) end)
    total = length(results)

    %{success: success, failure: total - success, total: total}
  end

  # Token validation

  @doc """
  Validates a device token format.

  Delegates to `PushX.Token.validate/2`.

  ## Examples

      :ok = PushX.validate_token(:apns, valid_token)
      {:error, :invalid_length} = PushX.validate_token(:apns, "too-short")

  """
  @spec validate_token(provider(), token()) :: :ok | {:error, Token.validation_error()}
  defdelegate validate_token(provider, token), to: Token, as: :validate

  @doc """
  Returns true if the token format is valid.

  Delegates to `PushX.Token.valid?/2`.
  """
  @spec valid_token?(provider(), token()) :: boolean()
  defdelegate valid_token?(provider, token), to: Token, as: :valid?

  # Rate limiting

  @doc """
  Checks if a request can be made within rate limits.

  Delegates to `PushX.RateLimiter.check/1`.
  Only applies when rate limiting is enabled in config.
  """
  @spec check_rate_limit(provider()) :: :ok | {:error, :rate_limited}
  defdelegate check_rate_limit(provider), to: RateLimiter, as: :check

  # Health check

  @doc """
  Returns health status for the configured providers and every named instance.

  For the static `:apns`/`:fcm` configuration: whether credentials are
  configured and the circuit breaker state. For each `PushX.Instance`
  (keyed by name): its provider, whether it is enabled, and its own breaker
  state — instance breakers are independent of the static ones and of each
  other, so one tenant's outage is visible without hiding the rest.

  ## Examples

      PushX.health_check()
      #=> %{
      #=>   apns: %{configured: true, circuit: :closed},
      #=>   fcm: %{configured: true, circuit: :closed},
      #=>   webpush: %{configured: false, circuit: :closed},
      #=>   instances: %{
      #=>     tenant_42_apns: %{provider: :apns, enabled: true, circuit: :closed},
      #=>     tenant_7_fcm: %{provider: :fcm, enabled: false, circuit: :open}
      #=>   }
      #=> }

  """
  @doc since: "0.8.0"
  @spec health_check() :: %{
          apns: map(),
          fcm: map(),
          webpush: map(),
          instances: %{atom() => map()}
        }
  def health_check do
    instances =
      Map.new(PushX.Instance.list(), fn %{name: name, provider: provider, enabled: enabled} ->
        {name, %{provider: provider, enabled: enabled, circuit: CircuitBreaker.state(name)}}
      end)

    %{
      apns: %{configured: Config.apns_configured?(), circuit: CircuitBreaker.state(:apns)},
      fcm: %{configured: Config.fcm_configured?(), circuit: CircuitBreaker.state(:fcm)},
      webpush: %{
        configured: Config.webpush_configured?(),
        circuit: CircuitBreaker.state(:webpush)
      },
      instances: instances
    }
  end

  # Connection management

  @doc """
  Restarts the Finch HTTP pool, forcing fresh connections.

  Call this when connections become stale (e.g., after persistent
  `too_many_concurrent_requests` or `request_timeout` errors). On cloud
  infrastructure like Fly.io, idle HTTP/2 connections can be silently
  dropped, and Finch cannot detect these zombie connections. Restarting
  the pool forces new TCP/TLS handshakes.

  This is called automatically by the retry logic on connection errors.
  You can also call it manually if needed.

  ## Examples

      PushX.reconnect()
      #=> :ok

  """
  @doc since: "0.7.1"
  @spec reconnect() :: :ok | {:error, term()}
  def reconnect do
    name = PushX.Config.finch_name()

    with :ok <- Supervisor.terminate_child(PushX.Supervisor, name),
         {:ok, _pid} <- Supervisor.restart_child(PushX.Supervisor, name) do
      Logger.info("[PushX] Reconnected HTTP pools (stale connections discarded)")
      :ok
    else
      {:error, :running} ->
        # Already restarted by another process — that's fine
        :ok

      {:error, reason} ->
        Logger.error("[PushX] Failed to reconnect: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # Private functions

  # `token` is the device token, or for Web Push the subscription map — the
  # callback receives whichever the caller passed, i.e. what they stored.
  defp maybe_notify_invalid_token(provider, token, {:error, %Response{} = response})
       when is_binary(token) or is_map(token) do
    if Response.should_remove_token?(response) do
      case Config.on_invalid_token() do
        {mod, fun, args} ->
          # Supervised so a crashing cleanup callback is logged (with a
          # stacktrace) instead of dying silently in an unlinked process.
          Task.Supervisor.start_child(PushX.TaskSupervisor, fn ->
            apply(mod, fun, [provider, token | args])
          end)

        nil ->
          :ok
      end
    end
  end

  defp maybe_notify_invalid_token(_provider, _token, _result), do: :ok

  defp normalize_payload(message, _provider) when is_binary(message) do
    Message.new(message, "")
  end

  defp normalize_payload(%Message{} = message, _provider) do
    message
  end

  # Web Push maps are the payload itself (Notification API options such as
  # icon/tag/actions live next to title/body) — never rewritten.
  defp normalize_payload(map, :webpush) when is_map(map), do: map

  defp normalize_payload(%{"title" => _, "body" => _} = map, _provider) do
    Message.new(map["title"], map["body"])
    |> maybe_set(:badge, map["badge"])
    |> maybe_set(:sound, map["sound"])
    |> maybe_set(:data, map["data"])
  end

  defp normalize_payload(%{title: _, body: _} = map, _provider) do
    Message.new(map.title, map.body)
    |> maybe_set(:badge, Map.get(map, :badge))
    |> maybe_set(:sound, Map.get(map, :sound))
    |> maybe_set(:data, Map.get(map, :data))
  end

  defp normalize_payload(payload, _provider) when is_map(payload) do
    # Pass through raw payload maps (e.g., already formatted APNS/FCM payloads)
    payload
  end

  defp maybe_set(message, _field, nil), do: message
  defp maybe_set(message, :badge, value), do: Message.badge(message, value)
  defp maybe_set(message, :sound, value), do: Message.sound(message, value)
  defp maybe_set(message, :data, value), do: Message.data(message, value)
end
