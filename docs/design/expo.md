# Design note: Expo Push as a PushX provider

Status: **design only** (0.15). Not implemented. Written to answer "do PushX's
shapes — `provider()`, `target()`, `Response`, `Instance`, `Batch`, test mode —
accommodate Expo without a breaking change?" before 1.0 freezes them.

## What Expo Push is

[Expo's push service](https://docs.expo.dev/push-notifications/sending-notifications/)
fronts APNS/FCM for React-Native/Expo apps. The server never sees device
tokens; it sends to **Expo push tokens** (`ExponentPushToken[xxxxxxxxxxxxxxxxxxxxxx]`)
via `POST https://exp.host/--/api/v2/push/send`, optionally authenticated
with a bearer *access token* (enhanced security mode). Three things differ
from APNS/FCM:

1. **Batched request body.** Up to 100 messages per request, each a JSON
   object `{to, title, body, data, sound, badge, ttl, expiration, priority,
   subtitle, channelId, categoryId, mutableContent, ...}`; `to` may be an array
   of tokens for identical messages.
2. **Two-phase results.** The send response returns one **ticket** per message
   — `{status: "ok", id: "..."}` or `{status: "error", message, details:
   {error: "DeviceNotRegistered" | "MessageTooBig" | "MessageRateExceeded" |
   "MismatchSenderId" | "InvalidCredentials"}}`. A ticket `id` is later
   exchanged for a **receipt** (`POST /--/api/v2/push/getReceipts`, ids ≤ 1000)
   that reports what APNS/FCM actually said — receipts are available for
   ~24 h and **must** be polled; `DeviceNotRegistered` there is the signal to
   delete a token.
3. **Rate limits**: 600 messages/s per project, and HTTP 429 with
   `Retry-After` on the whole request.

## How it maps onto PushX

| PushX concept | Expo | Fit |
|---|---|---|
| `provider()` | `:expo` | additive atom (same as `:webpush` in 0.15) |
| `target()` | Expo push token binary (`ExponentPushToken[...]` / `ExpoPushToken[...]`) | a binary — `Token.validate(:expo, t)` regex; batch validation works unchanged |
| `PushX.push(:expo, token, msg, opts)` | one-message request, ticket → `Response` | **fits**: ticket `ok` → `{:ok, %Response{status: :sent, id: ticket_id}}`; ticket errors map cleanly (`DeviceNotRegistered` → `:unregistered`, `MessageTooBig` → `:payload_too_large`, `MessageRateExceeded` → `:rate_limited`, `InvalidCredentials`/`MismatchSenderId` → `:auth_error`); request-level 429/5xx → `:rate_limited`/`:server_error` |
| `push_batch/4` | **the natural unit**: chunk 100 tokens per HTTP request | fits `PushX.Batch` *if* the provider batch function can send many targets per request. Today `Batch.stream/5` maps one `send_fun` per target. Expo wants `send_many(targets) -> [{target, result}]`. **Action before 1.0:** give `PushX.Batch` an optional `:chunk_send` mode (`{fun, size}`) that calls a chunk function and flattens; facade/APNS/FCM unchanged. Additive. |
| `Message` | `title/body/subtitle/badge/sound/data/ttl/priority/mutableContent/categoryId/channelId` | a `Message.to_expo_payload/1` — additive |
| `Response.id` | ticket id | fits; but semantics differ: "accepted by Expo", not "accepted by Apple/Google" |
| **receipts** | `PushX.Expo.receipts(ticket_ids) -> %{id => :ok \| {:error, status, reason}}` | **new surface**, but additive: a provider-specific function, like `PushX.FCM.subscribe/3`. Token cleanup from receipts would call the same `:on_invalid_token` callback (`apply(mod, fun, [:expo, token | args])`) — requires storing ticket→token on the caller's side, or PushX returning the mapping from `push_batch` (it does: `{token, {:ok, %Response{id: ticket}}}`). |
| `Instance` | per-tenant Expo access token | fits: `Instance.start(name, :expo, access_token: ...)`; no JWT cache, no Goth |
| test delivery mode | record + `{:ok, sent}` | fits (hook before HTTP) |
| circuit breaker / limiter | per `:expo` key | fits; limiter default should reflect 600/s |

## Conclusion

Expo fits **without breaking changes**: one new provider atom, a binary target,
a provider-specific `receipts/1`, and one additive `PushX.Batch` capability
(chunked multi-target sends) that other bulk APIs would also benefit from.
The only 1.0-relevant decision is to **not** promise that `Response.status:
:sent` means "accepted by the platform" — for Expo it means "accepted by Expo";
`PushX.Response` docs should say "accepted by the provider". That wording
lands with 0.15.

Not planned before 1.0; tracked for 1.x.
