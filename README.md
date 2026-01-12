# PushX

[![Hex.pm](https://img.shields.io/hexpm/v/pushx.svg)](https://hex.pm/packages/pushx)
[![Docs](https://img.shields.io/badge/docs-hexdocs-blue.svg)](https://hexdocs.pm/pushx)

Modern push notifications for Elixir. Supports Apple APNS and Google FCM with HTTP/2, JWT authentication, and a clean unified API.

## Features

- **HTTP/2** connections via Finch (Mint-based) for optimal performance
- **APNS** (Apple Push Notification Service) with JWT authentication
- **FCM** (Firebase Cloud Messaging) with OAuth2 via Goth
- **Automatic retry** with exponential backoff following Apple/Google best practices
- **Unified API** - single interface for both providers
- **Direct access** - use provider modules when you need more control
- **Message builder** - fluent API for constructing notifications
- **Structured responses** - consistent error handling across providers
- **Zero JSON dependency** - uses Elixir 1.18+ built-in JSON module

## Installation

Add `pushx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pushx, "~> 0.2.0"}
  ]
end
```

## Configuration

### APNS (Apple Push Notification Service)

```elixir
config :pushx,
  apns_key_id: "ABC123DEFG",
  apns_team_id: "TEAM123456",
  apns_private_key: {:file, "priv/keys/AuthKey.p8"},
  apns_mode: :prod  # or :sandbox
```

### FCM (Firebase Cloud Messaging)

```elixir
config :pushx,
  fcm_project_id: "my-project-id",
  fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}
```

### Retry Configuration (Optional)

PushX includes automatic retry with exponential backoff:

```elixir
config :pushx,
  retry_enabled: true,           # Enable/disable retry (default: true)
  retry_max_attempts: 3,         # Maximum retry attempts (default: 3)
  retry_base_delay_ms: 10_000,   # Base delay: 10 seconds (Google's minimum)
  retry_max_delay_ms: 60_000     # Maximum delay: 60 seconds
```

## Usage

### Unified API

```elixir
# Send to iOS
PushX.push(:apns, device_token, "Hello World", topic: "com.example.app")

# Send to Android
PushX.push(:fcm, device_token, "Hello World")

# With title and body
PushX.push(:apns, token, %{title: "New Message", body: "You have a new notification"}, topic: "com.example.app")
```

### Message Builder

```elixir
message = PushX.message()
  |> PushX.Message.title("Order Update")
  |> PushX.Message.body("Your order has been shipped!")
  |> PushX.Message.badge(1)
  |> PushX.Message.sound("default")
  |> PushX.Message.data(%{order_id: "12345"})

PushX.push(:apns, token, message, topic: "com.example.app")
```

### Direct Provider Access

```elixir
# APNS with all options
PushX.APNS.send(token, payload,
  topic: "com.app.bundle",
  mode: :sandbox,
  push_type: "alert",
  priority: 10
)

# FCM with data payload
PushX.FCM.send(token, notification, data: %{"key" => "value"})

# Silent/background notification
payload = PushX.APNS.silent_notification(%{action: "sync"})
PushX.APNS.send(token, payload, topic: "com.app", push_type: "background", priority: 5)
```

### Without Retry

Use `send_once` when you want to handle retries yourself:

```elixir
# Single attempt without retry
PushX.APNS.send_once(token, payload, topic: "com.app")
PushX.FCM.send_once(token, notification)
```

### Response Handling

```elixir
case PushX.push(:apns, token, message, topic: "com.app") do
  {:ok, %PushX.Response{status: :sent, id: apns_id}} ->
    Logger.info("Sent! ID: #{apns_id}")

  {:error, %PushX.Response{status: :invalid_token}} ->
    Tokens.delete(token)  # Remove invalid token

  {:error, %PushX.Response{status: :rate_limited, retry_after: seconds}} ->
    Logger.warning("Rate limited, retry after #{seconds}s")

  {:error, %PushX.Response{status: status, reason: reason}} ->
    Logger.warning("Failed: #{status} - #{reason}")
end

# Check if token should be removed
if PushX.Response.should_remove_token?(response) do
  Tokens.delete(token)
end
```

## Requirements

- Elixir 1.18+ (for built-in JSON module)
- OTP 26+

## License

MIT License. See [LICENSE](LICENSE) for details.
