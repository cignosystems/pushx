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

  ## Quick Start

      # Send to iOS
      PushX.push(:apns, device_token, "Hello World", topic: "com.example.app")

      # Send to Android
      PushX.push(:fcm, device_token, "Hello World")

      # With title and body
      PushX.push(:apns, token, %{title: "Alert", body: "Door unlocked"}, topic: "...")

  ## Configuration

      config :pushx,
        # APNS (Apple)
        apns_key_id: "ABC123DEFG",
        apns_team_id: "TEAM123456",
        apns_private_key: {:file, "priv/keys/AuthKey.p8"},
        apns_mode: :prod,

        # FCM (Firebase)
        fcm_project_id: "my-project-id",
        fcm_credentials: {:file, "priv/keys/firebase.json"}

  ## Direct Provider Access

  For more control, use the provider modules directly:

      # APNS
      PushX.APNS.send(token, payload, topic: "com.app.bundle", mode: :sandbox)

      # FCM
      PushX.FCM.send(token, payload, data: %{"key" => "value"})

  """

  alias PushX.{APNS, FCM, Message, Response}

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
        |> PushX.Message.title("Lock Alert")
        |> PushX.Message.body("Front door unlocked")
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

  # Private functions

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
