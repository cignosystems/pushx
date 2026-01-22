# PushX

[![CI](https://github.com/cignosystems/pushx/actions/workflows/ci.yml/badge.svg)](https://github.com/cignosystems/pushx/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/pushx.svg)](https://hex.pm/packages/pushx)
[![Hex Docs](https://img.shields.io/badge/hex-docs-purple.svg)](https://hexdocs.pm/pushx)
[![License](https://img.shields.io/hexpm/l/pushx.svg)](https://github.com/cignosystems/pushx/blob/main/LICENSE)

Modern push notifications for Elixir. Supports Apple APNS and Google FCM with HTTP/2, JWT authentication, and a clean unified API.

## Features

- **HTTP/2** connections via Finch (Mint-based) for optimal performance
- **APNS** (Apple Push Notification Service) with JWT authentication
- **FCM** (Firebase Cloud Messaging) with OAuth2 via Goth
- **Unified API** — single interface for both providers
- **Direct access** — use provider modules when you need more control
- **Message builder** — fluent API for constructing notifications
- **Structured responses** — consistent error handling across providers
- **Zero JSON dependency** — uses Elixir 1.18+ built-in JSON module

## Installation

Add `pushx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pushx, "~> 0.2.0"}
  ]
end
```

## Getting Your Credentials

### Apple APNS Setup

You'll need three things from Apple: **Key ID**, **Team ID**, and a **Private Key (.p8 file)**.

#### Step 1: Get Your Team ID

1. Go to [Apple Developer Account](https://developer.apple.com/account)
2. Your **Team ID** is shown in the top-right corner (10 characters, e.g., `TEAM123456`)

#### Step 2: Create an APNS Key

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/authkeys/list)
2. Click **Keys** → **+** (Create a new key)
3. Enter a name (e.g., "PushX APNS Key")
4. Check **Apple Push Notifications service (APNs)**
5. Click **Continue** → **Register**
6. **Download the .p8 file** (you can only download it once!)
7. Note the **Key ID** shown (10 characters, e.g., `ABC123DEFG`)

#### Step 3: Configure PushX

```elixir
# config/config.exs or config/runtime.exs
config :pushx,
  apns_key_id: "ABC123DEFG",           # From step 2
  apns_team_id: "TEAM123456",          # From step 1
  apns_private_key: {:file, "priv/keys/AuthKey_ABC123DEFG.p8"},
  apns_mode: :prod                      # :prod or :sandbox
```

Or use environment variables:

```elixir
config :pushx,
  apns_key_id: System.get_env("APNS_KEY_ID"),
  apns_team_id: System.get_env("APNS_TEAM_ID"),
  apns_private_key: System.get_env("APNS_PRIVATE_KEY"),  # PEM string directly
  apns_mode: :prod
```

> **Note:** The `:topic` option in `push/4` should be your app's Bundle ID (e.g., `com.yourcompany.app`)

---

### Google FCM Setup

You'll need a **Project ID** and a **Service Account JSON file** from Firebase.

#### Step 1: Create/Open Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a new project or select an existing one
3. Note your **Project ID** (shown in Project Settings, e.g., `my-app-12345`)

#### Step 2: Enable Cloud Messaging API

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Select your Firebase project
3. Go to **APIs & Services** → **Library**
4. Search for "Firebase Cloud Messaging API" and **Enable** it

#### Step 3: Create Service Account Key

1. In Firebase Console, go to **Project Settings** (gear icon)
2. Click **Service accounts** tab
3. Click **Generate new private key**
4. Save the JSON file securely (e.g., `priv/keys/firebase-service-account.json`)

#### Step 4: Configure PushX

```elixir
# config/config.exs or config/runtime.exs
config :pushx,
  fcm_project_id: "my-app-12345",
  fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}
```

Or inline the credentials:

```elixir
config :pushx,
  fcm_project_id: "my-app-12345",
  fcm_credentials: %{
    "type" => "service_account",
    "project_id" => "my-app-12345",
    "private_key_id" => "...",
    "private_key" => "-----BEGIN PRIVATE KEY-----\n...",
    "client_email" => "firebase-adminsdk-xxx@my-app-12345.iam.gserviceaccount.com",
    # ... rest of service account JSON
  }
```

> **Security:** Never commit credentials to git! Use environment variables or secret management in production.

---

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

### Finch Pool Configuration (Optional)

```elixir
config :pushx,
  finch_pool_size: 10,   # connections per pool (default: 10)
  finch_pool_count: 1    # number of pools (default: 1)
```

## Usage

### Unified API

```elixir
# Send to iOS
PushX.push(:apns, device_token, "Hello World", topic: "com.example.app")

# Send to Android
PushX.push(:fcm, device_token, "Hello World")

# With title and body
PushX.push(:apns, token, %{title: "Alert", body: "Door unlocked"}, topic: "com.example.app")
```

### Message Builder

```elixir
message = PushX.message()
  |> PushX.Message.title("Lock Alert")
  |> PushX.Message.body("Front door unlocked")
  |> PushX.Message.badge(1)
  |> PushX.Message.sound("default")
  |> PushX.Message.data(%{lock_id: "abc123"})

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

### Response Handling

```elixir
case PushX.push(:apns, token, message, topic: "com.app") do
  {:ok, %PushX.Response{status: :sent, id: apns_id}} ->
    Logger.info("Sent! ID: #{apns_id}")

  {:error, %PushX.Response{status: :invalid_token}} ->
    Tokens.delete(token)  # Remove invalid token

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

Tested on Elixir 1.18/1.19 with OTP 26, 27, and 28.

## Roadmap

- [ ] **Batch sending** — send to multiple tokens in one call
- [ ] **Automatic retry** — exponential backoff for rate limits and server errors
- [ ] **Telemetry integration** — metrics and tracing support
- [ ] **Token validation** — validate token format before sending
- [ ] **Connection pooling options** — configurable pool strategies
- [ ] **Rate limiting** — client-side rate limiting to avoid provider throttling
- [ ] **Safari Web Push** — support for Safari push notifications
- [ ] **Huawei HMS** — support for Huawei Push Kit

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add some amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

MIT License. See [LICENSE](LICENSE) for details.

---

Built with ❤️ by [Cigno Systems AB](https://github.com/cignosystems)
