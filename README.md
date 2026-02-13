<p align="center">
  <img src="https://raw.githubusercontent.com/cignosystems/pushx/main/pushx_logo.png" alt="PushX Logo" width="400">
</p>

<p align="center">
  <strong>Modern push notifications for Elixir</strong><br>
  Supports Apple APNS and Google FCM with HTTP/2, JWT authentication, and a clean unified API.
</p>

<p align="center">
  <a href="https://github.com/cignosystems/pushx/actions/workflows/ci.yml"><img src="https://github.com/cignosystems/pushx/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://hex.pm/packages/pushx"><img src="https://img.shields.io/hexpm/v/pushx.svg" alt="Hex.pm"></a>
  <a href="https://hexdocs.pm/pushx"><img src="https://img.shields.io/badge/hex-docs-purple.svg" alt="Hex Docs"></a>
  <a href="https://github.com/cignosystems/pushx/blob/main/LICENSE"><img src="https://img.shields.io/hexpm/l/pushx.svg" alt="License"></a>
</p>

---

## Table of Contents

- [Features](#features)
- [Quick Start](#quick-start)
- [Usage Guide](#usage-guide)
- [Configuration](#configuration)
- [Credential Storage](#credential-storage)
- [Getting Your Credentials](#getting-your-credentials)
- [Telemetry](#telemetry)
- [Circuit Breaker](#circuit-breaker)
- [Health Check](#health-check)
- [Token Cleanup Callback](#token-cleanup-callback)
- [Troubleshooting](#troubleshooting)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- **HTTP/2** connections via Finch (Mint-based) for optimal performance
- **APNS** (Apple Push Notification Service) with JWT authentication
- **FCM** (Firebase Cloud Messaging) with OAuth2 via Goth
- **Web Push** — FCM for Chrome/Firefox/Edge, APNS for Safari
- **Batch sending** — send to multiple tokens concurrently with configurable parallelism
- **Token validation** — validate token format before sending to catch errors early
- **Rate limiting** — optional client-side rate limiting to avoid provider throttling
- **Automatic retry** — exponential backoff for rate limits and server errors
- **Telemetry** — built-in instrumentation for metrics and monitoring
- **Message builder** — fluent API for constructing notifications
- **Structured responses** — consistent error handling across providers
- **Zero JSON dependency** — uses Elixir 1.18+ built-in JSON module

### Requirements

- Elixir 1.18+ (for built-in JSON module)
- OTP 26+

Tested on Elixir 1.18/1.19 with OTP 26, 27, and 28.

---

## Quick Start

### 1. Install

Add `pushx` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:pushx, "~> 0.8"}
  ]
end
```

### 2. Configure

Add credentials to `config/runtime.exs`:

```elixir
config :pushx,
  # APNS (iOS)
  apns_key_id: System.fetch_env!("APNS_KEY_ID"),
  apns_team_id: System.fetch_env!("APNS_TEAM_ID"),
  apns_private_key: System.fetch_env!("APNS_PRIVATE_KEY"),
  apns_mode: :prod,

  # FCM (Android)
  fcm_project_id: System.fetch_env!("FCM_PROJECT_ID"),
  fcm_credentials: System.fetch_env!("FCM_CREDENTIALS") |> JSON.decode!()
```

PushX starts its own HTTP/2 connection pools and OAuth processes automatically — no additional supervision tree setup needed.

> Need help getting credentials? See [Getting Your Credentials](#getting-your-credentials) below.

### 3. Send a notification

```elixir
# Send to iOS
PushX.push(:apns, device_token, "Hello!", topic: "com.example.app")

# Send to Android
PushX.push(:fcm, device_token, "Hello!")

# With title and body
PushX.push(:apns, token, %{title: "Welcome", body: "Thanks for signing up!"},
  topic: "com.example.app")
```

That's it. PushX handles HTTP/2 connections, JWT/OAuth authentication, and automatic retry.

---

## Usage Guide

### Message Builder

Build rich notifications with the fluent API:

```elixir
message = PushX.message()
  |> PushX.Message.title("Order Update")
  |> PushX.Message.body("Your order #1234 has shipped")
  |> PushX.Message.badge(1)
  |> PushX.Message.sound("default")
  |> PushX.Message.data(%{order_id: "1234", status: "shipped"})

PushX.push(:apns, token, message, topic: "com.example.app")
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

You can also pass a plain string, a `%{title: ..., body: ...}` map, or a raw APNS/FCM payload map directly to `push/4`.

### Response Handling

Every push returns `{:ok, Response}` or `{:error, Response}`:

```elixir
case PushX.push(:apns, token, message, topic: "com.example.app") do
  {:ok, %PushX.Response{status: :sent, id: apns_id}} ->
    Logger.info("Notification sent with ID: #{apns_id}")

  {:error, %PushX.Response{} = response} ->
    if PushX.Response.should_remove_token?(response) do
      # Token is invalid, expired, or unregistered — delete it
      MyApp.Tokens.delete(token)
    else
      Logger.error("Push failed: #{response.status} - #{response.reason}")
    end
end
```

**Response struct:**

```elixir
%PushX.Response{
  provider: :apns | :fcm,
  status: :sent | :invalid_token | :expired_token | ...,
  id: "message-id" | nil,
  reason: "error reason" | nil,
  raw: raw_response_body,
  retry_after: seconds | nil
}
```

| Status | Description | Action |
|--------|-------------|--------|
| `:sent` | Successfully delivered | None |
| `:invalid_token` | Token is malformed or invalid | Remove token |
| `:expired_token` | Token has expired | Remove token |
| `:unregistered` | Device unregistered | Remove token |
| `:payload_too_large` | Payload exceeds limit (APNS: 4KB, FCM: 4000 bytes) | Reduce payload size |
| `:rate_limited` | Too many requests | Automatic retry with backoff |
| `:server_error` | Provider server error | Automatic retry with backoff |
| `:connection_error` | Network failure | Automatic retry with backoff |
| `:unknown_error` | Unrecognized error | Check `reason` field |

**Helper functions:**

```elixir
PushX.Response.success?(response)              # true if status == :sent
PushX.Response.should_remove_token?(response)  # true for invalid/expired/unregistered
PushX.Response.retryable?(response)            # true for connection_error/rate_limited/server_error
```

### Batch Sending

Send to multiple devices concurrently:

```elixir
results = PushX.push_batch(:apns, tokens, message, topic: "com.example.app")

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

For aggregate counts, use the bang variant:

```elixir
%{success: 95, failure: 5, total: 100} =
  PushX.push_batch!(:fcm, tokens, "Hello!")
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

### Data-Only Message (FCM)

Send data without a visible notification. All values are automatically converted to strings (FCM requirement):

```elixir
PushX.FCM.send_data(token, %{action: "sync", id: 123})
```

### Web Push

#### FCM Web Push (Chrome, Firefox, Edge)

FCM uses the same API for web and mobile. Web tokens come from Firebase Messaging SDK.

```elixir
# Same API as mobile
PushX.push(:fcm, web_token, %{title: "Hello", body: "From web!"})

# With click action
PushX.FCM.send_web(web_token, "New Message", "Check it out",
  "https://example.com/messages")

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

#### Safari Web Push (macOS)

Safari uses APNS with a `web.` topic prefix. Tokens are 64 hex characters (same as iOS).

```elixir
# Topic format: web.{website-push-id}
payload = PushX.APNS.web_notification("New Article", "Check it out",
  "https://example.com/article/123")
PushX.APNS.send(safari_token, payload, topic: "web.com.example.website")

# With custom action button and data
payload = PushX.APNS.web_notification_with_data("Sale!", "50% off",
  "https://shop.com",
  %{"promo_id" => "summer50"},
  action: "Shop Now"
)
```

### Direct Provider Access

The unified `PushX.push/4` normalizes payloads across providers. When you need provider-specific features, use the modules directly:

```elixir
# APNS — full control over headers and payload
PushX.APNS.send(token, payload, topic: "com.app", push_type: "voip")
PushX.APNS.send_once(token, payload, opts)          # no automatic retry
PushX.APNS.send_batch(tokens, payload, opts)
PushX.APNS.notification("Title", "Body", badge)
PushX.APNS.notification_with_data("Title", "Body", %{key: "value"})
PushX.APNS.silent_notification(%{action: "sync"})
PushX.APNS.web_notification("Title", "Body", "https://url")
PushX.APNS.web_notification_with_data("Title", "Body", "https://url", %{key: "val"})

# FCM — full control over android/webpush/data options
PushX.FCM.send(token, payload, data: %{key: "value"})
PushX.FCM.send_once(token, payload, opts)            # no automatic retry
PushX.FCM.send_batch(tokens, payload, opts)
PushX.FCM.send_data(token, %{key: "value"})          # data-only, no visible notification
PushX.FCM.send_web(token, "Title", "Body", "https://link", opts)
PushX.FCM.notification("Title", "Body", image: "https://img")
PushX.FCM.web_notification("Title", "Body", "https://link", opts)
PushX.FCM.web_notification_with_data("Title", "Body", "https://link", %{key: "val"})
```

### Token Validation

Validate tokens before sending to catch format errors early:

```elixir
PushX.valid_token?(:apns, token)    # true/false
PushX.validate_token(:apns, token)  # :ok | {:error, :empty | :invalid_length | :invalid_format}

# In batch — filter out bad tokens automatically
PushX.push_batch(:apns, tokens, message, topic: "...", validate_tokens: true)
```

**APNS tokens:** exactly 64 hexadecimal characters (32 bytes)
**FCM tokens:** 20-500 characters, alphanumeric with hyphens/underscores/colons

---

## Configuration

All configuration goes under `config :pushx`. Here's a complete example with all options:

```elixir
config :pushx,
  # === Credentials ===
  apns_key_id: "ABC123DEFG",
  apns_team_id: "TEAM123456",
  apns_private_key: {:file, "priv/keys/AuthKey.p8"},
  apns_mode: :prod,
  fcm_project_id: "my-project-id",
  fcm_credentials: {:file, "priv/keys/firebase.json"},

  # === HTTP/2 Pool (tune for your traffic level) ===
  finch_pool_size: 2,          # connections per pool (default: 25)
  finch_pool_count: 1,         # number of pools (default: 2)

  # === Timeouts ===
  receive_timeout: 15_000,     # wait for response data (default: 15s)
  pool_timeout: 5_000,         # wait for pool connection (default: 5s)
  connect_timeout: 10_000,     # TCP connect timeout (default: 10s)

  # === Retry ===
  retry_enabled: true,         # default: true
  retry_max_attempts: 3,       # default: 3
  retry_base_delay_ms: 10_000, # default: 10s (Google's recommended minimum)
  retry_max_delay_ms: 60_000,  # default: 60s

  # === Rate Limiting (optional) ===
  rate_limit_enabled: false,   # default: false
  rate_limit_apns: 5000,       # requests per window
  rate_limit_fcm: 5000,        # requests per window
  rate_limit_window_ms: 1000   # 1 second window
```

### Credentials

#### APNS

| Option | Type | Description |
|--------|------|-------------|
| `:apns_key_id` | `String.t()` | 10-character Key ID from Apple |
| `:apns_team_id` | `String.t()` | 10-character Team ID from Apple |
| `:apns_private_key` | `String.t()` \| `{:file, path}` \| `{:system, env_var}` | PEM string, file path, or env var name |
| `:apns_mode` | `:prod` \| `:sandbox` | APNS environment (default: `:prod`) |

#### FCM

| Option | Type | Description |
|--------|------|-------------|
| `:fcm_project_id` | `String.t()` | Firebase project ID |
| `:fcm_credentials` | `map()` \| `{:file, path}` \| `{:json, string}` \| `{:system, env_var}` | Service account as map, file, JSON string, or env var |

### Pool Sizing

Each HTTP/2 connection supports ~100 concurrent streams. Pool capacity = `pool_size x pool_count x 100`.

| Traffic Level | `pool_size` | `pool_count` | Concurrent Capacity |
|---------------|-------------|--------------|---------------------|
| Low (<100/min) | 2 | 1 | ~200 |
| Medium (<1000/min) | 10 | 1 | ~1,000 |
| High (>1000/min) | 25 | 2 | ~5,000 |
| Very high | 50 | 4 | ~20,000 |

> **Important:** For low-traffic apps, **reduce** pool size from the defaults. Large pools create many idle HTTP/2 connections that can go stale on cloud infrastructure (Fly.io, AWS, GCP), leading to `too_many_concurrent_requests` errors. Start small and increase only if needed.

### Retry Behavior

PushX automatically retries transient failures with exponential backoff:

- **Connection errors** — reconnects the HTTP pool, then retries with 1s base delay (1s, 2s, 4s)
- **Server errors (5xx)** — 10s base delay (10s, 20s, 40s) per Google's recommendation
- **Rate limited (429)** — uses `retry-after` header, or 60s default
- **Permanent failures** — never retried (invalid token, payload too large, etc.)

To skip retry for a specific call, use `send_once`:

```elixir
PushX.APNS.send_once(token, payload, topic: "com.example.app")
PushX.FCM.send_once(token, payload)
```

### Timeouts

| Option | Default | Description |
|--------|---------|-------------|
| `:receive_timeout` | 15s | How long to wait for response data from APNS/FCM |
| `:pool_timeout` | 5s | How long to wait for a connection from the pool |
| `:connect_timeout` | 10s | TCP connection establishment timeout |

> **Tip:** Increase timeouts if connecting from distant regions (e.g., EU to Apple's US servers).

You can also override timeouts per-request:

```elixir
PushX.APNS.send(token, payload,
  topic: "com.example.app",
  receive_timeout: 30_000,
  pool_timeout: 10_000
)
```

### Rate Limiting

Optional client-side rate limiting prevents exceeding provider limits. Disabled by default.

```elixir
# Check manually before sending
case PushX.check_rate_limit(:apns) do
  :ok -> # proceed
  {:error, :rate_limited} -> # back off
end
```

When enabled, rate limits are checked automatically before each `send` call.

---

## Credential Storage

### File System (Development)

```elixir
# config/dev.exs
config :pushx,
  apns_private_key: {:file, "priv/keys/AuthKey.p8"},
  fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}
```

Add `/priv/keys/` to `.gitignore`.

### Environment Variables (Production)

```elixir
# config/runtime.exs
config :pushx,
  apns_key_id: System.get_env("APNS_KEY_ID"),
  apns_team_id: System.get_env("APNS_TEAM_ID"),
  apns_private_key: System.get_env("APNS_PRIVATE_KEY"),
  apns_mode: if(System.get_env("APNS_SANDBOX") == "true", do: :sandbox, else: :prod),

  fcm_project_id: System.get_env("FCM_PROJECT_ID"),
  fcm_credentials: System.get_env("FCM_CREDENTIALS") |> JSON.decode!()
```

> **Tip:** For multiline keys (APNS .p8), set the env var directly from the file: `export APNS_PRIVATE_KEY="$(cat AuthKey.p8)"`

### Fly.io Secrets

```bash
fly secrets set APNS_KEY_ID="ABC123DEFG"
fly secrets set APNS_TEAM_ID="TEAM123456"
fly secrets set APNS_PRIVATE_KEY="$(cat AuthKey.p8)"
fly secrets set FCM_PROJECT_ID="my-project-id"
fly secrets set FCM_CREDENTIALS="$(cat firebase-service-account.json)"
```

Then use `System.fetch_env!/1` in `config/runtime.exs`:

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

### AWS Secrets Manager / Vault

```elixir
if config_env() == :prod do
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

You need: **Key ID**, **Team ID**, and a **Private Key (.p8 file)**.

#### Step 1: Get Your Team ID

1. Go to [Apple Developer Account](https://developer.apple.com/account)
2. Your **Team ID** is shown in the top-right corner (10 characters)

#### Step 2: Create an APNS Key

1. Go to [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/authkeys/list)
2. Click **Keys** > **+** (Create a new key)
3. Enter a name (e.g., "Push Notifications Key")
4. Check **Apple Push Notifications service (APNs)**
5. Click **Continue** > **Register**
6. **Download the .p8 file** (you can only download it once!)
7. Note the **Key ID** shown (10 characters)

### Google FCM Setup

You need: **Project ID** and a **Service Account JSON file**.

#### Step 1: Create/Open Firebase Project

1. Go to [Firebase Console](https://console.firebase.google.com/)
2. Create a new project or select an existing one
3. Note your **Project ID** in Project Settings

#### Step 2: Enable Cloud Messaging API

1. Go to [Google Cloud Console](https://console.cloud.google.com/)
2. Select your Firebase project
3. Go to **APIs & Services** > **Library**
4. Search for "Firebase Cloud Messaging API" and **Enable** it

#### Step 3: Create Service Account Key

1. In Firebase Console, go to **Project Settings** (gear icon)
2. Click **Service accounts** tab
3. Click **Generate new private key**
4. Save the JSON file securely

### Credential Rotation

APNS .p8 keys and FCM service accounts **don't expire**. When you need to rotate:

1. Generate new credentials in Apple/Google console
2. Update your secrets (Fly: `fly secrets set`, AWS: update in Secrets Manager)
3. Restart or redeploy your app
4. Revoke old credentials after all instances are updated

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

> Tokens are automatically truncated in telemetry metadata for privacy (first 8 + last 4 characters).

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

## Circuit Breaker

PushX includes an optional circuit breaker that temporarily blocks requests to a provider after consecutive failures. This prevents wasting resources on dead connections.

```elixir
config :pushx,
  circuit_breaker_enabled: true,
  circuit_breaker_threshold: 5,        # consecutive failures to trip
  circuit_breaker_cooldown_ms: 30_000  # ms before retrying
```

**States:**
- **Closed** — Normal operation, all requests flow through
- **Open** — Provider is failing, requests are immediately rejected with `{:error, %Response{status: :circuit_open}}`
- **Half-open** — After cooldown, one probe request is allowed. Success closes the circuit; failure re-opens it

Only `:connection_error` and `:server_error` responses count as failures. Invalid tokens and rate limits do not trip the circuit.

```elixir
# Check circuit breaker state
PushX.CircuitBreaker.state(:apns)
#=> :closed

# Manual reset
PushX.CircuitBreaker.reset(:apns)
```

---

## Health Check

Check provider configuration and circuit breaker status:

```elixir
PushX.health_check()
#=> %{
#=>   apns: %{configured: true, circuit: :closed},
#=>   fcm: %{configured: true, circuit: :closed}
#=> }
```

---

## Token Cleanup Callback

Automatically clean up invalid tokens from your database when a push fails with `:invalid_token`, `:expired_token`, or `:unregistered`:

```elixir
config :pushx,
  on_invalid_token: {MyApp.Push, :handle_invalid_token, []}
```

The callback receives `(provider, device_token, ...extra_args)` and runs asynchronously:

```elixir
defmodule MyApp.Push do
  def handle_invalid_token(provider, device_token) do
    MyApp.Tokens.delete_by_token(device_token)
    Logger.info("Removed invalid #{provider} token")
  end
end
```

---

## Troubleshooting

### `too_many_concurrent_requests` Error

This Mint HTTP/2 error means all streams on a connection are in use. It has two common causes with **opposite** fixes:

```
[error] [PushX.APNS] Connection error: %Mint.HTTPError{reason: :too_many_concurrent_requests}
```

**Cause 1: Stale connections (low-traffic apps)**

On cloud infrastructure (Fly.io, AWS, GCP), idle HTTP/2 connections can be silently dropped by load balancers or firewalls. The client doesn't know the connection is dead, so new requests on it hang or fail. PushX enables TCP keepalive to detect dead connections at the OS level, and automatically reconnects on connection errors during retry.

**Fix:** Reduce pool size to minimize idle connections:
```elixir
config :pushx,
  finch_pool_size: 2,
  finch_pool_count: 1
```

You can also force a reconnect manually:
```elixir
PushX.reconnect()
```

**Cause 2: Actual overload (high-traffic apps)**

If you're sending thousands of notifications per minute, the pool may genuinely run out of HTTP/2 streams.

**Fix:** Increase pool capacity and use rate limiting:
```elixir
config :pushx,
  finch_pool_size: 50,
  finch_pool_count: 4,
  rate_limit_enabled: true,
  rate_limit_apns: 2000,
  rate_limit_fcm: 2000
```

### `request_timeout` Error

```
[error] [PushX.APNS] Connection error: %Finch.Error{reason: :request_timeout}
```

1. **Increase timeouts** if connecting from distant regions (e.g., EU to US):
   ```elixir
   config :pushx,
     receive_timeout: 30_000,
     connect_timeout: 20_000
   ```

2. PushX automatically retries connection errors with exponential backoff (1s, 2s, 4s)

3. If this follows a `too_many_concurrent_requests` error, see the stale connections fix above

### Debugging Tips

Enable telemetry logging to monitor push performance:

```elixir
:telemetry.attach("pushx-debug", [:pushx, :push, :error], fn _, _, meta, _ ->
  Logger.warning("Push failed: #{meta.provider} - #{meta.status} - #{meta.reason}")
end, nil)
```

---

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

Built with care by [Cigno Systems AB](https://github.com/cignosystems)
