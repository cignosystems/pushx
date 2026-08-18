# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Test delivery mode (`config :pushx, delivery: :test`) and `PushX.Test`** — the way to test an application that sends pushes without mocking PushX or contacting the providers. Every send (`PushX.push/4`, `push_data/4`, batches and `push_batch_stream/4`, `PushX.APNS`/`PushX.FCM` directly, and named instances) runs its full local validation (required `:topic`, target format, `:mode`, payload encoding and size limits) and is then recorded and answered `{:ok, %Response{status: :sent, id: "test-N"}}` — no credentials, no network, no retries. Records are scoped to the test process via `$callers` (so `async: true` and batch workers just work) and carry the decoded wire payload, the merged send options, the instance name, and the result. `PushX.Test.Assertions` provides `assert_pushed/1`, `refute_pushed/1` and `assert_no_pushes/0` (match patterns with pins, `assert_receive`-style, with failure messages listing what was recorded); `PushX.Test.pushes/0`, `last_push/0`, `clear/0`; `PushX.Test.stub/1` scripts provider responses per test (e.g. `{:error, :unregistered}` for a token — `:on_invalid_token` and `should_remove_token?/1` then behave exactly as for a real response); and `PushX.Test.apns_private_key/0` / `fcm_credentials/0` supply throwaway keys for starting named instances in tests. The same telemetry events are emitted as for a real send. PushX's own suite now uses those key helpers instead of its private fixtures.

- **`apns_id:` option** (APNS, static and instances): your own canonical UUID for the notification, sent as the `apns-id` header and echoed back by Apple in `response.id` — the handle for tracing a push end-to-end in delivery logs and the Push Notifications Console. Validated locally (`:invalid_request` for anything but a canonical UUID). Added to the `option()` typespec.
- **FCM `validate_only: true`** dry run on `PushX.push/4`, `push_data/4`, `PushX.FCM.send/3`, `send_data/3` and named instances: FCM validates the message (token registration, payload) without delivering it; a `{:ok, %Response{status: :sent}}` then means "would have been accepted", errors are the real ones. Applied at the request-envelope level so every builder honours it.
- **`PushX.Message` builder: iOS specifics and localization** — `subtitle/2`, `mutable_content/1`, `content_available/1`, `interruption_level/2` (`:passive | :active | :time_sensitive | :critical`), `relevance_score/2`, `localized_title/3`, `localized_subtitle/3`, `localized_body/3`. APNS gets `alert.subtitle`, `mutable-content`, `content-available`, `interruption-level`, `relevance-score` and the `*-loc-key`/`*-loc-args` keys; FCM gets `android.notification.{title,body}_loc_key/args` (new in `to_fcm_android/1`) and an automatic `apns` override for the iOS-only fields (new `Message.to_fcm_apns/1`), deep-merged under any explicit `:apns` option — explicit keys win, nested maps merge, so an `apns: %{"headers" => ...}` no longer wipes a derived payload. Defaults are inert: an unset message produces exactly the payloads it did before.
- **FCM topic subscription management** — `PushX.FCM.subscribe/3` / `unsubscribe/3` and `PushX.subscribe/4` / `unsubscribe/4` (static `:fcm` or a named FCM instance) call the Instance ID API (`iid/v1:batchAdd` / `batchRemove`) with the same OAuth as sends, auto-chunk at Google's 1 000-token limit, and return one `{token, :ok | {:error, code}}` per token in input order (`"NOT_FOUND"` = unregistered token); request-level failures come back as `{:error, %Response{}}`. Topic name and token list are validated locally; `retry:` applies; test delivery mode reports every token `:ok` without contacting anything. `PushX.URLs.fcm_topic_url/1` honours `:fcm_url_override`.
- **`PushX.Telemetry.metrics/0`** — a curated `Telemetry.Metrics` list (requires the new *optional* `telemetry_metrics` dependency): sends by provider, errors by provider/status, exceptions by provider/kind, send-latency distributions with provider-tuned buckets, retry attempts and delays — never tagged by token. Counters are bound to real measurements so every reporter counts them; a ConsoleReporter smoke test guards the wiring.

### Changed
- **CI dependency audit runs with no ignored advisories** — the two cowlib advisory IDs pinned since 0.12 (`GHSA-w4f7-4cxr-rv3c`, `GHSA-g2wm-735q-3f56`) have since been re-scoped upstream to cowboy < 2.16 / cowlib ≤ 2.16.1, neither of which we lock, so `mix deps.audit` passes clean and the `--ignore-advisory-ids` flag is gone. (hex.pm's own `mix hex.audit` feed still lists three EEF-CVEs against cowlib 2.19.0 — the latest release, test-only via Bypass, no fix published; that tool is not part of CI because it offers no way to acknowledge them.)
- **CI toolchain and matrix brought up to date** — the primary toolchain (quality, coverage, Dialyzer, docs, and the release workflow) is now Elixir 1.20 / OTP 29, and the test matrix spans the supported floor to the latest stable: 1.20/29, 1.20/28, 1.19/28, 1.19/27, 1.18/26 (previously topped out at 1.19/28). No code changes were needed; the supported range (`elixir: "~> 1.18"`, OTP 26+) is unchanged and now stated in the README. CI also sets `ERL_COMPILER_OPTIONS="[nowarn_deprecated_catch]"` to silence OTP 29's old-style `catch` deprecation warnings coming from `yamerl` 0.10.0 (an Erlang dependency of `mix_audit`, dev/test only, no fixed release available); it only affects Erlang-source compilation, so PushX's own warnings-as-errors gate is unchanged.

## [0.13.0] - 2026-08-18

The "last shape changes before 1.0" release: every public-API decision that
would be breaking after 1.0 is made here, additively where possible. Two items
are *Breaking (minor)* and are marked as such.

### Added
- **FCM topics and conditions** — pass `{:topic, "news"}` or `{:condition, "'news' in topics && 'sports' in topics"}` wherever a device token goes: `PushX.push/4`, `push_data/4`, `push_batch/4`, `PushX.FCM.send/3`/`send_data/3`, and named FCM instances (`t:PushX.FCM.target/0`). Topic names are validated locally (bare name, `[a-zA-Z0-9-_.~%]`; `:invalid_request` otherwise), telemetry labels them `topic:…`/`condition:…`, and they never trigger `:on_invalid_token`. APNS returns `:invalid_request` with a clear message for tuple targets instead of `:invalid_token`.
- **`retry: :blocking | :none` per-call option** on every send function (static, batch, and instances). `:blocking` is the unchanged default; `:none` makes exactly one attempt and returns retryable failures immediately with `retry_after` set when the provider supplied it, so callers can requeue on their own schedule instead of parking a process — or a batch concurrency slot — in backoff. A `:connection_error` under `:none` still triggers the coalesced automatic pool reconnect (only the retry is skipped), and batches with `retry: :none` size their default per-task timeout to the 30 s floor instead of the retry budget (`Config.batch_timeout_ms/1`). `true`/`false` are accepted as aliases (older APNS docs described the option as a boolean, and the key used to be silently ignored — it now has an effect); any other value returns `:invalid_request` without sending. Added to the `option()` typespecs. Documented on `PushX.push/4` and in the README's retry section.
- **`PushX.push_batch_stream/4`** — lazy `push_batch/4`: same options and semantics, but accepts any enumerable (e.g. a `Repo.stream`) and yields `{token, result}` pairs in input order, each as soon as it (and everything before it) has completed, with bounded memory. The input is enumerated exactly once (killed/crashed tasks recover their token via `zip_input_on_exit`), so one-shot sources such as `Repo.stream/2` are safe. `push_batch/4` is now `push_batch_stream/4 |> Enum.to_list()`, and its docs explain when to chunk or stream large audiences.
- **`PushX.health_check/0` reports named instances** under a new `:instances` key — `%{name => %{provider, enabled, circuit}}` — with each instance's own circuit-breaker state, so a multi-tenant deployment can see one tenant's outage without it hiding behind the static providers.
- **`:fcm_token_fetcher` is now a documented option** ("bring your own OAuth"): an `{module, function, args}` tuple, invoked as `apply(m, f, [goth_name | args])`, that replaces the `PushX.Goth` process PushX would otherwise start (to reuse your own Goth, wrap it: `def fetch(_goth_name), do: Goth.fetch(MyApp.Goth)`). It applies to the **static** configuration only — `:fcm_credentials` becomes optional there and `Config.fcm_configured?/0` accounts for it. Named FCM instances authenticate with their own `:credentials` (Goth) or a new per-instance **`:token_fetcher`** config key (validated at `start/3`; makes `:credentials` optional for that instance); a global fetcher never silently takes over a tenant's OAuth. The fetcher call is guarded on the send path: a fetcher that raises, exits, or returns `{:error, _}` yields a retryable `:connection_error`, one that returns any other shape yields `:auth_error` — never an exception. Previously an undocumented test seam.
- **`bench/send_bench.exs`** — manual micro-benchmark (per-send overhead over a raw HTTP request, batch throughput against a local stub) with the baseline recorded in its header (~6 µs PushX overhead per send; ~37k sends/s stub-bound). Run with `MIX_ENV=test mix run bench/send_bench.exs`.

### Changed
- **`:not_configured` response status (Breaking, minor)** — sending against a provider with no credentials configured now returns `{:error, %Response{status: :not_configured}}` (never retried) instead of `:auth_error`: `PushX.push(:apns, …)` without `:apns_key_id`/`:apns_team_id`/`:apns_private_key`, `PushX.push(:fcm, …)` without `:fcm_project_id`, or without any OAuth token source (no `:fcm_credentials` and no `:fcm_token_fetcher`). If credentials *are* configured but the OAuth process is momentarily gone (crashed/restarting Goth, static or an instance's), that is reported as a retryable `:connection_error`, not as misconfiguration. `:auth_error` now means "credentials exist but signing/OAuth failed, the provider rejected them, or a token fetcher misbehaved". Callers with an exhaustive `case` on `status` need a new clause. `:provider_disabled` — long present in the typespec — is now listed in the `PushX.Response` docs and README table too, together with `:circuit_open`.
- **`Response.status` growth policy documented** — the status set only grows, and any new atom is called out as *Breaking (minor)*; this is the last planned addition before 1.0.
- **APNS delivers to device tokens only** — non-binary targets (topics/conditions are FCM features) now fail with `:invalid_request` and an explanatory reason on both the static and instance paths, rather than `:invalid_token`.
- **Named-instance lifecycle documented** (`PushX.Instance` moduledoc, README): instances live in memory only — not persisted across node restarts, per-VM, start them on boot from your own source of truth; `start/3` returns `{:error, :already_started}` on re-run so that is safe. Behaviour is unchanged.
- **Tagline and hex description rewritten** to say what PushX actually does for you ("APNS and FCM in one call; retries, circuit breaker, dead-token cleanup and telemetry built in; per-tenant credentials at runtime; nothing to add to your supervision tree") instead of listing HTTP/2 and JWT, which are table stakes.
- **README performance guidance** — retries hold batch concurrency slots (use `retry: :none` for large audiences); chunk `push_batch/4` input above ~10k tokens or use `push_batch_stream/4`.
- **One batch engine** — `PushX.push_batch/4`, `push_batch_stream/4`, `PushX.APNS.send_batch/3` and `PushX.FCM.send_batch/3` now share `PushX.Batch` (internal). The three former copies had already drifted (different concurrency/timeout defaults, and the APNS copy classified an FCM topic tuple as `:invalid_token` under `validate_tokens: true`, i.e. "remove this token"); all four now validate binary tokens only, enumerate their input exactly once, honour `:batch_concurrency`, and map timeouts/crashes identically. `Token.validate/2` is total (any non-binary → `{:error, :invalid_format}`).
- **finch ≥ 0.22 note** — its HTTP/2 pool now traps exits, so a pool shutdown (`PushX.Instance.stop/1`, `reconfigure/2`, `PushX.reconnect/0`) waits for an in-flight connection attempt to finish (up to the instance's `connect_timeout`, default 10 s) instead of killing it. Harmless in steady state; visible only when a pool is mid-connect to an unreachable host.
- **`Instance.start/3` with a `:private_key` of the wrong shape** (`nil`, a number, an unknown tuple) now returns `{:error, {:invalid_private_key, ":private_key must be a PEM string, {:file, path} or {:system, \"ENV_VAR\"}, got: …"}}` instead of a `FunctionClauseError` message.
- **Dependencies**: `finch` lock 0.21 → 0.23 (the `~> 0.21` requirement is unchanged and already allowed it; the suite and Dialyzer pass against 0.23's reworked HTTP/2 pool registration and error types), `ex_doc` 0.40.1 → 0.40.3. The two cowlib advisory ignores in CI remain — cowlib 2.19.0 is still the latest release.

## [0.12.0] - 2026-08-16

### Security
- **FCM `INVALID_ARGUMENT` no longer classified as `:invalid_token`** — it now maps to `:invalid_request`. FCM returns `INVALID_ARGUMENT` for *any* malformed request (oversized fields, reserved `data` keys, bad `android`/`apns`/`webpush` blocks), not just bad tokens. Under the old mapping, a single developer-side payload bug produced `:invalid_token` for every recipient, and with the documented `:on_invalid_token` auto-cleanup pattern wired up, would have deleted every device token in the caller's database. `UNREGISTERED` and `SENDER_ID_MISMATCH` — the codes that genuinely mean "drop this token" — are unchanged. **Breaking (minor):** callers matching on `status: :invalid_token` for FCM 400s should match `:invalid_request` instead.
- **Unvalidated per-instance APNS credentials could crash the shared `PushX.JWTCache` and escalate to a cross-tenant outage** — `Instance.start/3` and `reconfigure/2` only checked that `:private_key` was *present*. A malformed PEM (or a `{:file, path}` whose file is missing / `{:system, VAR}` unset) made `Joken`/`JOSE` raise `badarg` on the first push — inside `PushX.JWTCache`'s `handle_call`, a GenServer shared by every instance and the default APNS path. The caller crashed instead of receiving the documented `{:error, %Response{}}`, the cache's ETS table (holding every tenant's cached JWT) was destroyed with it, and three such pushes within five seconds exceeded `PushX.Supervisor`'s default restart intensity, stopping the `:pushx` application — in a `start_permanent` release, the whole node. One tenant's bad credential became an availability failure for all tenants. Fixed in three layers:
  - `Instance.start/3` now eagerly resolves the APNS private key and performs a test sign, returning `{:error, {:invalid_private_key, reason}}` instead of accepting a credential that can never sign. `reconfigure/2` validates the merged config *before* stopping the old instance, so a bad rotation leaves the running instance untouched.
  - `generate_jwt` in both `PushX.APNS` and `PushX.Instance` now rescues exceptions from key resolution and signing, returning the documented `{:error, reason}` tuple.
  - `PushX.JWTCache` wraps the caller-supplied generator in `try/rescue/catch`, so no generator — raise, throw, exit, or bad return shape — can crash the shared cache process.

- **Unusable FCM credentials on a named instance could take down every named instance** — `Instance.start/3` only checked that `:credentials` was *present*. Goth eagerly exchanges the service-account credentials with Google when it starts, so a map missing `"private_key"`/`"client_email"` (or holding a PEM that cannot sign RS256) made Goth raise on that prefetch and crash-loop; the restarts escalated through the instance supervisor to `PushX.Instance.DynamicSupervisor`, whose restart wiped the instance registry and killed *all* tenants — while `start/3` had already returned `{:ok, name}`. This is the FCM twin of the APNS credential issue above and gets the same fix: `start/3` and `reconfigure/2` now decode the credentials, require both keys, and perform a test RS256 signature, returning `{:error, {:invalid_credentials, reason}}` before anything is started (a bad rotation leaves the running instance untouched).
- **`PushX.push(:fcm, …)` no longer exits the caller when FCM is not configured** — with no `PushX.Goth` process, `Goth.fetch/1` exited the calling process with `{:noproc, …}` instead of honouring the documented `{:error, %Response{}}` contract. The static and instance FCM paths now return `{:error, %Response{status: :auth_error, reason: "FCM is not configured: …"}}` (non-retryable); transient OAuth token-endpoint failures still map to the retryable `:connection_error`.

### Added
- **Coverage gate and hardened CI/release workflows** — `mix test --cover` enforces a 94% line-coverage threshold (`test_coverage: [summary: [threshold: 94]]` in `mix.exs`) and now runs as a dedicated CI job with the HTML report uploaded as an artifact; `mix hex.build` checks the package in the quality job; docs build with `--warnings-as-errors`; workflows run with `permissions: contents: read` and CI also runs weekly so newly published dependency advisories fail the build without a push. The release workflow no longer publishes on a bare tag: it first verifies the tag matches `mix.exs`'s `@version` and runs the full suite with the coverage gate.
- **Docs logo works on the dark theme** — the hexdocs sidebar logo is now an icon-only, square, transparent PNG (`assets/pushx_icon.png`, also used as the favicon). ExDoc renders the logo at 48×48 next to the project name it already prints, and the previous wide wordmark image had an opaque white background baked in (no alpha channel), which showed as a white block on the dark theme. The README wordmark (`pushx_logo.png`) is likewise transparent now, with the "PushX" lettering recoloured to the brand gradient so it reads on GitHub's, hex.pm's and hexdocs' light and dark themes alike.
- **Property-based tests** (`stream_data`, test-only) for the pure, input-shaped parts of the library: `PushX.Token.validate/2` (any even-length 64–512-char hex token is valid; length/format failures are classified correctly; never raises on arbitrary binaries), the `PushX.Message` payload builders and `PushX.FCM.build_message/3` (always JSON-encodable, `aps` can never be overwritten by caller data, FCM `data` values are always strings), `PushX.Response` error classification (total functions; unknown FCM codes can never trigger token removal), `PushX.HTTP.parse_retry_after/1` (nil or a non-negative integer for any header value), and `PushX.Config.batch_timeout_ms/0` (never below the 30 s floor, always covers the worst-case retry cycle).
- **Credo now runs in CI** (`mix credo --strict`) alongside Dialyzer, with a checked-in `.credo.exs`. The sweep it triggered: `Response.apns_reason_to_status/1` rewritten as a map lookup, two single-branch `cond`s converted to `if`, and alias ordering fixed.
- **CI dependency audit switched from `mix hex.audit` to `mix_audit`** — cowlib 2.19.0 (a test-only dependency via Bypass) has two published advisories with no fixed release, which made the un-ignorable `hex.audit` step permanently red. `mix deps.audit` pins exactly those two advisory IDs (the response-splitting one is mitigated downstream by cowboy ≥ 2.16, which is locked); the ignores are documented in the workflow and should be removed when a fixed cowlib ships.

### Fixed
- **Batch sends no longer kill retrying tasks mid-backoff by default** — the per-task `:timeout` in `PushX.push_batch/4`, `PushX.APNS.send_batch/3`, and `PushX.FCM.send_batch/3` defaulted to a flat 30 s, while a single send's blocking retry cycle can legitimately take ~3 minutes with the default retry config (3 attempts, up to 60 s delays). A retrying batch task was therefore killed mid-backoff and reported as a timeout even though a later attempt would have succeeded. The default is now `PushX.Config.batch_timeout_ms/0`, computed from the retry config (`attempts × (receive_timeout + pool_timeout) + (attempts − 1) × max(retry_max_delay_ms, 60 s rate-limit delay)`, floor 30 s; plain 30 s when retries are disabled). An explicit `:timeout` still always wins. **Breaking (minor):** with retries enabled, a hung batch task is now killed after ~180 s (default config) instead of 30 s — pass `timeout: 30_000` to keep the old behavior.
- **Low-severity hardening sweep** (L1–L7 from the v0.11.0 review):
  - APNS token validation no longer hard-codes 64 characters (Apple warns token length may change): any even-length hex string of 64–512 chars now passes `PushX.Token.validate/2`.
  - `verify: :verify_peer` is set explicitly on every HTTPS pool (static and instance) so a future refactor can't silently disable TLS peer verification — this was already Mint's default, now it's pinned.
  - The `:on_invalid_token` callback now runs under `PushX.TaskSupervisor` instead of an unsupervised `Task.start`, so a crashing cleanup callback is logged with a stacktrace instead of dying silently.
  - `PushX.Retry.retryable?/1` now delegates to `PushX.Response.retryable?/1` (the logic existed in both places and could drift).
  - Documented that `Message.to_apns_payload/1` injects `"sound": "default"` for titled messages, and how to opt out.
- **Circuit breaker no longer serializes every send result through its GenServer** — `record_success/1` previously issued a `GenServer.call` per successful send, making the breaker process a throughput chokepoint at high send rates. In steady state (`:closed`, zero failures) a success changes nothing, so it now checks that with one lock-free ETS read and skips the round-trip entirely — the breaker process sees no traffic at all on the healthy hot path. State *transitions* (failure counting, resets after failures, probe results) remain fully serialized through the GenServer as before. The elision can race a concurrent failure, which at worst opens the breaker one failure earlier than the configured threshold; the trade-off is documented on `record_success/1`.
- **Circuit breaker now admits exactly one half-open probe** — the open→half_open transition was a read-modify-write on ETS performed in the *caller* process, so under concurrency multiple requests could each flip the state and all be admitted as "probes", defeating the point of half-open. The transition now runs inside the breaker's GenServer (the hot allow-path remains a lock-free ETS read; only the rare transition takes the call), other requests are rejected while a probe is in flight, and a probe that never reports back (e.g. its task was killed) is replaced after a full cooldown instead of wedging the breaker.
- **Rate limiter is now race-free (single atomic counter per window)** — the old implementation did an ETS lookup followed by a conditional increment/insert: concurrent callers could all pass the check and overshoot the limit, and two callers hitting the "window expired" branch clobbered each other's `:ets.insert`, resetting the count and letting far more than the limit through. Counters are now keyed `{key, window_id}` and bumped with one atomic `:ets.update_counter/4` — there is no separate check step to race. The moduledoc also stops claiming a "sliding window": it is and was a **fixed** window, now documented as such (and as best-effort, which client-side limiting inherently is).
- **Background/silent APNS pushes now default to `apns-priority: 5`** — Apple requires priority 5 for `apns-push-type: background`; the previous unconditional default of 10 produced an invalid request unless the caller remembered `priority: 5` themselves. When `push_type: "background"` is set and no explicit `:priority` is given, PushX now sends 5. Explicit `:priority` always wins. Header building is shared between the static and instance paths (`PushX.APNS.build_headers/3`).
- **Named instances no longer bypass the hardening the static path has** — three drift bugs closed by extracting shared helpers:
  - Instance sends now pass through the same circuit-breaker + rate-limiter gate as `PushX.APNS`/`PushX.FCM` (new internal `PushX.SendGate`). Breakers are keyed by instance name so one tenant's failing pool can't open the breaker for others; rate limits count per instance using the provider-level config.
  - Instance requests now go through the shared `PushX.HTTP.finch_request/4`, which converts Finch's NimblePool `CaseClauseError` (e.g. `:connection_process_went_down`) into a retryable `:connection_error` — the headline v0.11.0 fix that the instance path had missed, where it still crashed the calling task.
  - The instance FCM builder now delegates to `PushX.FCM.build_message/3`, restoring the `apns` override key that the instance copy silently dropped (iOS-via-FCM overrides vanished on named instances).
- **Automatic pool reconnects are now coalesced instead of cascading** — the retry logic restarts the shared Finch pool on the first connection error of a send, but under load (e.g. a network blip during a `push_batch` of thousands) every concurrent task observed the error and every one of them restarted the pool, killing all other in-flight connections and amplifying a brief blip into a sustained outage. The new `PushX.ReconnectGuard` grants at most one automatic restart per pool per cooldown window (default 5 s, `config :pushx, reconnect_cooldown_ms: ...`), keyed separately for the static pool and each named instance. Manual `PushX.reconnect/0` calls are not gated.
- **`PushX.Message` `priority/2`, `ttl/2`, and `collapse_key/2` now actually reach the wire** — these documented builder setters were silently dropped: neither `to_apns_payload/1` nor the FCM builders ever read them, so `Message.new() |> Message.ttl(3600) |> Message.priority(:normal)` sent a notification with none of that applied. They now translate to APNS headers (`apns-priority`, `apns-expiration` — computed from `ttl` seconds, `apns-collapse-id`) and to the FCM `android` block (`priority`, `ttl`, `collapse_key`) on both the static and instance paths, via the new public helpers `Message.to_apns_options/1` and `Message.to_fcm_android/1`. Explicit call-site opts always win over struct-derived values. **Breaking (minor):** `%Message{}.priority` now defaults to `nil` ("use the provider's default") instead of `:high`, so an unset struct can never fight provider rules such as APNS requiring priority 5 for background pushes; callers who relied on reading `.priority` from a fresh struct should set it explicitly.
- **A crashing batch task no longer takes down the whole batch — or the caller** — batch sends used `Task.async_stream`, which links tasks to the calling process: a task that raised (rather than returning an error tuple) killed the caller outright, and even a trapped exit would have hit a result aggregator that only matched `{:ok, _}` and `{:exit, :timeout}`. Batches now run under a dedicated `Task.Supervisor` via `async_stream_nolink`, and the aggregators in `PushX.push_batch/4`, `PushX.APNS.send_batch/3`, and `PushX.FCM.send_batch/3` map any non-timeout task exit to `{token, {:error, %Response{status: :unknown_error}}}`, preserving per-token isolation.
- **APNS provider-token (JWT) rejections now self-heal instead of causing up to ~50 minutes of failures** — Apple's `ExpiredProviderToken`, `InvalidProviderToken`, `MissingProviderToken`, and `TooManyProviderTokenUpdates` reasons previously fell through to `:unknown_error`: not retryable, and nothing invalidated the cached JWT, so every send failed until the 50-minute cache TTL rolled over (clock skew, key rotation, or Apple expiring the token early all trigger this). They now classify as `:auth_error`, and for the first three the send path invalidates the cached JWT and retries once with a freshly signed one (both the static `PushX.APNS` path and named instances). `TooManyProviderTokenUpdates` deliberately does *not* regenerate — minting JWTs faster is exactly what that error is complaining about.
- **The test suite now exercises the real send paths** — the FCM, APNS, batch, facade, and named-instance "HTTP integration" tests were asserting against hand-copied re-implementations of the send pipeline living inside the test files, so `PushX.FCM.send/3`, `PushX.push/4` and the whole `PushX.Instance` send path had effectively zero coverage through their public API. Two internal, test-only seams close that gap: `:fcm_url_override` (mirrors the existing `:apns_url_override`) and `:fcm_token_fetcher` (a `{module, function, args}` replacement for `Goth.fetch/1`; when set, named FCM instances do not start a Goth process). Line coverage rose from 65% to 94% and the 90% coverage threshold is now enforced in `mix test --cover`. Neither seam is documented for production use.
- **Test fixture APNS key was on the wrong curve — and is no longer committed at all** — the test key in `test_helper.exs` was a secp256k1 key, which JOSE cannot sign ES256 with (APNS requires P-256); the suite never noticed because JWT generation was only exercised lazily at push time. Both the APNS P-256 key and the FCM RSA service-account key are now generated fresh for every test run instead of being checked in, so secret scanners have nothing to flag and the keys are provably tied to nothing.
- **CI actions bumped to their Node 24 majors** (`actions/checkout@v7`, `actions/cache@v6`, `actions/upload-artifact@v7`) to clear the Node.js 20 deprecation warnings on every job.

## [0.11.0] - 2026-05-07

### Documentation

- `AGENTS.md` — usage guide for AI coding assistants integrating PushX into
  projects: mental model (function-call API, no supervision-tree setup),
  decision tree (`push` / `push_batch` / `push_data` / instances), idiomatic
  patterns (token cleanup via `:on_invalid_token`, multi-tenant via
  `PushX.Instance`, web push topic IDs), and a curated list of mistakes
  commonly made (forgetting APNS `topic:`, `push_data` on APNS, mode
  mismatch, `fcm_credentials` as raw string, multiline `apns_private_key`
  via env). Shipped in the hex package and rendered on hexdocs.
- `CONTRIBUTING.md` — repo orientation for contributors: layout, test
  commands, conventions for error semantics and telemetry. `CLAUDE.md` is a
  symlink to `AGENTS.md` for tool compatibility.
- README banner pointing AI assistants at `AGENTS.md`.

### Fixed
- **APNS/FCM crash on transient Finch pool errors** — Finch's outer case in `lib/finch.ex:516` only matches `{:ok, …}` or the 3-tuple `{:error, err, _acc}` shape. When NimblePool returns a 2-tuple error — `{:error, :connection_process_went_down}` (HTTP/2 connection process death under concurrent-request-limit pressure) is the one observed in production, but the same pattern can produce other atom reasons — Finch raises `CaseClauseError` on itself. The exception escaped past `PushX.Retry`, killed the sending Task, and (in batch sends with caller-side `Enum.each`) silently skipped every recipient after the failing one. Now rescued in both `PushX.APNS` and `PushX.FCM`: any `CaseClauseError{term: {:error, reason}}` where reason is an atom is converted to a retryable `Response.error(_, :connection_error, _)`, so `PushX.Retry` handles reconnection normally. The previous narrow rescue only matched the literal `:connection_process_went_down` term and reraised any other 2-tuple shape.
- **APNS payload corruption when custom data uses an atom `:aps` key** — `Message.to_apns_payload/1`, `APNS.notification_with_data/4`, `APNS.silent_notification/1`, and `APNS.web_notification_with_data/5` previously stripped only the string `"aps"` key from caller data. A map containing both atom `:aps` and the constructed string `"aps"` was JSON-encoded with two `aps` keys, which APNS could reject or interpret unpredictably. All four functions now drop both `"aps"` and `:aps` from custom data.
- **APNS URL injection via unvalidated device tokens** — Device tokens were interpolated directly into the request URL (`/3/device/<token>`). A token containing `/`, `?`, `#`, or whitespace could redirect the request to an unintended path. `APNS.send/3`, `APNS.send_once/3`, and the named-instance APNS path now reject tokens that contain anything other than alphanumerics, underscore, or hyphen with `{:error, %Response{status: :invalid_token}}`.
- **`PushX.push_data/4` silently produced an invalid APNS payload for APNS named instances** — Calling `push_data(:my_apns_instance, …)` previously routed through `push/4` with a `%{"data" => …}` map, which APNS doesn't understand. Now rejected with `{:error, %Response{status: :invalid_request, provider: :apns}}` and a message pointing at `push/4` with `push_type: "background"` for APNS silent push.
- **JWT refresh could deadlock if the lock holder was killed** — The previous APNS JWT cache used `:atomics` as a mutex with `try/after` to release. If the holder was killed forcibly (e.g. `Process.exit(pid, :kill)`), the `after` clause did not run and every subsequent JWT request failed indefinitely with `"JWT refresh timeout after 10 attempts"`. The cache is now a supervised GenServer (`PushX.JWTCache`) with lock-free ETS reads and serialized refresh through `GenServer.call/3`. A killed refresher only delays callers until the supervisor restarts the process.
- **APNS empty-string `:topic` was forwarded to Apple** — Treating `""` as a valid topic produced a remote `MissingTopic` error. Both static and named-instance APNS paths now treat `nil` and `""` as missing and return `:invalid_request` locally.
- **Invalid APNS `:mode` raised `FunctionClauseError`** — A typo'd `apns_mode` (e.g. `:production`) crashed the sending Task past the `try/rescue` (which only catches `CaseClauseError`). Mode is now validated upfront and returns `{:error, %Response{status: :invalid_request}}` cleanly.
- **`push_batch/4` with `:validate_tokens` silently dropped invalid tokens** — Callers got a result list shorter than their input list with no signal of which tokens were skipped, so iterating in lockstep (e.g. to mark tokens) misaligned. Invalid tokens now get `{:error, %Response{status: :invalid_token, reason: "Invalid token format"}}` instead, so the result list always matches the input length. Same option is now honored by `APNS.send_batch/3` and `FCM.send_batch/3`.
- **`HTTP.stringify_map/1` raised `Protocol.UndefinedError` on nested maps/lists** — The previous `to_string(v)` worked only for binaries, atoms, and numbers. A nested map or list as an FCM `data` value crashed the calling process past the `try/rescue`. Nested maps and lists are now JSON-encoded so they survive transport as strings; PIDs and other non-stringable terms fall back to `inspect/1`.
- **`JSON.encode!` crashed the calling process on un-encodable terms** — A payload containing a PID, ref, function, or tuple raised past the rescue block (which only catches `CaseClauseError`). Encoding now goes through `PushX.HTTP.safe_encode/1`; failures return `{:error, %Response{status: :invalid_request, reason: "Failed to encode payload: ..."}}` cleanly. Encoding also happens before JWT/OAuth acquisition so an oversized or un-encodable payload doesn't waste a credential round-trip.
- **`push_batch/4` and `push_batch!/4` type specs missed instance names** — Both functions accept instance atoms but the spec was `provider() :: :apns | :fcm`. Dialyzer flagged legitimate calls. Specs now include `instance_name()`.
- **`Response.error(provider, …)` could embed an instance atom in the response struct** — `push_batch/4`'s `:exit, :timeout` branch used the caller-supplied provider atom directly, violating the `Response.provider :: :apns | :fcm | :unknown` typespec. Now mapped through `response_provider/1` so instance atoms collapse to `:unknown`.
- **`CircuitBreaker.record_failure/1` lost updates under concurrency** — `:ets.lookup` followed by `:ets.insert` is non-atomic, so concurrent failures undercounted and the real threshold was fuzzy. All circuit-breaker writes now route through the GenServer via `GenServer.call/2`, serializing them while reads stay lock-free.

### Added
- **Pre-flight payload size check** — APNS rejects payloads >4 KB (>5 KB for `push_type: "voip"`) and FCM rejects payloads >4 KB locally, returning `{:error, %Response{status: :payload_too_large}}` instead of round-tripping a guaranteed-fail request.
- **HTTP-date `Retry-After` parsing** — `HTTP.parse_retry_after/1` now handles RFC 1123 HTTP-date format (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`) in addition to delta-seconds, per RFC 7231 §7.1.3. Falls back to `nil` (default backoff) for malformed or past dates.
- 25 new tests covering atom-`:aps` (3), URL-special characters (3), APNS-instance `push_data` guard (1), `JWTCache` GenServer (6), `:validate_tokens` error responses (3), empty `:topic` and unknown `:mode` (2), payload size and encode failures (2), and the `PushX.HTTP` module (5+ groups, 21 tests).
- Total test count: 340 tests, 25 doctests.

### Changed
- **Hot-path `Logger.debug` calls deferred** — APNS and FCM debug log lines now use the function form, so `PushX.Telemetry.truncate_token/1` no longer runs when debug logging is disabled. Measurable on high-volume batch sends.
- **Payload validation moved before credential acquisition** — APNS and FCM now encode + size-check the payload before requesting a JWT or OAuth token. Saves one ES256 signing or OAuth round-trip per rejected request and gives faster local error feedback.
- **Internal: shared HTTP helpers extracted** — `PushX.URLs` centralizes APNS/FCM endpoint constants and `PushX.HTTP` consolidates header parsing, `Retry-After` parsing, FCM `data` stringification, and JSON encoding. Eliminates ~100 lines of duplication between `PushX.APNS`, `PushX.FCM`, `PushX.Instance`, and `PushX.Application`.

## [0.10.0] - 2026-02-19

### Added
- **`PushX.push_data/3,4`** — Send data-only (silent) push notifications via both `:fcm` and named instances. Returns a clear error for `:apns` with guidance to use `push/4` with `push_type: "background"`.
- **`PushX.Response.extract_fcm_error_code/1`** — Public function to extract FCM-specific error codes from the `details` array in FCM v1 API responses. Eliminates duplicated parsing logic across modules.
- 16 new tests (8 for `extract_fcm_error_code`, 4 for FCM data-only/structured payloads, 3 for `push_data`, 1 for NOT_FOUND mapping)
- Total test count: 302 tests, 25 doctests

### Fixed
- **FCM UNREGISTERED errors parsed as unknown_error** — FCM v1 API wraps the real error code (e.g., `UNREGISTERED`) in a `details` array with `NOT_FOUND` as the top-level gRPC status. The parser only read the top-level status, so `on_invalid_token` callbacks never fired for unregistered tokens. Now extracts the FCM-specific `errorCode` from the details array. (Fixes #3)
- **FCM `build_message` always added notification key** — `build_message` hardcoded a `"notification"` key in the base map, making data-only messages impossible and sending `"notification": null` for empty Message structs. Now uses conditional logic to only include notification when content exists. (Fixes #2)
- **FCM structured payloads treated as notifications** — Raw maps with `"notification"` and/or `"data"` keys were wrapped in another `"notification"` key instead of being passed through. Now detects structured payloads and preserves their structure.

## [0.9.0] - 2026-02-16

### Added
- **Dynamic instances (runtime config)** — Start, stop, reconfigure, enable/disable APNS and FCM instances at runtime without application restart. Each instance gets its own HTTP/2 pool, JWT cache, and OAuth process. Enables database-backed admin panels for multi-provider setups. See [Dynamic Instances](README.md#dynamic-instances-runtime-config) in the README.
  - `PushX.Instance.start/3` — Start a named APNS or FCM instance
  - `PushX.Instance.stop/1` — Stop and clean up an instance
  - `PushX.Instance.reconfigure/2` — Hot-swap credentials or config without restart
  - `PushX.Instance.enable/1` / `disable/1` — Toggle instances without tearing down pools
  - `PushX.Instance.list/0` / `status/1` / `resolve/1` — Query running instances
  - `PushX.Instance.reconnect/1` — Restart an instance's HTTP/2 pool
  - `PushX.push/4` accepts instance names (e.g., `PushX.push(:apns_prod, token, msg, opts)`)
- **New response statuses** — `:invalid_request` (missing required options like `:topic`) and `:auth_error` (JWT/credential failure). Both are non-retryable and don't trip the circuit breaker.
- **Credential rotation docs** — README now documents how to hot-swap APNS/FCM credentials without restart for both static config and dynamic instances
- **HexDocs module groups** — Modules are now organized into Core API, Providers, Runtime Instances, Infrastructure, and Observability groups
- 45 new tests (Instance lifecycle, pool management, concurrent instances, error paths)
- Total test count: 286 tests, 23 doctests

### Fixed
- **APNS missing `:topic` no longer raises** — Returns `{:error, %Response{status: :invalid_request}}` instead of raising `ArgumentError`, consistent with the error-tuple API contract
- **JWT generation failure no longer crashes** — Returns `{:error, %Response{status: :auth_error}}` instead of raising, preventing process crashes from invalid private keys
- **JWT refresh no longer recurses infinitely** — Added depth limit (10 retries, 500ms max wait) to prevent stack overflow if the atomic lock holder crashes

### Changed
- `PushX.Response` provider type now includes `:unknown` for instance-not-found/disabled errors

## [0.8.0] - 2026-02-13

### Added
- **Circuit breaker** — Opt-in circuit breaker tracks consecutive failures per provider and temporarily blocks requests when a provider is consistently failing. Configurable threshold and cooldown. See [Circuit Breaker](README.md#circuit-breaker) in the README.
- **`PushX.health_check/0`** — Returns configuration status and circuit breaker state for each provider
- **Per-request timeout overrides** — Pass `:receive_timeout` and `:pool_timeout` as opts to individual `send` calls to override global config
- **Token cleanup callback** — Configure `on_invalid_token: {Mod, :fun, args}` to automatically clean up invalid tokens from your database
- `PushX.Telemetry.truncate_token/1` is now a public function for use in custom logging
- 23 doctests across 7 modules (Token, Telemetry, APNS, FCM, Message, Response, PushX)
- Circuit breaker test suite (13 tests)
- Integration tests for batch sending with mixed success/failure responses
- Total test count: 241 tests, 23 doctests

### Fixed
- **APNS payload injection** — Custom data containing an `"aps"` key can no longer overwrite the notification payload in `Message.to_apns_payload/1`, `notification_with_data/4`, `silent_notification/1`, and `web_notification_with_data/5`
- **FCM `send_data` parity** — `send_data/3` and `send_data_once/3` now have circuit breaker, telemetry, per-request timeouts, debug logging, and exception handling matching the regular `send/3` path
- **Reconnect error logging** — Retry logic now logs a warning if `PushX.reconnect/0` fails instead of silently ignoring the error
- **Device tokens redacted in debug logs** — APNS and FCM debug log messages now truncate tokens (first 8 + last 4 chars) matching the telemetry module's privacy behavior
- Fixed incorrect doctest for `Token.validate/2` (was `:invalid_format`, actually `:invalid_length`)

## [0.7.1] - 2026-02-11

### Added
- **Automatic pool reconnect on connection errors** — When the first retry attempt fails with a connection error (stale HTTP/2 connections), PushX now restarts the Finch pool to force fresh connections before retrying. This fixes the issue where retries on stale connections always fail with `too_many_concurrent_requests`.
- **`PushX.reconnect/0`** — Public function to manually restart the HTTP connection pool. Useful for recovering from persistent connection issues without restarting the app.
- **TCP keepalive on all connections** — Enables OS-level dead connection detection on APNS and FCM pools, helping prevent zombie HTTP/2 connections on cloud infrastructure.
- 4 new tests (reconnect, concurrent reconnect, retry-triggered reconnect, no reconnect on non-connection errors)
- Total test count: 219 tests

### Fixed
- Retries on stale HTTP/2 connections no longer fail repeatedly with `too_many_concurrent_requests` — the pool is recycled on first connection error

## [0.7.0] - 2026-02-09

### Fixed
- **FCM OAuth error handling** — `get_access_token/0` no longer raises on Goth failure, returns `{:ok, token} | {:error, reason}` instead
- **FCM data-only messages missing timeouts** — `send_data` now uses configured `receive_timeout` and `pool_timeout`
- **JWT cache thundering herd** — Added atomic compare-and-swap lock to prevent concurrent JWT refresh
- **Rate limiter O(n) scaling** — Replaced timestamp list with O(1) fixed-window counter in ETS
- **Batch timeout loses token identity** — Timed-out tokens now correctly reported via `Enum.zip`

### Changed
- **Rewritten README** — New structure with Quick Start, complete Usage Guide, and consolidated Configuration section
- Deprecated `request_timeout/0` (was never passed to Finch; use `receive_timeout` and `pool_timeout`)
- Fixed CHANGELOG FCM token validation range (was 100-500, actually 20-500)

## [0.6.2] - 2026-02-04

### Fixed
- Logo now has solid white background (fixes transparency grid on GitHub)
- Fixed HexDocs logo path configuration
- README now uses GitHub raw URL for logo (works on both GitHub and HexDocs)

## [0.6.1] - 2026-02-04

### Added
- **Configurable request timeouts** — New configuration options to handle slow connections:
  - `:request_timeout` — Overall request timeout (default: 30s)
  - `:receive_timeout` — Timeout for receiving response data (default: 15s)
  - `:pool_timeout` — Timeout for acquiring connection from pool (default: 5s)
  - `:connect_timeout` — TCP connection timeout (default: 10s)
- Timeouts are now passed to Finch for both APNS and FCM requests
- Connection timeout configured at Finch pool level for better TCP handling
- **New logo** — Modern purple bell/arrow logo added to README and HexDocs
- 10 new config tests for timeout options
- Total test count: 215 tests

### Fixed
- `request_timeout` errors when connecting to APNS from distant regions (e.g., EU to Apple's US servers)

## [0.6.0] - 2026-02-04

### Changed
- **Increased default pool size** from 10 to 25 connections per pool
- **Increased default pool count** from 1 to 2 pools
- **Faster retry for connection errors** — connection errors now use 1s base delay (was 10s) since these are typically transient network issues, not provider throttling
- **Added explicit FCM HTTP/2 pool** — FCM endpoint now has dedicated HTTP/2 pool configuration (was using default pool)

### Added
- **Troubleshooting section** in README with solutions for common errors:
  - `too_many_concurrent_requests` — HTTP/2 stream limit exceeded
  - `request_timeout` — connection timeout issues
- **Pool sizing guide** in README with recommendations by traffic level
- Updated documentation for pool configuration options

### Fixed
- Connection errors (`request_timeout`, `too_many_concurrent_requests`) now retry faster with 1s/2s/4s delays instead of 10s/20s/40s

## [0.5.0] - 2026-01-22

### Added
- **Web Push support** for browsers:
  - FCM Web Push (Chrome, Firefox, Edge) - same API as mobile
  - Safari Web Push (macOS) via APNS with `web.` topic prefix
- `PushX.FCM.web_notification/4` - Create web push payloads with click action
- `PushX.FCM.send_web/5` - Convenience function for web notifications
- `PushX.APNS.web_notification/4` - Safari web push payloads with URL args
- `PushX.APNS.web_notification_with_data/5` - Safari web push with custom data
- 20 new tests for web push functionality
- Total test count: 205 tests

### Changed
- FCM token validation now accepts shorter web tokens (min 20 chars, was 100)
- Updated Finch dependency to `~> 0.21`
- Updated documentation with Web Push examples

## [0.4.1] - 2026-01-22

### Added
- Expanded Config module test coverage to 100% (24 new tests)
- Total test count: 185 tests

## [0.4.0] - 2026-01-22

### Added
- **Batch sending** — send to multiple tokens concurrently with configurable parallelism
  - `PushX.push_batch/4` - Returns list of `{token, result}` tuples
  - `PushX.push_batch!/4` - Returns summary `%{success: n, failure: n, total: n}`
  - `PushX.APNS.send_batch/3` and `PushX.FCM.send_batch/3` for direct provider access
  - Configurable `:concurrency` (default: 50) and `:timeout` (default: 30s) options
- **Token validation** — validate token format before sending
  - `PushX.validate_token/2` - Returns `:ok` or `{:error, reason}`
  - `PushX.valid_token?/2` - Returns boolean
  - `PushX.Token` module with validation for APNS (64 hex chars) and FCM (20-500 chars) tokens
  - `:validate_tokens` option for batch sending to filter invalid tokens
- **Rate limiting** — optional client-side rate limiting
  - `PushX.check_rate_limit/1` - Check if under rate limit
  - `PushX.RateLimiter` module with sliding window algorithm
  - Configurable per-provider limits via config
  - Automatic rate limit check before each request (when enabled)

### Changed
- Updated README with batch sending, token validation, and rate limiting documentation
- Removed completed items from roadmap

## [0.3.3] - 2026-01-22

### Fixed
- Fixed release workflow cache conflict with ex_doc

## [0.3.2] - 2026-01-22 [YANKED]

### Fixed
- Fixed code formatting in retry tests

## [0.3.1] - 2026-01-22 [YANKED]

### Fixed
- Fixed release workflow to use MIX_ENV=dev for ex_doc availability

## [0.3.0] - 2026-01-22 [YANKED]

### Added
- **Telemetry integration** with events for monitoring push notification delivery:
  - `[:pushx, :push, :start]` - Request started
  - `[:pushx, :push, :stop]` - Request succeeded
  - `[:pushx, :push, :error]` - Request failed
  - `[:pushx, :push, :exception]` - Exception raised
  - `[:pushx, :retry, :attempt]` - Retry attempted
- `PushX.Telemetry` module with documentation and examples
- `telemetry ~> 1.3` dependency
- Comprehensive retry and telemetry test suites (116 total tests)
- Credential rotation documentation in README
- Retry configuration documentation in README

### Changed
- Made all examples generic (removed domain-specific references)
- Updated README with telemetry usage examples and Telemetry.Metrics integration

## [0.2.4] - 2026-01-22

### Added
- Comprehensive API reference documentation with all functions, options, and types
- Credential storage options guide (filesystem, env vars, Fly.io, AWS Secrets Manager)

## [0.2.3] - 2026-01-22

### Added
- GitHub Actions CI workflow (tests on Elixir 1.18/1.19 with OTP 26-28)
- APNS and FCM credential setup guides
- Roadmap and contributing sections

### Changed
- Updated Finch dependency to `~> 0.20`
- Improved CI with code quality checks, security audit, and unused deps check
- Clarified test key comment to avoid false positive security alerts

## [0.2.2] - 2026-01-12

### Added
- Added CHANGELOG.md with full version history
- Added Changelog link to hex.pm package

## [0.2.1] - 2026-01-12

### Fixed
- Fixed CI workflow for documentation generation
- Fixed code formatting issues

### Changed
- Updated documentation examples to use generic messaging

## [0.2.0] - 2026-01-12

### Added
- Automatic retry with exponential backoff following Apple/Google best practices
- `PushX.Retry` module for retry logic
- `send_once/3` functions for APNS and FCM (single attempt without retry)
- `retry_after` field in `PushX.Response` struct
- `retryable?/1` helper function in `PushX.Response`
- Configuration options for retry behavior:
  - `retry_enabled` - Enable/disable retry (default: `true`)
  - `retry_max_attempts` - Maximum retry attempts (default: `3`)
  - `retry_base_delay_ms` - Base delay in milliseconds (default: `10_000`)
  - `retry_max_delay_ms` - Maximum delay in milliseconds (default: `60_000`)

### Fixed
- Fixed APNS sandbox URL (`api.sandbox.push.apple.com`)

## [0.1.1] - 2026-01-09

### Fixed
- Initial bug fixes and improvements

## [0.1.0] - 2026-01-09

### Added
- Initial release
- APNS (Apple Push Notification Service) support with JWT authentication
- FCM (Firebase Cloud Messaging) support with OAuth2 via Goth
- Unified API for both providers (`PushX.push/4`)
- Message builder API (`PushX.Message`)
- Structured response handling (`PushX.Response`)
- HTTP/2 connections via Finch
- Zero external JSON dependency (uses Elixir 1.18+ built-in JSON)

[Unreleased]: https://github.com/cignosystems/pushx/compare/v0.13.0...HEAD
[0.13.0]: https://github.com/cignosystems/pushx/compare/v0.12.0...v0.13.0
[0.12.0]: https://github.com/cignosystems/pushx/compare/v0.11.0...v0.12.0
[0.11.0]: https://github.com/cignosystems/pushx/compare/v0.10.0...v0.11.0
[0.10.0]: https://github.com/cignosystems/pushx/compare/v0.9.0...v0.10.0
[0.9.0]: https://github.com/cignosystems/pushx/compare/v0.8.0...v0.9.0
[0.8.0]: https://github.com/cignosystems/pushx/compare/v0.7.1...v0.8.0
[0.7.1]: https://github.com/cignosystems/pushx/compare/v0.7.0...v0.7.1
[0.7.0]: https://github.com/cignosystems/pushx/compare/v0.6.2...v0.7.0
[0.6.2]: https://github.com/cignosystems/pushx/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/cignosystems/pushx/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/cignosystems/pushx/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/cignosystems/pushx/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/cignosystems/pushx/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/cignosystems/pushx/compare/v0.3.3...v0.4.0
[0.3.3]: https://github.com/cignosystems/pushx/compare/v0.3.2...v0.3.3
[0.3.2]: https://github.com/cignosystems/pushx/compare/v0.3.1...v0.3.2
[0.3.1]: https://github.com/cignosystems/pushx/compare/v0.3.0...v0.3.1
[0.3.0]: https://github.com/cignosystems/pushx/compare/v0.2.4...v0.3.0
[0.2.4]: https://github.com/cignosystems/pushx/compare/v0.2.3...v0.2.4
[0.2.3]: https://github.com/cignosystems/pushx/compare/v0.2.2...v0.2.3
[0.2.2]: https://github.com/cignosystems/pushx/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/cignosystems/pushx/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/cignosystems/pushx/compare/v0.1.1...v0.2.0
[0.1.1]: https://github.com/cignosystems/pushx/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/cignosystems/pushx/releases/tag/v0.1.0
