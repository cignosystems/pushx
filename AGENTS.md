# AGENTS.md

Guidance for AI coding assistants integrating **PushX** into a project. Read
this before suggesting code that uses this library — it captures the mental
model and the mistakes agents most often make.

> Modifying PushX itself? See `CONTRIBUTING.md` for repo layout and test
> commands.

## What PushX is

A single hex package (`{:pushx, "~> 0.13"}`) that sends push notifications to
**Apple APNS** and **Google FCM** over HTTP/2 — with JWT/OAuth handled
automatically. Concretely, what's in the box:

| Layer | Module | Purpose |
|-------|--------|---------|
| Unified API | `PushX` | One call sends to either provider |
| Provider APIs | `PushX.APNS`, `PushX.FCM` | Direct provider access for full control |
| Message builder | `PushX.Message` | Fluent struct for cross-provider payloads |
| Result | `PushX.Response` | Normalized result with semantic `:status` |
| Multi-tenant | `PushX.Instance` | Named runtime instances with their own credentials |
| Health/ops | `PushX.health_check/0`, `PushX.reconnect/0`, `PushX.CircuitBreaker` | |
| Testing | `PushX.Test`, `PushX.Test.Assertions` | `delivery: :test` records sends instead of sending |

There is **no setup beyond config + deps**. PushX starts its own HTTP/2 pools
(Finch) and OAuth processes (Goth) under its own supervisor — you do not add
anything to your application's supervision tree.

## Decision tree (which function to call)

```
single set of credentials in config?
├── yes → PushX.push(:apns | :fcm, token, msg, opts)
│            └── many tokens at once?  → PushX.push_batch/4 (list) or
│            │                            PushX.push_batch_stream/4 (lazy; big audiences)
│            └── only need :ok / :error? → PushX.push!/4
│            └── data-only (silent, FCM)? → PushX.push_data(:fcm, ...)
│            └── APNS silent push?       → PushX.push(:apns, ..., push_type: "background")
│            └── FCM topic / condition?   → PushX.push(:fcm, {:topic, "news"}, msg)
│            └── must not block on backoff? → add retry: :none to any call
└── no — multiple tenants / per-customer credentials at runtime
         → PushX.Instance.start(name, :apns | :fcm, config)
           then PushX.push(name, token, msg, opts)
```

## Mental model

- **It's a function-call API, not a process you message.** No `start_link`,
  no GenServer.call, no behaviour to implement. Just `PushX.push/4`.
- **Every send returns `{:ok, %PushX.Response{}}` or `{:error, %PushX.Response{}}`** —
  errors are still wrapped in the same struct so a single `case` handles both.
  Inspect `response.status` (an atom like `:sent`, `:invalid_token`,
  `:rate_limited`, `:circuit_open`) for what happened.
- **Token cleanup is your responsibility.** APNS/FCM tell you when a token is
  dead; PushX does not delete it from your DB. Either check
  `PushX.Response.should_remove_token?(response)` per call, or set
  `:on_invalid_token` config to a `{module, fun, args}` tuple. The callback
  is invoked asynchronously as `apply(module, fun, [provider, token | args])` —
  i.e. `provider` and `token` come first, followed by your `args` list.
- **Retries happen automatically** for connection errors, 5xx, and
  rate-limited responses. By default 3 attempts with exponential backoff
  starting at 10s (Google's recommended minimum), **blocking the calling
  process** (and, inside a batch, holding a concurrency slot). Disable
  per-call with `retry: :none` on any send function (returns the retryable
  failure immediately, with `retry_after` when known) — or use
  `PushX.APNS.send_once/3` / `PushX.FCM.send_once/3`.
- **FCM targets can be topics or conditions**: pass `{:topic, "news"}` or
  `{:condition, "'a' in topics && 'b' in topics"}` where the token goes.
  Bare topic name only (no `/topics/`); APNS rejects tuple targets with
  `:invalid_request`; topics never trigger `:on_invalid_token`.
- **Named instances are in-memory only** — not persisted across node
  restarts and per-VM. Start them on boot from your DB (a worker after
  `Repo`); `start/3` returns `{:error, :already_started}` on re-run.
- **`:not_configured` vs `:auth_error`**: a send against a provider with no
  credentials configured returns `status: :not_configured` (never retried);
  `:auth_error` means credentials exist but signing/OAuth failed or the
  provider rejected them.
- **The circuit breaker can short-circuit you.** If a provider has been
  failing, the breaker opens and `push/4` returns
  `{:error, %Response{status: :circuit_open}}` *without* hitting the network.
  Call `PushX.health_check/0` to inspect breaker state (static providers
  under `:apns`/`:fcm`, each named instance under `:instances`).
- **Test your app with `config :pushx, delivery: :test`** — sends are
  validated then recorded, not sent; assert with
  `import PushX.Test.Assertions` → `assert_pushed(%{provider: :apns, target: ^token})`,
  script provider errors with `PushX.Test.stub/1`. Don't mock `PushX.push/4`
  yourself and don't put real credentials in test config.
- **HTTP/2 pools are long-lived** — set `finch_pool_size` low (2–5) for
  low-traffic apps to avoid stale-connection issues on cloud infra (Fly.io,
  AWS NLB, GCP), or call `PushX.reconnect/0` if you suspect zombie sockets.

## Idiomatic patterns

### Send + handle every relevant outcome

```elixir
case PushX.push(:apns, token, "Hello", topic: "com.example.app") do
  {:ok, %PushX.Response{status: :sent, id: apns_id}} ->
    Logger.info("sent: #{apns_id}")

  {:error, %PushX.Response{} = resp} ->
    if PushX.Response.should_remove_token?(resp) do
      MyApp.Tokens.delete(token)            # token dead — clean up
    else
      Logger.warning("push failed: #{resp.status} #{resp.reason}")
    end
end
```

### Token cleanup via central callback (preferred for fleets)

```elixir
# config/runtime.exs
config :pushx, on_invalid_token: {MyApp.Tokens, :delete_by_token, []}

# MyApp.Tokens
def delete_by_token(provider, token) do
  Repo.delete_all(from t in Token, where: t.provider == ^provider and t.value == ^token)
end
```

PushX calls this in a spawned task on any response where
`should_remove_token?/1` is true. You do not need a per-call check after this.

### Batch send with token validation

```elixir
results = PushX.push_batch(:fcm, tokens, "Server maintenance in 10m",
                            concurrency: 100, validate_tokens: true)

# results :: [{token, {:ok | :error, %Response{}}}, ...] — one entry per input token
Enum.each(results, fn
  {_token, {:ok, _}}                                  -> :ok
  {token, {:error, resp}} ->
    if PushX.Response.should_remove_token?(resp), do: MyApp.Tokens.delete(token)
end)
```

`validate_tokens: true` rejects malformed tokens locally (no network round
trip) — the result list still has one entry per input, with status
`:invalid_token`.

### Multi-tenant with named instances

```elixir
# At app boot or whenever a tenant is provisioned:
PushX.Instance.start(:tenant_42_apns, :apns,
  key_id:      tenant.apns_key_id,
  team_id:     tenant.apns_team_id,
  private_key: tenant.apns_private_key,    # PEM string or {:file, path}
  mode:        :prod
)

# Then send through that named instance:
PushX.push(:tenant_42_apns, token, msg, topic: tenant.bundle_id)

# Hot-rotate credentials without restart:
PushX.Instance.reconfigure(:tenant_42_apns, private_key: new_pem)
```

Reserved instance names: `:apns` and `:fcm` (those resolve to the default
config-based pools — don't use as instance names).

### Web push (Safari = APNS, Chrome/Firefox/Edge = FCM)

```elixir
# Safari (APNS web push)
payload = PushX.APNS.web_notification("New article", "Just published",
                                       "https://example.com/p/123")
PushX.APNS.send(safari_token, payload, topic: "web.com.example.app")

# Chrome / Firefox / Edge (FCM webpush)
PushX.FCM.send_web(fcm_token, "New article", "Just published",
                    "https://example.com/p/123")
```

The APNS web-push topic is the **website push ID** (typically `web.<reverse-DNS>`),
not the iOS bundle ID.

## Common mistakes (do not do these)

- **Forgetting `topic:` for APNS.** APNS *requires* the bundle ID (or website
  push ID). Without it `push/4` returns
  `{:error, %Response{status: :invalid_request, reason: ":topic option is required"}}` —
  no network call is made. There is no per-config default.
- **Calling `push_data/4` for APNS.** It's FCM-only. For an APNS silent
  push, call `PushX.push(:apns, token, payload, push_type: "background", priority: 5, topic: ...)`
  — the function returns an explicit error explaining this.
- **Confusing the `:apns`/`:fcm` symbols with named instance atoms.** Both
  work as the first argument to `push/4`, but mean different things. `:apns`
  and `:fcm` use *config-based* credentials and are reserved; any other atom
  must first be started via `PushX.Instance.start/3`.
- **Wrong `apns_mode`.** Sandbox tokens fail silently in `:prod` mode and
  vice versa — APNS returns `BadDeviceToken`, which PushX surfaces as
  `:invalid_token`. Make sure dev/sandbox tokens go to `:sandbox` and TestFlight
  / App Store tokens go to `:prod`.
- **Not handling `should_remove_token?/1` (or setting `:on_invalid_token`).**
  Dead tokens (uninstalls, app reinstalls, expired) accumulate forever in
  your DB and waste a network call each. APNS in particular *requires* you
  to stop sending to dead tokens — providers may rate-limit you otherwise.
- **Treating `push_batch/4` results as parallel lists.** It returns
  `[{token, result}, ...]` — a list of pairs, not a separate `tokens` list
  and `results` list. Match on the pair shape.
- **Ignoring the circuit breaker.** A `:circuit_open` response means PushX
  is *not* calling the provider right now. Don't retry in a tight loop;
  wait, then call `PushX.health_check/0` to check breaker state.
- **`fcm_credentials` as a string.** It must be a *decoded* JSON map (or
  `{:file, path}`). Storing the JSON as a single env var works only if you
  decode it: `FCM_CREDENTIALS |> JSON.decode!()` in `runtime.exs`.
- **Multiline `apns_private_key` mangled by env.** Env vars containing
  newlines often arrive as literal `\n`. Either set the env to the file
  contents directly (`export APNS_PRIVATE_KEY="$(cat AuthKey.p8)"`) or use
  the `{:file, "priv/keys/AuthKey.p8"}` tuple form.
- **Web-push topic = bundle ID.** Safari web push needs the *website push
  ID* (`web.com.example.app`), not the iOS bundle (`com.example.app`).
- **Restarting your supervision tree to "fix" stale HTTP/2 connections.**
  Just call `PushX.reconnect/0` — it terminates the Finch pool and lets the
  PushX supervisor start a fresh one. This is also called automatically by
  the retry logic on connection errors.

## Decision helpers

- **`push/4` vs `push!/4`:** use `push/4` whenever you might want to act on
  the response (token cleanup, logging the APNS message ID, etc.). Use
  `push!/4` only for fire-and-forget (e.g., low-priority marketing).
- **APNS `:priority`:** `10` (immediate, default) wakes the device; `5`
  defers to a power-friendly time. Apple *requires* `5` for some
  notification types — check the APNS docs for `apns-priority` rules.
- **APNS `:push_type`:** `"alert"` (default, user-visible), `"background"`
  (silent / data-only — must use `priority: 5`), `"voip"` (CallKit),
  `"complication"`, `"liveactivity"`, etc.
- **FCM data-only vs notification:** `push_data/4` sends `data` only — your
  app's onMessage handler runs even when the app is killed. `push/4` sends
  a `notification` block — the system tray shows it without your code
  running. Use both keys together (via `push/4` with a map containing both)
  for hybrid behavior.
- **`finch_pool_size`:** for < 100 pushes/min, **2** is the sweet spot —
  fewer idle connections to go stale on cloud infra. Scale up (25–50) only
  for genuine throughput.

## Where to find authoritative answers

- **Public API:** [hexdocs.pm/pushx](https://hexdocs.pm/pushx) — `@doc`
  strings on every public function
- **Worked examples and config:** `README.md` (it's thorough — Quick Start,
  Configuration, Troubleshooting, Telemetry, Circuit Breaker, Health Check,
  Token Cleanup all covered)
- **Recent behavior changes:** `CHANGELOG.md`
- **Provider docs:**
  [APNS](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns) /
  [FCM HTTP v1](https://firebase.google.com/docs/cloud-messaging/migrate-v1)
