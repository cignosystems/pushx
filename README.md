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
- **Batch sending** — send to multiple tokens concurrently with configurable parallelism
- **Token validation** — validate token format before sending to catch errors early
- **Rate limiting** — optional client-side rate limiting to avoid provider throttling
- **Automatic retry** — exponential backoff for rate limits and server errors
- **Telemetry** — built-in instrumentation for metrics and monitoring
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
    {:pushx, "~> 0.5.0"}
  ]
end
```

---

## API Reference

### `PushX.push/4`

Send a push notification to a device.

```elixir
PushX.push(provider, device_token, message, opts)
```

| Parameter | Type | Description |
|-----------|------|-------------|
| `provider` | `:apns` \| `:fcm` | Target platform |
| `device_token` | `String.t()` | Device push token |
| `message` | `String.t()` \| `map()` \| `PushX.Message.t()` | Notification content |
| `opts` | `Keyword.t()` | Provider-specific options |

**Returns:** `{:ok, %PushX.Response{}}` | `{:error, %PushX.Response{}}`

#### APNS Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:topic` | `String.t()` | *required* | App bundle ID (e.g., `"com.example.app"`) |
| `:mode` | `:prod` \| `:sandbox` | from config | APNS environment |
| `:push_type` | `String.t()` | `"alert"` | `"alert"`, `"background"`, `"voip"`, `"complication"`, `"fileprovider"`, `"mdm"` |
| `:priority` | `5` \| `10` | `10` | Delivery priority (5 = throttled, 10 = immediate) |
| `:expiration` | `integer()` | `nil` | Unix timestamp when notification expires |
| `:collapse_id` | `String.t()` | `nil` | Group notifications (max 64 bytes) |

#### FCM Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:project_id` | `String.t()` | from config | Firebase project ID |
| `:data` | `map()` | `nil` | Custom key-value data payload |
| `:android` | `map()` | `nil` | Android-specific options |
| `:apns` | `map()` | `nil` | APNS options (for iOS via FCM) |
| `:webpush` | `map()` | `nil` | Web push options |

### `PushX.push!/4`

Same as `push/4` but returns `:ok` | `:error` (without response details).

```elixir
case PushX.push!(:apns, token, "Hello", topic: "com.example.app") do
  :ok -> Logger.info("Sent!")
  :error -> Logger.error("Failed")
end
```

### `PushX.Message`

Fluent builder for constructing notification payloads.

```elixir
message = PushX.message()
  |> PushX.Message.title("New Message")
  |> PushX.Message.body("You have a new notification")
  |> PushX.Message.badge(1)
  |> PushX.Message.sound("default")
  |> PushX.Message.data(%{user_id: "12345"})
```

| Function | Description |
|----------|-------------|
| `title(msg, string)` | Set notification title |
| `body(msg, string)` | Set notification body |
| `badge(msg, integer)` | Set app badge count (iOS) |
| `sound(msg, string)` | Set notification sound |
| `data(msg, map)` | Set custom data payload |
| `put_data(msg, key, value)` | Add single data key-value |
| `category(msg, string)` | Set notification category (iOS) |
| `thread_id(msg, string)` | Set thread ID for grouping (iOS) |
| `image(msg, url)` | Set image URL (FCM) |
| `priority(msg, :high \| :normal)` | Set delivery priority |
| `ttl(msg, seconds)` | Set time-to-live |
| `collapse_key(msg, string)` | Set collapse key (FCM) |

### `PushX.Response`

Response struct returned from push operations.

```elixir
%PushX.Response{
  provider: :apns | :fcm,
  status: :sent | :invalid_token | :expired_token | ...,
  id: "message-id" | nil,
  reason: "error reason" | nil,
  raw: raw_response_body
}
```

| Status | Description | Action |
|--------|-------------|--------|
| `:sent` | Successfully delivered | None |
| `:invalid_token` | Token is malformed or invalid | Remove token |
| `:expired_token` | Token has expired | Remove token |
| `:unregistered` | Device unregistered | Remove token |
| `:payload_too_large` | Payload exceeds limit | Reduce payload size |
| `:rate_limited` | Too many requests | Retry with backoff |
| `:server_error` | Provider server error | Retry later |
| `:connection_error` | Network failure | Retry later |
| `:unknown_error` | Unrecognized error | Check `reason` field |

**Helper functions:**

```elixir
PushX.Response.success?(response)           # true if status == :sent
PushX.Response.should_remove_token?(response)  # true for invalid/expired/unregistered
```

### `PushX.push_batch/4`

Send to multiple devices concurrently.

```elixir
results = PushX.push_batch(:fcm, tokens, "Hello!")

# Process results
Enum.each(results, fn
  {token, {:ok, response}} -> Logger.info("Sent to #{token}")
  {token, {:error, response}} ->
    if PushX.Response.should_remove_token?(response) do
      MyApp.Tokens.delete(token)
    end
end)
```

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `:concurrency` | `integer()` | `50` | Max concurrent requests |
| `:timeout` | `integer()` | `30_000` | Timeout per request (ms) |
| `:validate_tokens` | `boolean()` | `false` | Filter invalid tokens before sending |

**Returns:** List of `{token, {:ok, Response.t()} | {:error, Response.t()}}` tuples.

### `PushX.push_batch!/4`

Same as `push_batch/4` but returns a summary map:

```elixir
%{success: 95, failure: 5, total: 100} = PushX.push_batch!(:fcm, tokens, "Hello!")
```

### Token Validation

Validate tokens before sending to catch obvious format errors early:

```elixir
# Check if valid
PushX.valid_token?(:apns, token)  # true/false

# Get detailed error
PushX.validate_token(:apns, token)
# :ok | {:error, :empty} | {:error, :invalid_length} | {:error, :invalid_format}

# Validate tokens in batch sending
PushX.push_batch(:apns, tokens, "Hello", topic: "...", validate_tokens: true)
```

**APNS tokens:** 64 hexadecimal characters (32 bytes)
**FCM tokens:** 100-500 characters, alphanumeric with hyphens/underscores

### Rate Limiting

Optional client-side rate limiting prevents exceeding provider limits:

```elixir
# Check before sending
case PushX.check_rate_limit(:apns) do
  :ok -> # Proceed
  {:error, :rate_limited} -> # Back off
end
```

Enable in config:

```elixir
config :pushx,
  rate_limit_enabled: true,
  rate_limit_apns: 5000,        # requests per window
  rate_limit_fcm: 5000,         # requests per window  
  rate_limit_window_ms: 1000    # 1 second window
```

### Direct Provider Access

For more control, use the provider modules directly:

```elixir
# APNS
PushX.APNS.send(token, payload, opts)
PushX.APNS.send_batch(tokens, payload, opts)
PushX.APNS.notification(title, body, badge \\ nil)
PushX.APNS.notification_with_data(title, body, data, badge \\ nil)
PushX.APNS.silent_notification(data \\ %{})

# FCM
PushX.FCM.send(token, payload, opts)
PushX.FCM.send_batch(tokens, payload, opts)
PushX.FCM.send_data(token, data, opts)  # Data-only message
PushX.FCM.notification(title, body, opts \\ [])
```

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

| Option | Type | Description |
|--------|------|-------------|
| `:apns_key_id` | `String.t()` | 10-character Key ID from Apple |
| `:apns_team_id` | `String.t()` | 10-character Team ID from Apple |
| `:apns_private_key` | `String.t()` \| `{:file, path}` | PEM string or file path |
| `:apns_mode` | `:prod` \| `:sandbox` | APNS environment (default: `:prod`) |

### FCM (Firebase Cloud Messaging)

```elixir
config :pushx,
  fcm_project_id: "my-project-id",
  fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}
```

| Option | Type | Description |
|--------|------|-------------|
| `:fcm_project_id` | `String.t()` | Firebase project ID |
| `:fcm_credentials` | `map()` \| `{:file, path}` | Service account JSON or file path |

### Pool Configuration (Optional)

```elixir
config :pushx,
  finch_pool_size: 10,   # connections per pool (default: 10)
  finch_pool_count: 1    # number of pools (default: 1)
```

---

## Credential Storage Options

### Option 1: File System (Development)

Store credentials in `priv/keys/` (gitignored):

```elixir
# config/dev.exs
config :pushx,
  apns_private_key: {:file, "priv/keys/AuthKey.p8"},
  fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}
```

Add to `.gitignore`:
```
/priv/keys/
```

### Option 2: Environment Variables (Production)

Store credentials as environment variables:

```elixir
# config/runtime.exs
config :pushx,
  apns_key_id: System.get_env("APNS_KEY_ID"),
  apns_team_id: System.get_env("APNS_TEAM_ID"),
  apns_private_key: System.get_env("APNS_PRIVATE_KEY"),
  apns_mode: if(System.get_env("APNS_SANDBOX") == "true", do: :sandbox, else: :prod),

  fcm_project_id: System.get_env("FCM_PROJECT_ID"),
  fcm_credentials: System.get_env("FCM_CREDENTIALS") |> Jason.decode!()
```

> **Tip:** For multiline keys (APNS .p8), encode as base64 or replace newlines with `\n`.

### Option 3: Fly.io Secrets

```bash
# Set APNS credentials
fly secrets set APNS_KEY_ID="ABC123DEFG"
fly secrets set APNS_TEAM_ID="TEAM123456"
fly secrets set APNS_PRIVATE_KEY="$(cat AuthKey.p8)"

# Set FCM credentials (JSON as string)
fly secrets set FCM_PROJECT_ID="my-project-id"
fly secrets set FCM_CREDENTIALS="$(cat firebase-service-account.json)"
```

Then in `config/runtime.exs`:

```elixir
if config_env() == :prod do
  config :pushx,
    apns_key_id: System.fetch_env!("APNS_KEY_ID"),
    apns_team_id: System.fetch_env!("APNS_TEAM_ID"),
    apns_private_key: System.fetch_env!("APNS_PRIVATE_KEY"),
    apns_mode: :prod,

    fcm_project_id: System.fetch_env!("FCM_PROJECT_ID"),
    fcm_credentials: System.fetch_env!("FCM_CREDENTIALS") |> JSON.decode!()
end
```

### Option 4: AWS Secrets Manager / Vault

Fetch secrets at runtime in `config/runtime.exs`:

```elixir
if config_env() == :prod do
  # Example with ExAws
  {:ok, %{"SecretString" => apns_key}} = 
    ExAws.SecretsManager.get_secret_value("pushx/apns-key")
    |> ExAws.request()

  config :pushx,
    apns_private_key: apns_key
end
```

---

## Getting Your Credentials

### Apple APNS Setup

You'll need: **Key ID**, **Team ID**, and a **Private Key (.p8 file)**.

#### Step 1: Get Your Team ID

1. Go to [Apple Developer Account](https://developer.apple.com/account)
2. Your **Team ID** is shown in the top-right corner (10 characters)

#### Step 2: Create an APNS Key

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/authkeys/list)
2. Click **Keys** → **+** (Create a new key)
3. Enter a name (e.g., "Push Notifications Key")
4. Check **Apple Push Notifications service (APNs)**
5. Click **Continue** → **Register**
6. **Download the .p8 file** (you can only download it once!)
7. Note the **Key ID** shown (10 characters)

### Google FCM Setup

You'll need: **Project ID** and a **Service Account JSON file**.

#### Step 1: Create/Open Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a new project or select an existing one
3. Note your **Project ID** in Project Settings

#### Step 2: Enable Cloud Messaging API

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Select your Firebase project
3. Go to **APIs & Services** → **Library**
4. Search for "Firebase Cloud Messaging API" and **Enable** it

#### Step 3: Create Service Account Key

1. In Firebase Console, go to **Project Settings** (gear icon)
2. Click **Service accounts** tab
3. Click **Generate new private key**
4. Save the JSON file securely

### Credential Rotation

> **TL;DR:** APNS .p8 keys and FCM service accounts **don't expire**. Rotate by updating your secrets and restarting/redeploying your app.

Both APNS JWT-based keys and FCM service accounts are valid until you manually revoke them. When you need to rotate (security policy, key compromise, etc.):

1. Generate new credentials in Apple/Google console
2. Update your secrets (Fly: `fly secrets set`, AWS: update in Secrets Manager)
3. Restart or redeploy your app
4. Revoke old credentials after all instances are updated

---

## Usage Examples

### Basic Usage

```elixir
# Send to iOS
PushX.push(:apns, device_token, "Hello!", topic: "com.example.app")

# Send to Android
PushX.push(:fcm, device_token, "Hello!")

# With title and body
PushX.push(:apns, token, %{title: "Welcome", body: "Thanks for signing up!"}, 
  topic: "com.example.app")
```

### Using Message Builder

```elixir
message = PushX.message()
  |> PushX.Message.title("Order Update")
  |> PushX.Message.body("Your order #1234 has shipped")
  |> PushX.Message.badge(1)
  |> PushX.Message.sound("default")
  |> PushX.Message.data(%{order_id: "1234", status: "shipped"})

PushX.push(:apns, token, message, topic: "com.example.app")
```

### Silent/Background Notification

```elixir
payload = PushX.APNS.silent_notification(%{action: "sync", resource: "messages"})

PushX.APNS.send(token, payload, 
  topic: "com.example.app",
  push_type: "background",
  priority: 5
)
```

### Response Handling

```elixir
case PushX.push(:apns, token, message, topic: "com.example.app") do
  {:ok, %PushX.Response{status: :sent, id: apns_id}} ->
    Logger.info("Notification sent with ID: #{apns_id}")

  {:error, %PushX.Response{status: :invalid_token}} ->
    # Remove invalid token from database
    MyApp.Tokens.delete(token)

  {:error, %PushX.Response{status: :rate_limited}} ->
    # Retry later with exponential backoff
    Logger.warning("Rate limited, will retry")

  {:error, %PushX.Response{status: status, reason: reason}} ->
    Logger.error("Push failed: #{status} - #{reason}")
end
```

### Batch Sending

```elixir
# Send to multiple tokens with built-in concurrency
results = PushX.push_batch(:apns, tokens, message, topic: "com.example.app")

# With higher concurrency and token validation
results = PushX.push_batch(:fcm, tokens, message, 
  concurrency: 100,
  validate_tokens: true
)

# Get summary counts
%{success: sent, failure: failed, total: total} = 
  PushX.push_batch!(:apns, tokens, message, topic: "com.example.app")

Logger.info("Sent #{sent}/#{total}, failed: #{failed}")
```

---

## Telemetry

PushX emits telemetry events for monitoring and metrics:

| Event | When | Measurements | Metadata |
|-------|------|--------------|----------|
| `[:pushx, :push, :start]` | Request starts | `system_time` | `provider`, `token` |
| `[:pushx, :push, :stop]` | Request succeeds | `duration` | `provider`, `token`, `status`, `id` |
| `[:pushx, :push, :error]` | Request fails | `duration` | `provider`, `token`, `status`, `reason` |
| `[:pushx, :push, :exception]` | Exception raised | `duration` | `provider`, `token`, `kind`, `reason` |
| `[:pushx, :retry, :attempt]` | Retry attempted | `delay_ms`, `attempt` | `provider`, `status` |

### Example: Attach a Logger

```elixir
# In your Application.start/2
:telemetry.attach_many(
  "pushx-logger",
  [
    [:pushx, :push, :stop],
    [:pushx, :push, :error]
  ],
  fn
    [:pushx, :push, :stop], %{duration: d}, %{provider: p}, _ ->
      ms = System.convert_time_unit(d, :native, :millisecond)
      Logger.info("PushX #{p} sent in #{ms}ms")

    [:pushx, :push, :error], _, %{provider: p, status: s, reason: r}, _ ->
      Logger.warning("PushX #{p} failed: #{s} - #{r}")
  end,
  nil
)
```

### Example: With Telemetry.Metrics

```elixir
defmodule MyApp.Telemetry do
  import Telemetry.Metrics

  def metrics do
    [
      counter("pushx.push.stop.count", tags: [:provider]),
      counter("pushx.push.error.count", tags: [:provider, :status]),
      distribution("pushx.push.stop.duration",
        unit: {:native, :millisecond},
        tags: [:provider]
      )
    ]
  end
end
```

---

## Retry Configuration

PushX automatically retries transient failures (rate limits, server errors) with exponential backoff:

```elixir
config :pushx,
  retry_enabled: true,           # default: true
  retry_max_attempts: 3,         # default: 3
  retry_base_delay_ms: 10_000,   # default: 10s (Google's recommended minimum)
  retry_max_delay_ms: 60_000     # default: 60s
```

**Retried errors:** `:connection_error`, `:rate_limited`, `:server_error`

**Not retried:** `:invalid_token`, `:expired_token`, `:unregistered`, `:payload_too_large`

To disable retry for a specific call, use `send_once`:

```elixir
PushX.APNS.send_once(token, payload, topic: "com.example.app")
PushX.FCM.send_once(token, payload)
```

---

## Requirements

- Elixir 1.18+ (for built-in JSON module)
- OTP 26+

Tested on Elixir 1.18/1.19 with OTP 26, 27, and 28.

## Web Push Support

PushX supports web push notifications for browsers.

### FCM Web Push (Chrome, Firefox, Edge)

FCM uses the same API for web and mobile. Web tokens come from Firebase Messaging SDK.

```elixir
# Get token in browser: firebase.messaging().getToken()
web_token = "eKz7v2j..."

# Same API as mobile!
PushX.push(:fcm, web_token, %{title: "Hello", body: "From web!"})

# Using web notification helper with click action
PushX.FCM.send_web(web_token, "New Message", "Check it out", "https://example.com/messages")

# With icon and badge
PushX.FCM.send_web(web_token, "Alert", "Important update",
  "https://example.com",
  icon: "https://example.com/icon.png",
  badge: "https://example.com/badge.png"
)

# Build payload manually for more control
payload = PushX.FCM.web_notification("Title", "Body", "https://example.com",
  icon: "https://example.com/icon.png",
  require_interaction: true
)
PushX.FCM.send(web_token, payload)
```

### Safari Web Push (macOS)

Safari uses APNS with a `web.` topic prefix. Tokens are 64 hex characters (same as iOS).

```elixir
safari_token = "abc123..."  # 64 hex chars

# Topic format: web.{website-push-id}
PushX.APNS.send(safari_token, payload, topic: "web.com.example.website")

# Using web notification helper
payload = PushX.APNS.web_notification(
  "New Article",
  "Check out our latest post",
  "https://example.com/article/123"
)
PushX.APNS.send(safari_token, payload, topic: "web.com.example.website")

# With custom action button
payload = PushX.APNS.web_notification("Sale!", "50% off today",
  "https://shop.com",
  action: "Shop Now"
)
```

## Roadmap

| Priority | Feature | Description |
|----------|---------|-------------|
| 🟢 Low | **Connection pooling** | Configurable pool strategies |

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
