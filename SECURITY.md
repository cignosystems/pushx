# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| latest 1.x (when released) | yes |
| latest 0.x | yes, until 1.0 ships |
| older | no — please upgrade |

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately via
[GitHub Security Advisories](https://github.com/cignosystems/pushx/security/advisories/new)
("Report a vulnerability"), or email <security@cigno-systems.com>. Include the
PushX version, a description and, if possible, a reproduction.

You will get an acknowledgement within 72 hours and a fix or mitigation plan
within 14 days for confirmed issues. Fixes ship as a patch release with a
CHANGELOG entry and a GitHub Security Advisory; reporters are credited unless
they ask not to be.

## Scope notes

- PushX never logs full device tokens, subscription keys, JWTs or OAuth tokens;
  `PushX.Telemetry` truncates tokens in metadata.
- Provider credentials (APNS `.p8`, FCM service account, VAPID private key) are
  read from config / files you control; rotate them if leaked — PushX has no
  copy.
- Dependency advisories are tracked by `mix deps.audit` / `mix hex.audit` in CI.
