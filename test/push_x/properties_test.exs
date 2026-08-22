defmodule PushX.PropertiesTest do
  @moduledoc false
  # Property-based tests for the library's pure, input-shaped functions:
  # token validation, payload builders, error-code classification,
  # Retry-After parsing, and the batch timeout budget. Everything else in
  # PushX is I/O plumbing and is covered by the example-based suites.

  use ExUnit.Case
  use ExUnitProperties

  alias PushX.{Config, FCM, HTTP, Message, Response, Token, WebPush}
  alias PushX.WebPush.VAPID

  @statuses [
    :sent,
    :invalid_token,
    :expired_token,
    :unregistered,
    :payload_too_large,
    :rate_limited,
    :server_error,
    :connection_error,
    :circuit_open,
    :provider_disabled,
    :invalid_request,
    :auth_error,
    :unknown_error
  ]

  # -- Generators -------------------------------------------------------------

  defp hex_string(min, max) do
    string([?0..?9, ?a..?f, ?A..?F], min_length: min, max_length: max)
  end

  # Constructive (not filtered) even-length hex tokens in the valid range.
  defp valid_apns_token do
    bind(integer(32..256), fn half -> hex_string(2 * half, 2 * half) end)
  end

  # Odd-length hex tokens inside the length range — the only reason they fail.
  defp odd_length_apns_token do
    bind(integer(32..255), fn half -> hex_string(2 * half + 1, 2 * half + 1) end)
  end

  defp fcm_charset_string(min, max) do
    string([?a..?z, ?A..?Z, ?0..?9, ?_, ?:, ?-], min_length: min, max_length: max)
  end

  # JSON-safe scalar values: what a caller can legitimately put in `data`.
  defp json_scalar do
    one_of([string(:printable), integer(), float(), boolean()])
  end

  # Nested JSON-safe terms, bounded so payloads stay small.
  defp json_term do
    tree(json_scalar(), fn child ->
      one_of([list_of(child, max_length: 3), map_of(string(:alphanumeric), child, max_length: 3)])
    end)
  end

  defp data_map do
    map_of(
      one_of([string(:alphanumeric, min_length: 1), atom(:alphanumeric)]),
      json_term(),
      max_length: 5
    )
  end

  defp message do
    gen all(
          title <- one_of([constant(nil), string(:printable, min_length: 1, max_length: 40)]),
          body <- one_of([constant(nil), string(:printable, max_length: 80)]),
          badge <- one_of([constant(nil), non_negative_integer()]),
          sound <- one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
          image <- one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
          priority <- one_of([constant(nil), member_of([:high, :normal])]),
          ttl <- one_of([constant(nil), non_negative_integer()]),
          collapse <- one_of([constant(nil), string(:alphanumeric, min_length: 1)]),
          subtitle <- one_of([constant(nil), string(:printable, min_length: 1, max_length: 20)]),
          mutable <- boolean(),
          content_avail <- boolean(),
          level <-
            one_of([constant(nil), member_of([:passive, :active, :time_sensitive, :critical])]),
          score <- one_of([constant(nil), float(min: 0.0, max: 1.0)]),
          body_loc <-
            one_of([
              constant(nil),
              tuple(
                {string(:alphanumeric, min_length: 1), list_of(string(:printable), max_length: 3)}
              )
            ]),
          data <- data_map()
        ) do
      base = if title, do: Message.new(title, body || ""), else: Message.new()

      base
      |> then(fn m -> if body && !title, do: Message.body(m, body), else: m end)
      |> then(fn m -> if badge, do: Message.badge(m, badge), else: m end)
      |> then(fn m -> if sound, do: Message.sound(m, sound), else: m end)
      |> then(fn m -> if image, do: Message.image(m, image), else: m end)
      |> then(fn m -> if priority, do: Message.priority(m, priority), else: m end)
      |> then(fn m -> if ttl, do: Message.ttl(m, ttl), else: m end)
      |> then(fn m -> if collapse, do: Message.collapse_key(m, collapse), else: m end)
      |> then(fn m -> if subtitle, do: Message.subtitle(m, subtitle), else: m end)
      |> Message.mutable_content(mutable)
      |> Message.content_available(content_avail)
      |> then(fn m -> if level, do: Message.interruption_level(m, level), else: m end)
      |> then(fn m -> if score, do: Message.relevance_score(m, score), else: m end)
      |> then(fn m ->
        case body_loc do
          nil -> m
          {key, args} -> Message.localized_body(m, key, args)
        end
      end)
      |> Message.data(data)
    end
  end

  # -- Token validation ------------------------------------------------------

  describe "PushX.Token.validate/2" do
    property "APNS: any even-length hex token of 64..512 chars is valid" do
      check all(token <- valid_apns_token()) do
        assert Token.validate(:apns, token) == :ok
        assert Token.valid?(:apns, token)
      end
    end

    property "APNS: odd length, or length outside 64..512, is :invalid_length" do
      check all(
              token <- one_of([hex_string(1, 63), hex_string(513, 600), odd_length_apns_token()])
            ) do
        assert Token.validate(:apns, token) == {:error, :invalid_length}
      end
    end

    property "APNS: a single non-hex byte in an otherwise valid token is :invalid_format" do
      check all(
              token <- valid_apns_token(),
              pos <- integer(0..(byte_size(token) - 1)),
              bad <- one_of([member_of(~c"gzGZ !-_:."), constant(?ö)])
            ) do
        # Replace one char with a non-hex char (a multi-byte one shifts the
        # length by one, which is still caught before or at the format check).
        <<pre::binary-size(^pos), _::binary-size(1), post::binary>> = token
        mutated = pre <> <<bad::utf8>> <> post

        assert Token.validate(:apns, mutated) in [
                 {:error, :invalid_format},
                 {:error, :invalid_length}
               ]

        refute Token.valid?(:apns, mutated)
      end
    end

    property "FCM: any token from the allowed charset with 20..500 chars is valid" do
      check all(token <- fcm_charset_string(20, 500)) do
        assert Token.validate(:fcm, token) == :ok
      end
    end

    property "FCM: length outside 20..500 is :invalid_length; a bad char is :invalid_format" do
      check all(
              short <- fcm_charset_string(1, 19),
              long <- fcm_charset_string(501, 560),
              token <- fcm_charset_string(20, 499),
              bad <- member_of(~c" /+=.@#ö")
            ) do
        assert Token.validate(:fcm, short) == {:error, :invalid_length}
        assert Token.validate(:fcm, long) == {:error, :invalid_length}
        assert Token.validate(:fcm, token <> <<bad::utf8>>) == {:error, :invalid_format}
      end
    end

    property "never raises for arbitrary terms and always returns :ok or an error tuple" do
      check all(
              token <- one_of([binary(), string(:printable), term()]),
              provider <- member_of([:apns, :fcm])
            ) do
        result = Token.validate(provider, token)
        assert result == :ok or match?({:error, reason} when is_atom(reason), result)
      end
    end
  end

  # -- Payload builders -------------------------------------------------------

  describe "PushX.Message payload builders" do
    property "to_apns_payload/1 is JSON-encodable, keeps `aps` intact, and passes data through" do
      check all(message <- message()) do
        payload = Message.to_apns_payload(message)

        assert {:ok, _} = HTTP.safe_encode(payload)
        # `aps` is always PushX's map, never overwritten by caller data.
        assert is_map(payload["aps"])
        refute Map.has_key?(payload, :aps)

        if message.title do
          assert payload["aps"]["alert"]["title"] == message.title
          # A titled message always carries a sound (explicit or "default").
          assert payload["aps"]["sound"] == (message.sound || "default")
        end

        if message.badge, do: assert(payload["aps"]["badge"] == message.badge)
        # Boolean flags are the APNS integer form or absent, never false/0 noise.
        assert payload["aps"]["mutable-content"] in [nil, 1]
        assert payload["aps"]["content-available"] in [nil, 1]

        assert payload["aps"]["interruption-level"] in [
                 nil,
                 "passive",
                 "active",
                 "time-sensitive",
                 "critical"
               ]

        if message.subtitle, do: assert(payload["aps"]["alert"]["subtitle"] == message.subtitle)

        # Every non-aps top-level key comes from data, verbatim.
        for {key, value} <- payload, key != "aps" do
          assert Map.fetch!(message.data, key) == value
        end
      end
    end

    property "to_apns_options/1 always yields valid APNS option values" do
      check all(message <- message()) do
        opts = Message.to_apns_options(message)

        assert Keyword.keyword?(opts)
        assert Keyword.get(opts, :priority) in [nil, 5, 10]
        exp = Keyword.get(opts, :expiration)
        assert is_nil(exp) or (is_integer(exp) and exp >= 0)
        if message.collapse_key, do: assert(opts[:collapse_id] == message.collapse_key)
      end
    end

    property "to_fcm_payload/1 only ever produces a `notification` block, and only when needed" do
      check all(message <- message()) do
        payload = Message.to_fcm_payload(message)

        assert {:ok, _} = HTTP.safe_encode(payload)
        assert Map.keys(payload) -- ["notification"] == []

        if is_nil(message.title) and is_nil(message.body) and is_nil(message.image) do
          assert payload == %{}
        else
          assert is_map(payload["notification"])
        end
      end
    end

    property "FCM.build_message/3 stringifies every data value and encodes cleanly" do
      check all(message <- message(), token <- fcm_charset_string(20, 60)) do
        %{"message" => built} = FCM.build_message(token, message, [])

        assert built["token"] == token
        assert {:ok, _} = HTTP.safe_encode(built)

        case built["data"] do
          nil ->
            assert message.data == %{}

          data ->
            assert map_size(data) == map_size(message.data)
            assert Enum.all?(data, fn {k, v} -> is_binary(k) and is_binary(v) end)
        end

        # The apns override is JSON-safe and only present when iOS fields are set.
        ios_fields? =
          message.mutable_content or message.content_available or
            not is_nil(message.interruption_level) or not is_nil(message.relevance_score) or
            not is_nil(message.subtitle) or not is_nil(message.body_loc_key)

        assert is_map(built["apns"]) == ios_fields?

        if built["android"] do
          assert built["android"]["priority"] in [nil, "HIGH", "NORMAL"]
          if built["android"]["ttl"], do: assert(String.ends_with?(built["android"]["ttl"], "s"))
        end
      end
    end
  end

  # -- Error classification ---------------------------------------------------

  describe "PushX.Response error classification" do
    property "apns_reason_to_status/1 is total: any string maps to a known status" do
      check all(reason <- one_of([string(:printable), binary()])) do
        assert Response.apns_reason_to_status(reason) in @statuses
      end
    end

    property "fcm_error_to_status/1 is total and never yields a token-removing status for unknown codes" do
      known =
        ~w(UNREGISTERED SENDER_ID_MISMATCH INVALID_ARGUMENT QUOTA_EXCEEDED UNAVAILABLE INTERNAL)

      check all(code <- filter(one_of([string(:printable), binary()]), &(&1 not in known))) do
        status = Response.fcm_error_to_status(code)
        assert status in @statuses

        # Only the two codes Google documents as "drop this token" may remove
        # tokens; an unrecognised code must never trigger token cleanup.
        refute Response.should_remove_token?(Response.error(:fcm, status, code))
      end
    end

    property "extract_fcm_error_code/1 never raises on arbitrary decoded bodies" do
      check all(body <- json_term()) do
        result = Response.extract_fcm_error_code(body)
        assert is_nil(result) or is_binary(result)
      end
    end
  end

  # -- Retry-After parsing ----------------------------------------------------

  describe "PushX.HTTP.parse_retry_after/1" do
    property "a non-negative integer header value is returned as-is" do
      check all(seconds <- non_negative_integer()) do
        assert HTTP.parse_retry_after([{"retry-after", Integer.to_string(seconds)}]) == seconds
      end
    end

    property "any header value yields nil or a non-negative integer, never an exception" do
      check all(
              value <- one_of([string(:printable), binary()]),
              extra <- list_of({string(:alphanumeric, min_length: 1), string(:printable)})
            ) do
        result = HTTP.parse_retry_after(extra ++ [{"retry-after", value}])
        assert is_nil(result) or (is_integer(result) and result >= 0)
        assert HTTP.parse_retry_after(extra) == nil or List.keymember?(extra, "retry-after", 0)
      end
    end

    property "an HTTP-date in the past (or malformed) is nil; in the future it is positive" do
      check all(offset <- integer(-100_000..100_000)) do
        date =
          DateTime.utc_now()
          |> DateTime.add(offset, :second)
          |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")

        result = HTTP.parse_retry_after([{"retry-after", date}])

        if offset > 1 do
          assert is_integer(result) and result > 0 and result <= offset
        else
          assert result == nil
        end
      end
    end
  end

  # -- Batch timeout budget ---------------------------------------------------

  describe "PushX.Config.batch_timeout_ms/0" do
    setup do
      keys = [
        :retry_enabled,
        :retry_max_attempts,
        :receive_timeout,
        :pool_timeout,
        :retry_max_delay_ms
      ]

      on_exit(fn -> Enum.each(keys, &Application.delete_env(:pushx, &1)) end)
      :ok
    end

    property "never drops below the 30 s floor and covers the worst-case retry cycle" do
      check all(
              attempts <- integer(1..10),
              receive_timeout <- integer(0..120_000),
              pool_timeout <- integer(0..30_000),
              max_delay <- integer(0..120_000)
            ) do
        Application.put_env(:pushx, :retry_enabled, true)
        Application.put_env(:pushx, :retry_max_attempts, attempts)
        Application.put_env(:pushx, :receive_timeout, receive_timeout)
        Application.put_env(:pushx, :pool_timeout, pool_timeout)
        Application.put_env(:pushx, :retry_max_delay_ms, max_delay)

        budget = Config.batch_timeout_ms()

        worst_cycle =
          attempts * (receive_timeout + pool_timeout) + (attempts - 1) * max(max_delay, 60_000)

        assert budget >= 30_000
        assert budget >= worst_cycle
        assert budget == max(30_000, worst_cycle)
      end
    end

    property "is exactly the 30 s floor when retries are disabled, whatever the retry config" do
      check all(attempts <- integer(1..10), max_delay <- integer(0..120_000)) do
        Application.put_env(:pushx, :retry_enabled, false)
        Application.put_env(:pushx, :retry_max_attempts, attempts)
        Application.put_env(:pushx, :retry_max_delay_ms, max_delay)

        assert Config.batch_timeout_ms() == 30_000
      end
    end
  end

  # -- Web Push ---------------------------------------------------------------

  defp b64url(bin), do: Base.url_encode64(bin, padding: false)

  defp valid_subscription do
    gen all(
          host <- string(:alphanumeric, min_length: 1, max_length: 20),
          path <- string(:alphanumeric, max_length: 30),
          auth <- binary(length: 16)
        ) do
      {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)

      %{
        "endpoint" => "https://#{host}.example/#{path}",
        "keys" => %{"p256dh" => b64url(ua_public), "auth" => b64url(auth)}
      }
    end
  end

  describe "PushX.WebPush.validate_subscription/1" do
    property "accepts any https endpoint with a real P-256 point and a 16-byte auth secret" do
      check all(sub <- valid_subscription()) do
        assert {:ok,
                %{endpoint: endpoint, ua_public: <<4, _::binary-64>>, auth: <<_::binary-16>>}} =
                 WebPush.validate_subscription(sub)

        assert endpoint == sub["endpoint"]
        assert :ok = Token.validate(:webpush, sub)
      end
    end

    property "a p256dh or auth of the wrong length is always :invalid_token, never a raise" do
      check all(
              sub <- valid_subscription(),
              p_len <- integer(0..130) |> filter(&(&1 != 65)),
              a_len <- integer(0..40) |> filter(&(&1 != 16)),
              which <- member_of([:p256dh, :auth])
            ) do
        bad =
          case which do
            :p256dh -> put_in(sub, ["keys", "p256dh"], b64url(:crypto.strong_rand_bytes(p_len)))
            :auth -> put_in(sub, ["keys", "auth"], b64url(:crypto.strong_rand_bytes(a_len)))
          end

        assert {:error, %Response{provider: :webpush, status: :invalid_token}} =
                 WebPush.validate_subscription(bad)

        assert {:error, :invalid_format} = Token.validate(:webpush, bad)
      end
    end

    property "never raises for arbitrary terms" do
      check all(term <- term()) do
        assert match?({:ok, _}, WebPush.validate_subscription(term)) or
                 match?(
                   {:error, %Response{status: :invalid_token}},
                   WebPush.validate_subscription(term)
                 )
      end
    end
  end

  describe "PushX.WebPush.VAPID.validate_subject/1" do
    property "mailto:/https: with a non-empty rest is :ok; anything else is an error with a reason" do
      check all(
              rest <- string(:printable, min_length: 1, max_length: 40),
              scheme <- member_of(["mailto:", "https://", "http://", "", "ftp://"])
            ) do
        case VAPID.validate_subject(scheme <> rest) do
          :ok -> assert scheme in ["mailto:", "https://"]
          {:error, reason} -> assert reason =~ "mailto: or https:"
        end
      end
    end

    property "never raises for arbitrary terms" do
      check all(term <- term()) do
        assert VAPID.validate_subject(term) in [:ok] or
                 match?({:error, _}, VAPID.validate_subject(term))
      end
    end
  end

  describe "PushX.Message Web Push builders" do
    property "to_webpush_payload/1 is JSON-encodable, never emits nil values and never a badge" do
      check all(message <- message()) do
        payload = Message.to_webpush_payload(message)
        assert {:ok, _} = HTTP.safe_encode(payload)
        refute Enum.any?(payload, fn {_k, v} -> is_nil(v) end)
        refute Map.has_key?(payload, "badge")
        assert Map.keys(payload) -- ["title", "body", "icon", "tag", "data"] == []
        if message.title, do: assert(payload["title"] == message.title)
      end
    end

    property "to_webpush_options/1 only ever yields valid :ttl / :urgency values" do
      check all(message <- message()) do
        opts = Message.to_webpush_options(message)
        assert Keyword.keys(opts) -- [:ttl, :urgency] == []
        if ttl = opts[:ttl], do: assert(is_integer(ttl) and ttl >= 0)
        if urgency = opts[:urgency], do: assert(urgency in [:high, :normal])
      end
    end
  end
end
