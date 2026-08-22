# Contributing to PushX

Notes for humans and AI assistants modifying this library itself. If you are
*using* PushX in a project, see `README.md` and `AGENTS.md` instead.

## Repo layout

- `lib/push_x.ex` — top-level user-facing API (`push`, `push_batch`,
  `push_data`, `push!`, `health_check`, `reconnect`, `validate_token`)
- `lib/push_x/apns.ex` — APNS provider (HTTP/2 + JWT)
- `lib/push_x/fcm.ex` — FCM provider (HTTP/2 + OAuth via Goth)
- `lib/push_x/instance.ex` + `lib/push_x/instance/` — runtime-configured
  named instances (multi-tenant), backed by an ETS registry and per-instance
  Finch pool + JWT/OAuth process
- `lib/push_x/web_push.ex` + `lib/push_x/web_push/` — standards Web Push
  provider (RFC 8030 delivery, `encryption.ex` RFC 8291, `vapid.ex` RFC 8292)
- `lib/push_x/batch.ex` — shared batch engine behind `push_batch*`
- `lib/push_x/send_gate.ex` — breaker + limiter gate on every send path
- `lib/push_x/test.ex` + `lib/push_x/test/` — `delivery: :test` mode
- `lib/mix/tasks/` — `mix pushx.doctor`, `mix pushx.vapid`
- `lib/push_x/message.ex` — fluent struct + provider conversion
  (`to_apns_payload/1`, `to_fcm_payload/1`, `to_webpush_payload/1`)
- `lib/push_x/response.ex` — normalized result struct + `should_remove_token?/1`
- `lib/push_x/http.ex` — internal Finch wrapper, `safe_encode/1` for payload
  serialization (kept hidden — error handling for un-encodable terms lives here)
- `lib/push_x/jwt_cache.ex` — APNS JWT cache (token bucket, ~50 min TTL)
- `lib/push_x/retry.ex` — exponential backoff with `reconnect_fn` hook
- `lib/push_x/circuit_breaker.ex` — per-provider failure threshold breaker
- `lib/push_x/rate_limiter.ex` — optional client-side limiter
- `lib/push_x/token.ex` — APNS hex / FCM format validation
- `lib/push_x/telemetry.ex` — `[:pushx, :push, :start | :stop | :error]` events
- `lib/push_x/config.ex`, `lib/push_x/urls.ex`, `lib/push_x/application.ex`
  — config helpers, provider URLs, OTP application

## Running tests

- All tests: `mix test`
- Single file: `mix test test/push_x/apns_test.exs`
- Coverage: `mix test --cover` — the threshold in `mix.exs` (`test_coverage`,
  currently 94%) is enforced locally and in CI; ratchet it up, never down
- HTTP traffic is mocked via `bypass` — no network calls during tests
- Benchmark (manual, not in CI): `MIX_ENV=test mix run bench/send_bench.exs` —
  per-send overhead over a raw HTTP request and batch throughput against a
  local stub; the baseline is recorded in the script header. Run it before
  and after touching the send path, `Retry`, `SendGate`, or the JWT cache.
- Property tests (`stream_data`) live in `test/push_x/properties_test.exs`
  (a provider-local one next to its unit tests is fine when it needs that
  file's fixtures); add one whenever you touch a pure function with an input
  space worth sweeping (validators, payload builders, parsers, classification
  tables)
- Integration tests must call the **real** public functions (`PushX.push/4`,
  `PushX.APNS.send/3`, `PushX.FCM.send/3`, `PushX.Instance` via `PushX.push/4`)
  — never re-implement the send pipeline inside a test helper. Three
  test-only seams make that possible without touching the network:
  - `:apns_url_override` / `:fcm_url_override` — point the real send path
    at a local Bypass server (`PushX.URLs`)
  - `:fcm_token_fetcher` — `{mod, fun, args}` replacing `Goth.fetch/1`
    (`test_helper.exs` sets it to `PushX.TestOAuth`; when set, FCM instances
    do not start a Goth process)
  - Disable retries in HTTP tests (`Application.put_env(:pushx, :retry_enabled, false)`)
    or retryable failures back off for 10–60 s

## Format / credo / docs / dialyzer

- `mix format --check-formatted`
- `mix credo --strict` (runs in CI)
- `mix docs --warnings-as-errors` — hexdocs output to `doc/`
- `mix dialyzer` (runs in CI with a cached PLT)
- `mix deps.audit` — dependency advisories (runs in CI, also weekly on a schedule)
- `mix hex.build` — package sanity check (runs in CI)

## Releasing

1. Move the `[Unreleased]` changelog section to `[x.y.z] - YYYY-MM-DD` and add
   the compare link; bump `@version` in `mix.exs` and the `~> x.y` constraint
   in `README.md` / `AGENTS.md`.
2. Commit, then `git tag vx.y.z && git push --tags`.
3. The release workflow verifies the tag matches `@version`, runs the suite
   with the coverage gate, and only then publishes the package and docs to Hex
   — and creates the GitHub Release for the tag, with that version's
   CHANGELOG section as the notes (`scripts/release_notes.sh <version>`).
   Every tag gets a GitHub Release; if the workflow's last job ever fails,
   run `gh release create vX.Y.Z --verify-tag --title vX.Y.Z --notes-file <(scripts/release_notes.sh X.Y.Z)`.

## Coding conventions

- Public modules get `@moduledoc` + `@doc` on every public function with
  `## Examples`. Hidden internal modules (`HTTP`, `URLs`, `JWTCache`,
  `Batch`, `SendGate`, `Application`, `Instance.Server`,
  `Instance.Supervisor`, `Test.Store`, `WebPush.Encryption`, `WebPush.VAPID`)
  use `@moduledoc false`.
- Errors are `{:error, %PushX.Response{status: atom_status, ...}}` —
  do not return ad-hoc `{:error, reason}` tuples from public functions.
- Add new error semantics by extending `Response.status` *and*
  `Response.should_remove_token?/1` if applicable, *and* the docstring on
  `Response`.
- Telemetry events go through `PushX.Telemetry` — don't `:telemetry.execute`
  inline.
