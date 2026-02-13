# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
