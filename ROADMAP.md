# PushX roadmap

PushX 1.0 (2026-10-07) is **a stability promise, not a feature milestone** —
see README "Versioning and Support". What follows is how it got there and
what is planned on top of it.

## Done

- **0.12** — review remediation, real-path test suite (94% coverage gate),
  property tests, hardened CI.
- **0.13** — last API shape changes: FCM topics/conditions, `retry: :none`,
  `push_batch_stream/4`, `:not_configured`, per-instance `:token_fetcher`,
  `health_check/0` instances.
- **0.14** — test delivery mode (`PushX.Test`), `apns_id`, FCM `validate_only`,
  Message iOS/localization builders, topic subscription management,
  `Telemetry.metrics/0`, `Instance.Loader`, `mix pushx.doctor`.
- **0.15** — standards-based Web Push (VAPID + RFC 8291), HTTP/2 keepalive
  options, pool-sizing fixes, Expo design note.
- **1.0** — stability promise (2026-10-07): `request_timeout/0` removed, `since:`
  badges, versioning/support policy, real-RTT load test. See CHANGELOG.

## 0.15 — shipped 2026-08-22

- **Standards-based Web Push** (`:webpush`: RFC 8030/8291/8292, VAPID) —
  also the stress test that the `provider`/`target`/`Response`/`Instance`
  abstractions generalise beyond APNS/FCM. They did: Web Push landed as an
  additive provider with no signature changes.
- Expo design note — [docs/design/expo.md](docs/design/expo.md): fits
  additively; one `PushX.Batch` enhancement (chunked multi-target sends) is
  the only shared change it needs.

## 1.0 — boring on purpose

- [x] Remove `Config.request_timeout/0` (deprecated since 0.7.0). *(1.0.0)*
- [x] `@since` annotations; supported-versions (Elixir ≥ 1.18 / OTP ≥ 26), semver
  and deprecation policy in the README; "Upgrading to 1.0" note. *(1.0.0)*
- [x] `SECURITY.md`, Dependabot config, issue/PR templates. *(1.0.0)*
- [x] Response docs: `status: :sent` = "accepted by the provider". *(0.15)*
- [x] A real-RTT load test against the APNS sandbox / FCM before the word
  "production-ready" goes next to 1.0. *(Both legs run 2026-10-07 — numbers
  in README "Performance and Pool Sizing" and the `bench/real_rtt.exs` header.
  FCM: PING keepalive confirmed across a 5-min idle; pool-sizing guidance
  confirmed by the concurrency-200 stream-exhaustion cliff. APNS sandbox:
  keepalive confirmed (157 ms after 5-min idle vs 155 ms warm p50); sandbox
  stream limit documented in Troubleshooting, including the invalid-key
  variant where saturation masquerades as a capacity problem.)*
- [x] Let 0.15 bake in production for a couple of weeks first. *(Shipped
  2026-08-22; six weeks, no issues reported.)*

## 1.x candidates

- Expo push (see design note), Huawei HMS, APNS Live Activity broadcast
  channels, `PushX.Batch` chunked multi-target sends.
- Per-origin circuit breaker / rate-limit keys for Web Push (today one
  `:webpush` key spans every push service; the breaker is off by default).

## Not planned

Distributed rate limiting / breaker state, scheduling or deferred delivery
(use Oban), a token persistence layer, wrappers for hosted services
(OneSignal, Pusher Beams).
