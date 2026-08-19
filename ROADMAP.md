# PushX roadmap

PushX is at 0.x while the public API is still allowed to change shape. The
plan is to reach **1.0 as a stability promise**, not as a feature milestone.

## Done

- **0.12** — review remediation, real-path test suite (94% coverage gate),
  property tests, hardened CI.
- **0.13** — last API shape changes: FCM topics/conditions, `retry: :none`,
  `push_batch_stream/4`, `:not_configured`, per-instance `:token_fetcher`,
  `health_check/0` instances.
- **0.14** — test delivery mode (`PushX.Test`), `apns_id`, FCM `validate_only`,
  Message iOS/localization builders, topic subscription management,
  `Telemetry.metrics/0`, `Instance.Loader`, `mix pushx.doctor`.

## 0.15 (in progress)

- **Standards-based Web Push** (`:webpush`: RFC 8030/8291/8292, VAPID) —
  also the stress test that the `provider`/`target`/`Response`/`Instance`
  abstractions generalise beyond APNS/FCM. They did: Web Push landed as an
  additive provider with no signature changes.
- Expo design note — [docs/design/expo.md](docs/design/expo.md): fits
  additively; one `PushX.Batch` enhancement (chunked multi-target sends) is
  the only shared change it needs.

## 1.0 — boring on purpose

- Remove `Config.request_timeout/0` (deprecated since 0.11).
- `@since` annotations; supported-versions (Elixir ≥ 1.18 / OTP ≥ 26), semver
  and deprecation policy in the README; "Upgrading to 1.0" note.
- `SECURITY.md`, Dependabot config, issue/PR templates.
- A real-RTT load test against the APNS sandbox / FCM before the word
  "production-ready" goes next to 1.0.
- Response docs: `status: :sent` = "accepted by the provider".

## 1.x candidates

- Expo push (see design note), Huawei HMS, APNS Live Activity broadcast
  channels, `PushX.Batch` chunked multi-target sends.

## Not planned

Distributed rate limiting / breaker state, scheduling or deferred delivery
(use Oban), a token persistence layer, wrappers for hosted services
(OneSignal, Pusher Beams).
