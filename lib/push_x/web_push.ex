defmodule PushX.WebPush do
  @moduledoc """
  Standards-based Web Push: send to any browser's push service — Chrome,
  Firefox, Edge, Safari 16+ (macOS Ventura / iOS 16.4 and later), Opera,
  Samsung Internet — using the subscription the browser's `PushManager` gives
  you. Payloads are encrypted end-to-end per RFC 8291 (`aes128gcm`) and the
  request is authenticated with VAPID (RFC 8292); transport is RFC 8030.

  This is the modern path for *all* browsers. (FCM's `webpush` block is for
  apps that use the Firebase JS SDK — see `PushX.FCM.send_web/5`; Safari's
  legacy APNS website push is `PushX.APNS.web_notification/4`.)

  ## Setup

  Generate a VAPID key pair once (`mix pushx.vapid`, or `generate_vapid_keys/0`)
  and configure it with a contact for the push services:

      config :pushx,
        webpush_vapid_subject: "mailto:ops@example.com",
        webpush_vapid_public_key: "BJ...",        # optional — derived from the private key
        webpush_vapid_private_key: "k1..."        # base64url (web-push CLI format) or EC PEM

  The **public** key is what your front end passes as `applicationServerKey`
  to `pushManager.subscribe/1`. Keep the private key secret; rotating it
  invalidates every existing subscription.

  ## Sending

  The target is the subscription object from the browser, as JSON-decoded
  (string or atom keys):

      subscription = %{
        "endpoint" => "https://fcm.googleapis.com/fcm/send/...",
        "keys" => %{"p256dh" => "BNc...", "auth" => "tBH..."}
      }

      PushX.push(:webpush, subscription, "Hello")                      # via the unified API
      PushX.WebPush.send(subscription, %{"title" => "Hi", "body" => "...", "icon" => "/icon.png"})

  A `PushX.Message` maps to the Notification API shape your service worker
  shows (`title`, `body`, `icon`, `tag`, `data` — `Message.to_webpush_payload/1`);
  a map is sent as JSON as-is; a binary is sent verbatim (your service worker
  reads it with `event.data.text()` / `.json()`).

  ## Options

    * `:ttl` — seconds the push service may hold the message for an offline
      browser (default `2_419_200`, four weeks; `0` = deliver now or drop)
    * `:urgency` — `:very_low | :low | :normal | :high` (default: provider's
      default, i.e. normal); lets the device defer low-urgency pushes to save power
    * `:topic` — collapse key (≤ 32 base64url characters): a newer push with the
      same topic replaces an undelivered one
    * `:retry`, `:receive_timeout`, `:pool_timeout` — as for `PushX.push/4`

  ## Responses

  Push services answer `201 Created` → `{:ok, %Response{status: :sent}}`
  (`id` is the `Location` header when present). `404`/`410` mean the
  subscription is gone → `:unregistered` — `PushX.Response.should_remove_token?/1`
  is true and `:on_invalid_token` fires with the subscription map, so delete
  it from your store. `401`/`403` → `:auth_error` (VAPID; PushX re-signs and
  retries once in case the cached JWT went stale), `413` → `:payload_too_large`,
  `429` → `:rate_limited` (with `retry_after`), `5xx` → `:server_error`.

  Payloads are limited to #{PushX.WebPush.Encryption.max_plaintext()} bytes of
  plaintext (the 4 096-byte record every push service must accept, minus
  framing); larger payloads are rejected locally with `:payload_too_large`.

  Multi-tenant: `PushX.Instance.start(name, :webpush, vapid_subject: ..., vapid_private_key: ...)`
  gives each tenant its own VAPID identity. Test delivery mode records the
  plaintext payload and never encrypts or contacts a push service.

  ## Standards compliance

  Implemented (the mandatory application-server side of each RFC):

    * **RFC 8030 (transport)** — `POST` to the push resource over TLS; `TTL`
      always sent (required); `Urgency` (`very-low | low | normal | high`) and
      `Topic` (≤ 32 URL-safe base64 characters) when given; `201 Created`
      with `Location` is success; `404`/`410` mean the subscription is gone;
      `413`, `429` + `Retry-After`, `5xx` mapped. Plain `http` endpoints are
      accepted only so a local push-service stub can be used in tests.
    * **RFC 8291 (encryption) / RFC 8188 (`aes128gcm`)** — ECDH P-256 with a
      fresh ephemeral key pair and a fresh 16-byte salt per message, HKDF-SHA-256
      with the subscription's `auth` secret, `"WebPush: info"` key info, CEK/nonce
      derivation, single 4096-byte record with the `0x02` delimiter, GCM tag.
      The implementation reproduces RFC 8291 Appendix A bit-for-bit (see the
      encryption tests).
    * **RFC 8292 (VAPID)** — ES256 JWT with `aud` = push-service origin, `exp`
      12 h ahead (the RFC allows up to 24 h), `sub` = your `mailto:`/`https:`
      contact; sent as `Authorization: vapid t=<jwt>, k=<public key>` with the
      same key that signed. JWTs are cached per origin and re-signed once when a
      push service answers 401/403.

  Optional parts of the RFCs that are **not** implemented: multi-record
  encryption and padding (RFC 8188 allows records > 4096 bytes; push services
  are only required to accept 4096, so PushX limits plaintext to
  #{PushX.WebPush.Encryption.max_plaintext()} bytes instead), push-message
  receipts and `Prefer: respond-async` (RFC 8030 §5.1, rarely supported by
  push services), and HTTP/2 to push services (HTTP/1.1 is used, which RFC
  8030 permits for application servers).
  """

  require Logger

  alias PushX.{Config, HTTP, Message, Response, Retry, SendGate, Telemetry}
  alias PushX.WebPush.{Encryption, VAPID}

  @typedoc """
  A browser push subscription as produced by `PushManager.subscribe/1` and
  JSON-decoded: `endpoint` plus `keys.p256dh` / `keys.auth` (base64url).
  String or atom keys are accepted.
  """
  @type subscription :: %{
          required(:endpoint | String.t()) => String.t(),
          required(:keys | String.t()) => %{required(atom() | String.t()) => String.t()},
          optional(any()) => any()
        }
  @type payload :: binary() | map() | Message.t()
  @type urgency :: :very_low | :low | :normal | :high
  @type option ::
          {:ttl, non_neg_integer()}
          | {:urgency, urgency()}
          | {:topic, String.t()}
          | {:retry, :blocking | :none}
          | {:receive_timeout, pos_integer()}
          | {:pool_timeout, pos_integer()}

  @default_ttl 2_419_200
  @topic_regex ~r/\A[A-Za-z0-9_\-]{1,32}\z/

  # -- Public API -------------------------------------------------------------

  @doc """
  Sends a Web Push message to `subscription` with automatic retry
  (see `PushX.push/4` for the retry semantics and the `:retry` option).
  """
  @spec send(subscription(), payload(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def send(subscription, payload, opts \\ []) do
    Retry.maybe_with_retry(:webpush, opts, fn -> send_once(subscription, payload, opts) end)
  end

  @doc "Sends a Web Push message without retry."
  @spec send_once(subscription(), payload(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def send_once(subscription, payload, opts \\ []) do
    case SendGate.check(:webpush, :webpush) do
      :ok ->
        result = do_send(static_ctx(), subscription, payload, opts)
        SendGate.record(:webpush, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  @doc """
  Generates a VAPID key pair (base64url, the format the `web-push` CLI and
  browsers use). Do this once per application and keep the private key secret.
  """
  @spec generate_vapid_keys() :: %{public_key: String.t(), private_key: String.t()}
  def generate_vapid_keys, do: VAPID.generate()

  @doc """
  Validates a subscription object: `https` endpoint, a 65-byte uncompressed
  P-256 `p256dh` key and a 16-byte `auth` secret (both base64url). Returns the
  parsed form used internally or `{:error, %Response{status: :invalid_token}}`.
  """
  @spec validate_subscription(term()) ::
          {:ok, %{endpoint: String.t(), ua_public: binary(), auth: binary()}}
          | {:error, Response.t()}
  def validate_subscription(%{} = subscription) do
    endpoint = get(subscription, :endpoint)
    keys = get(subscription, :keys) || %{}
    p256dh = if is_map(keys), do: get(keys, :p256dh)
    auth = if is_map(keys), do: get(keys, :auth)

    with :ok <- validate_endpoint(endpoint),
         {:ok, ua_public} <- decode_key(p256dh, 65, "keys.p256dh"),
         {:ok, auth_secret} <- decode_key(auth, 16, "keys.auth") do
      if binary_part(ua_public, 0, 1) == <<4>> do
        {:ok, %{endpoint: endpoint, ua_public: ua_public, auth: auth_secret}}
      else
        invalid_subscription("keys.p256dh must be an uncompressed P-256 point")
      end
    end
  end

  def validate_subscription(_),
    do: invalid_subscription("expected a subscription map with endpoint and keys")

  # -- Shared core (static configuration and named instances) ----------------

  @doc false
  # `ctx`: %{vapid: {public_b64 | nil, private}, subject:, finch_name:,
  #   request_opts:, scope: (JWT cache key part), configured?: boolean,
  #   instance: name | nil, retry_opts: keyword}
  def do_send(ctx, subscription, payload, opts) do
    with :ok <- ensure_configured(ctx),
         {:ok, sub} <- validate_subscription(subscription),
         :ok <- validate_opts(opts),
         {:ok, body} <- build_body(payload),
         :ok <- check_size(body) do
      if PushX.Test.active?(),
        do: PushX.Test.deliver(:webpush, subscription, body, opts, ctx.instance),
        else: send_encrypted(ctx, subscription, sub, body, opts, false)
    end
  end

  defp send_encrypted(ctx, subscription, sub, body, opts, reauthed?) do
    with {:ok, keys} <- vapid_keys(ctx),
         {:ok, authorization} <- VAPID.authorization(sub.endpoint, keys, ctx.subject, ctx.scope),
         {:ok, encrypted} <- encrypt(body, sub) do
      case request(ctx, subscription, sub, authorization, encrypted, opts) do
        {:error, %Response{status: :auth_error}} when not reauthed? ->
          # A stale/rotated VAPID JWT: drop the cached token for this origin and try once more.
          PushX.JWTCache.invalidate({:vapid_jwt, ctx.scope, VAPID.origin(sub.endpoint)})

          Logger.warning(
            "[PushX.WebPush] push service rejected VAPID auth; re-signing and retrying once"
          )

          send_encrypted(ctx, subscription, sub, body, opts, true)

        result ->
          result
      end
    else
      {:error, %Response{} = response} -> {:error, response}
      {:error, reason} -> {:error, Response.error(:webpush, :auth_error, to_string(reason))}
    end
  end

  defp request(ctx, subscription, sub, authorization, encrypted, opts) do
    Telemetry.start(:webpush, subscription)
    start_time = System.monotonic_time()

    headers =
      [
        {"authorization", authorization},
        {"content-encoding", "aes128gcm"},
        {"content-type", "application/octet-stream"},
        {"ttl", Integer.to_string(Keyword.get(opts, :ttl, @default_ttl))}
      ]
      |> HTTP.maybe_add_header("urgency", urgency_header(Keyword.get(opts, :urgency)))
      |> HTTP.maybe_add_header("topic", Keyword.get(opts, :topic))

    request_opts =
      Keyword.merge(ctx.request_opts, Keyword.take(opts, [:receive_timeout, :pool_timeout]))

    case HTTP.finch_request(
           Finch.build(:post, sub.endpoint, headers, encrypted),
           ctx.finch_name,
           request_opts,
           "PushX.WebPush"
         ) do
      {:ok, %{status: status, headers: resp_headers}} when status in [200, 201, 202] ->
        response = Response.success(:webpush, HTTP.get_header(resp_headers, "location"))
        Telemetry.stop(:webpush, subscription, start_time, response)
        {:ok, response}

      {:ok, %{status: status, headers: resp_headers, body: resp_body}} ->
        response = error_response(status, resp_body, resp_headers)
        Telemetry.error(:webpush, subscription, start_time, response)
        {:error, response}

      {:error, reason} ->
        Logger.error("[PushX.WebPush] Connection error: #{inspect(reason)}")
        response = Response.error(:webpush, :connection_error, inspect(reason))
        Telemetry.error(:webpush, subscription, start_time, response)
        {:error, response}
    end
  end

  # RFC 8030 §8 / common push-service behaviour.
  defp error_response(status, body, headers) do
    retry_after = HTTP.parse_retry_after(headers)
    reason = String.slice(to_string(body), 0, 200)

    http_status =
      case status do
        400 -> :invalid_request
        s when s in [401, 403] -> :auth_error
        s when s in [404, 410] -> :unregistered
        413 -> :payload_too_large
        429 -> :rate_limited
        s when s >= 500 -> :server_error
        _ -> :unknown_error
      end

    Logger.warning("[PushX.WebPush] push service answered #{status}: #{reason}")

    Response.error(
      :webpush,
      http_status,
      "HTTP #{status}" <> if(reason == "", do: "", else: ": #{reason}"),
      body,
      retry_after
    )
  end

  defp encrypt(body, sub) do
    case Encryption.encrypt(body, %{ua_public: sub.ua_public, auth: sub.auth}) do
      {:ok, encrypted} ->
        {:ok, encrypted}

      {:error, :payload_too_large} ->
        {:error, payload_too_large()}

      {:error, :invalid_keys} ->
        invalid_subscription("keys are not a valid P-256 point / auth secret")
    end
  end

  # -- Helpers -------------------------------------------------------------------

  defp static_ctx do
    %{
      vapid: {Config.get(:webpush_vapid_public_key), Config.get(:webpush_vapid_private_key)},
      subject: Config.get(:webpush_vapid_subject),
      finch_name: Config.finch_name(),
      request_opts: Config.finch_request_opts(),
      scope: :static,
      configured?: Config.webpush_configured?(),
      instance: nil
    }
  end

  defp ensure_configured(%{configured?: true}), do: :ok

  defp ensure_configured(_ctx) do
    if PushX.Test.active?(),
      do: :ok,
      else:
        {:error,
         Response.error(
           :webpush,
           :not_configured,
           "Web Push is not configured: set :webpush_vapid_subject and :webpush_vapid_private_key"
         )}
  end

  defp vapid_keys(%{vapid: {public, private}, subject: subject}) do
    with :ok <- VAPID.validate_subject(subject) do
      VAPID.resolve_keys(public, private)
    end
  end

  @doc false
  def build_body(%Message{} = message),
    do: HTTP.safe_encode(Message.to_webpush_payload(message)) |> wrap_encode()

  def build_body(payload) when is_map(payload), do: HTTP.safe_encode(payload) |> wrap_encode()
  def build_body(payload) when is_binary(payload), do: {:ok, payload}

  def build_body(other),
    do:
      {:error,
       Response.error(
         :webpush,
         :invalid_request,
         "payload must be a binary, map or PushX.Message, got: #{inspect(other)}"
       )}

  defp wrap_encode({:ok, json}), do: {:ok, json}

  defp wrap_encode({:error, reason}),
    do:
      {:error, Response.error(:webpush, :invalid_request, "Failed to encode payload: #{reason}")}

  defp check_size(body) do
    if byte_size(body) > Encryption.max_plaintext(), do: {:error, payload_too_large()}, else: :ok
  end

  defp payload_too_large do
    Response.error(
      :webpush,
      :payload_too_large,
      "Payload exceeds the #{Encryption.max_plaintext()}-byte Web Push limit"
    )
  end

  defp validate_opts(opts) do
    urgency = Keyword.get(opts, :urgency)
    topic = Keyword.get(opts, :topic)
    ttl = Keyword.get(opts, :ttl, @default_ttl)

    cond do
      not (is_integer(ttl) and ttl >= 0) ->
        {:error,
         Response.error(
           :webpush,
           :invalid_request,
           "Invalid :ttl #{inspect(ttl)}: expected a non-negative integer (seconds)"
         )}

      not is_nil(urgency) and urgency not in [:very_low, :low, :normal, :high] ->
        {:error,
         Response.error(
           :webpush,
           :invalid_request,
           "Invalid :urgency #{inspect(urgency)}: expected :very_low | :low | :normal | :high"
         )}

      not is_nil(topic) and not (is_binary(topic) and Regex.match?(@topic_regex, topic)) ->
        {:error,
         Response.error(
           :webpush,
           :invalid_request,
           "Invalid :topic #{inspect(topic)}: up to 32 base64url characters"
         )}

      true ->
        :ok
    end
  end

  defp urgency_header(nil), do: nil
  defp urgency_header(:very_low), do: "very-low"
  defp urgency_header(level), do: Atom.to_string(level)

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    case URI.parse(endpoint) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" -> :ok
      # http is accepted so PushX's own tests can use a local push service.
      %URI{scheme: "http", host: host} when is_binary(host) and host != "" -> :ok
      _ -> invalid_subscription("endpoint must be an https URL")
    end
  end

  defp validate_endpoint(_), do: invalid_subscription("endpoint is missing")

  defp decode_key(nil, _size, name), do: invalid_subscription("#{name} is missing")

  defp decode_key(value, size, name) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, <<_::binary-size(^size)>> = raw} -> {:ok, raw}
      {:ok, _} -> invalid_subscription("#{name} must be #{size} bytes")
      :error -> invalid_subscription("#{name} is not base64url")
    end
  end

  defp decode_key(_, _size, name), do: invalid_subscription("#{name} must be a base64url string")

  defp invalid_subscription(reason),
    do: {:error, Response.error(:webpush, :invalid_token, "Invalid subscription: #{reason}")}

  defp get(map, key) when is_atom(key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
