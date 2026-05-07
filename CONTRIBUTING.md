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
- `lib/push_x/message.ex` — fluent struct + provider conversion
  (`to_apns_payload/1`, `to_fcm_payload/1`)
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
- HTTP traffic is mocked via `bypass` — no network calls during tests

## Format / docs / dialyzer

- `mix format --check-formatted`
- `mix docs` — hexdocs output to `doc/`
- Dialyzer is not configured here; rely on type-spec coverage in PRs

## Coding conventions

- Public modules get `@moduledoc` + `@doc` on every public function with
  `## Examples`. Hidden internal modules (`HTTP`, `URLs`, `JWTCache`,
  `Application`, `Instance.Server`, `Instance.Supervisor`) use
  `@moduledoc false`.
- Errors are `{:error, %PushX.Response{status: atom_status, ...}}` —
  do not return ad-hoc `{:error, reason}` tuples from public functions.
- Add new error semantics by extending `Response.status` *and*
  `Response.should_remove_token?/1` if applicable, *and* the docstring on
  `Response`.
- Telemetry events go through `PushX.Telemetry` — don't `:telemetry.execute`
  inline.
