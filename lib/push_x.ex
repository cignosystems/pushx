defmodule PushX do
  @moduledoc """
  Modern push notifications for Elixir.

  PushX provides a simple, unified API for sending push notifications
  to iOS (APNS) and Android (FCM) devices using HTTP/2 connections.

  ## Features

    * HTTP/2 connections via Finch (Mint-based)
    * JWT authentication for APNS with automatic caching
    * OAuth2 authentication for FCM via Goth
    * Unified API with direct provider access
    * Structured response handling
    * Batch sending with configurable concurrency
    * Token validation
    * Client-side rate limiting

  ## Quick Start

      # Send to iOS
      PushX.push(:apns, device_token, "Hello World", topic: "com.example.app")

      # Send to Android
      PushX.push(:fcm, device_token, "Hello World")

      # With title and body
      PushX.push(:apns, token, %{title: "New Message", body: "You have a notification"}, topic: "...")

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

  alias PushX.{APNS, FCM, Message, Response, Token, RateLimiter}

  @type provider :: :apns | :fcm
  @type token :: String.t()
  @type message :: String.t() | map() | Message.t()
  @type option :: APNS.option() | FCM.option()

  @doc """
  Sends a push notification to a device.

  ## Arguments

    * `provider` - `:apns` for iOS or `:fcm` for Android
    * `device_token` - The device's push token
    * `message` - A string, map, or `PushX.Message` struct
    * `opts` - Provider-specific options

  ## Options

  ### APNS Options

    * `:topic` - Bundle ID (required for APNS)
    * `:mode` - `:prod` or `:sandbox` (default: from config)
    * `:push_type` - "alert", "background", "voip" (default: "alert")
    * `:priority` - 5 or 10 (default: 10)

  ### FCM Options

    * `:project_id` - Firebase project ID (default: from config)
    * `:data` - Custom data payload map

  ## Examples

      # Simple string message
      PushX.push(:apns, token, "Hello!", topic: "com.example.app")

      # Map with title and body
      PushX.push(:fcm, token, %{title: "Alert", body: "Something happened"})

      # Using Message struct
      message = PushX.Message.new()
        |> PushX.Message.title("Order Update")
        |> PushX.Message.body("Your order has been shipped!")
        |> PushX.Message.badge(1)

      PushX.push(:apns, token, message, topic: "com.example.app")

  ## Returns

      {:ok, %PushX.Response{provider: :apns, status: :sent, id: "..."}}
      {:error, %PushX.Response{provider: :apns, status: :invalid_token, reason: "BadDeviceToken"}}

  """
  @spec push(provider(), token(), message(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def push(provider, device_token, message, opts \\ [])

  def push(:apns, device_token, message, opts) do
    payload = normalize_payload(message, :apns)
    APNS.send(device_token, payload, opts)
  end

  def push(:fcm, device_token, message, opts) do
    payload = normalize_payload(message, :fcm)
    FCM.send(device_token, payload, opts)
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
  @spec push!(provider(), token(), message(), [option()]) :: :ok | :error
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
  @spec message() :: Message.t()
  def message, do: Message.new()

  @doc """
  Creates a new message with title and body.

  Alias for `PushX.Message.new/2`.

  ## Examples

      message = PushX.message("Hello", "World")

  """
  @spec message(String.t(), String.t()) :: Message.t()
  def message(title, body), do: Message.new(title, body)

  # Batch sending

  @doc """
  Sends a push notification to multiple devices concurrently.

  Uses `Task.async_stream` for parallel sending with configurable concurrency.
  Each result contains the token and the response.

  ## Arguments

    * `provider` - `:apns` for iOS or `:fcm` for Android
    * `device_tokens` - List of device tokens
    * `message` - A string, map, or `PushX.Message` struct
    * `opts` - Provider-specific options plus:
      * `:concurrency` - Max concurrent requests (default: 50)
      * `:timeout` - Timeout per request in ms (default: 30_000)
      * `:validate_tokens` - Validate tokens before sending (default: false)

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

  """
  @spec push_batch(provider(), [token()], message(), [option()]) ::
          [{token(), {:ok, Response.t()} | {:error, Response.t()}}]
  def push_batch(provider, device_tokens, message, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, batch_concurrency())
    timeout = Keyword.get(opts, :timeout, 30_000)
    validate = Keyword.get(opts, :validate_tokens, false)
    send_opts = Keyword.drop(opts, [:concurrency, :timeout, :validate_tokens])

    # Optionally validate tokens first
    tokens_to_send =
      if validate do
        Enum.filter(device_tokens, &Token.valid?(provider, &1))
      else
        device_tokens
      end

    tokens_to_send
    |> Task.async_stream(
      fn token -> {token, push(provider, token, message, send_opts)} end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(tokens_to_send)
    |> Enum.map(fn
      {{:ok, result}, _token} ->
        result

      {{:exit, :timeout}, token} ->
        {token, {:error, Response.error(provider, :connection_error, "timeout")}}
    end)
  end

  @doc """
  Sends a push notification to multiple devices and returns success count.

  Simplified version of `push_batch/4` that returns aggregate results.

  ## Returns

  A map with `:success`, `:failure`, and `:total` counts.

  ## Examples

      %{success: 95, failure: 5, total: 100} =
        PushX.push_batch!(:fcm, tokens, "Hello!")

  """
  @spec push_batch!(provider(), [token()], message(), [option()]) ::
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

  defp batch_concurrency do
    PushX.Config.get(:batch_concurrency, 50)
  end

  defp normalize_payload(message, _provider) when is_binary(message) do
    Message.new(message, "")
  end

  defp normalize_payload(%Message{} = message, _provider) do
    message
  end

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
