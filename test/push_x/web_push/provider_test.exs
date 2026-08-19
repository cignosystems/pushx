defmodule PushX.WebPush.ProviderTest do
  use ExUnit.Case, async: false

  alias PushX.Instance.Loader
  alias PushX.{Response, WebPush}
  alias PushX.WebPush.{Encryption, VAPID}

  defmodule Sink do
    def invalid(provider, target, pid), do: send(pid, {:invalid_token, provider, target})
  end

  # --- the browser side: a subscription for our Bypass "push service" --------
  defp browser_subscription(bypass, path \\ "/push/sub-1") do
    {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
    auth = :crypto.strong_rand_bytes(16)

    subscription = %{
      "endpoint" => "http://localhost:#{bypass.port}#{path}",
      "keys" => %{
        "p256dh" => Base.url_encode64(ua_public, padding: false),
        "auth" => Base.url_encode64(auth, padding: false)
      }
    }

    {subscription, ua_private, auth}
  end

  defp vapid_jwk(public_b64) do
    <<4, x::binary-32, y::binary-32>> = Base.url_decode64!(public_b64, padding: false)

    JOSE.JWK.from_map(%{
      "kty" => "EC",
      "crv" => "P-256",
      "x" => Base.url_encode64(x, padding: false),
      "y" => Base.url_encode64(y, padding: false)
    })
  end

  setup do
    bypass = Bypass.open()
    keys = VAPID.generate()
    Application.put_env(:pushx, :webpush_vapid_subject, "mailto:ops@example.com")
    Application.put_env(:pushx, :webpush_vapid_public_key, keys.public_key)
    Application.put_env(:pushx, :webpush_vapid_private_key, keys.private_key)
    Application.put_env(:pushx, :retry_enabled, false)

    on_exit(fn ->
      for k <- [
            :webpush_vapid_subject,
            :webpush_vapid_public_key,
            :webpush_vapid_private_key,
            :retry_enabled
          ],
          do: Application.delete_env(:pushx, k)

      PushX.JWTCache.invalidate({:vapid_jwt, :static, "http://localhost:#{bypass.port}"})
    end)

    {:ok, bypass: bypass, vapid: keys}
  end

  describe "send/3 end to end" do
    test "encrypts per RFC 8291, authenticates with VAPID, and the browser can decrypt", %{
      bypass: bypass,
      vapid: vapid
    } do
      {subscription, ua_private, auth} = browser_subscription(bypass)

      Bypass.expect_once(bypass, "POST", "/push/sub-1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)

        assert Plug.Conn.get_req_header(conn, "content-encoding") == ["aes128gcm"]
        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/octet-stream"]
        assert Plug.Conn.get_req_header(conn, "ttl") == ["60"]
        assert Plug.Conn.get_req_header(conn, "urgency") == ["high"]
        assert Plug.Conn.get_req_header(conn, "topic") == ["order-42"]

        # VAPID: "vapid t=<jwt>, k=<public key>", JWT verifiable with the configured public key
        ["vapid t=" <> rest] = Plug.Conn.get_req_header(conn, "authorization")
        [jwt, k] = String.split(rest, ", k=")
        assert k == vapid.public_key

        assert {true, %JOSE.JWT{fields: claims}, _} =
                 JOSE.JWT.verify_strict(vapid_jwk(vapid.public_key), ["ES256"], jwt)

        assert claims["aud"] == "http://localhost:#{bypass.port}"
        assert claims["sub"] == "mailto:ops@example.com"

        # The browser decrypts the body with its private key and auth secret.
        assert {:ok, plaintext} = Encryption.decrypt(body, ua_private, auth)

        assert JSON.decode!(plaintext) == %{
                 "title" => "Hi",
                 "body" => "There",
                 "data" => %{"url" => "/x"}
               }

        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "http://localhost:#{bypass.port}/push/sub-1/msg-1"
        )
        |> Plug.Conn.resp(201, "")
      end)

      message = PushX.Message.new("Hi", "There") |> PushX.Message.data(%{"url" => "/x"})

      assert {:ok, %Response{provider: :webpush, status: :sent, id: "http://localhost:" <> _}} =
               WebPush.send(subscription, message, ttl: 60, urgency: :high, topic: "order-42")
    end

    test "maps, raw binaries, and the unified API all work; default TTL is four weeks", %{
      bypass: bypass
    } do
      {subscription, ua_private, auth} = browser_subscription(bypass)
      {:ok, seen} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "POST", "/push/sub-1", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        {:ok, plaintext} = Encryption.decrypt(body, ua_private, auth)
        Agent.update(seen, &[plaintext | &1])
        assert Plug.Conn.get_req_header(conn, "ttl") == ["2419200"]
        assert Plug.Conn.get_req_header(conn, "urgency") == []
        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, _} = WebPush.send(subscription, %{"title" => "Map"})
      assert {:ok, _} = WebPush.send(subscription, "raw text payload")
      assert {:ok, %Response{status: :sent}} = PushX.push(:webpush, subscription, "Hello")
      assert {:ok, _} = PushX.push_data(:webpush, subscription, %{"action" => "sync"})
      assert :ok = PushX.push!(:webpush, subscription, "Hello")

      # Compare decoded (map key order in JSON is not significant).
      assert Enum.map(Agent.get(seen, &Enum.reverse/1), fn p ->
               case JSON.decode(p) do
                 {:ok, m} -> m
                 _ -> p
               end
             end) ==
               [
                 %{"title" => "Map"},
                 "raw text payload",
                 %{"title" => "Hello", "body" => ""},
                 %{"action" => "sync"},
                 %{"title" => "Hello", "body" => ""}
               ]
    end

    test "response mapping: 404/410 are unregistered (and fire on_invalid_token with the subscription), 400/413/429/5xx map too",
         %{bypass: bypass} do
      {subscription, _, _} = browser_subscription(bypass)
      Application.put_env(:pushx, :on_invalid_token, {Sink, :invalid, [self()]})
      on_exit(fn -> Application.delete_env(:pushx, :on_invalid_token) end)

      for {status, expected} <- [
            {410, :unregistered},
            {404, :unregistered},
            {400, :invalid_request},
            {413, :payload_too_large},
            {429, :rate_limited},
            {502, :server_error},
            {418, :unknown_error}
          ] do
        Bypass.expect_once(bypass, "POST", "/push/sub-1", fn conn ->
          conn |> Plug.Conn.put_resp_header("retry-after", "9") |> Plug.Conn.resp(status, "nope")
        end)

        assert {:error, %Response{status: ^expected, reason: reason} = resp} =
                 PushX.push(:webpush, subscription, "x")

        assert reason =~ "HTTP #{status}"
        if expected == :rate_limited, do: assert(resp.retry_after == 9)
        if expected == :unregistered, do: assert(Response.should_remove_token?(resp))
      end

      # The cleanup callback received the subscription map, twice (404 and 410).
      assert_receive {:invalid_token, :webpush, ^subscription}
      assert_receive {:invalid_token, :webpush, ^subscription}
      refute_receive {:invalid_token, _, _}, 50
    end

    test "a 401/403 drops the cached VAPID JWT and retries once with a fresh one", %{
      bypass: bypass
    } do
      {subscription, _, _} = browser_subscription(bypass)
      {:ok, tokens} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "POST", "/push/sub-1", fn conn ->
        ["vapid t=" <> rest] = Plug.Conn.get_req_header(conn, "authorization")
        [jwt, _] = String.split(rest, ", k=")
        n = Agent.get_and_update(tokens, fn acc -> {length(acc) + 1, acc ++ [jwt]} end)
        if n == 1, do: Plug.Conn.resp(conn, 403, "bad jwt"), else: Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, %Response{status: :sent}} = WebPush.send(subscription, "x")
      assert [first, second] = Agent.get(tokens, & &1)
      # ES256 signatures are randomised, so a re-signed JWT differs.
      refute first == second

      # A second rejection in the same send is returned as auth_error.
      Bypass.expect(bypass, "POST", "/push/sub-1", fn conn ->
        Plug.Conn.resp(conn, 401, "still bad")
      end)

      assert {:error, %Response{status: :auth_error}} = WebPush.send(subscription, "x")
    end

    test "connection errors are connection_error", %{bypass: bypass} do
      {subscription, _, _} = browser_subscription(bypass)
      Bypass.down(bypass)

      assert {:error, %Response{status: :connection_error, provider: :webpush}} =
               WebPush.send(subscription, "x")
    end
  end

  describe "local validation (no network)" do
    test "subscriptions are validated: endpoint, p256dh (65-byte point), auth (16 bytes)", %{
      bypass: bypass
    } do
      {good, _, _} = browser_subscription(bypass)

      bad = [
        {Map.delete(good, "endpoint"), "endpoint is missing"},
        {%{good | "endpoint" => "ftp://x"}, "endpoint must be an https URL"},
        {put_in(good, ["keys", "p256dh"], Base.url_encode64(<<4, 1::8>>, padding: false)),
         "p256dh must be 65 bytes"},
        {put_in(good, ["keys", "p256dh"], "***"), "p256dh is not base64url"},
        {put_in(good, ["keys", "auth"], Base.url_encode64(<<0::8>>, padding: false)),
         "auth must be 16 bytes"},
        {Map.delete(good, "keys"), "p256dh is missing"},
        {"not a map", "expected a subscription map"}
      ]

      for {sub, reason} <- bad do
        assert {:error, %Response{status: :invalid_token, reason: full}} =
                 WebPush.send_once(sub, "x")

        assert full =~ reason, "expected #{inspect(reason)} for #{inspect(sub)}"
      end

      # Atom keys are fine.
      atom_sub = %{
        endpoint: good["endpoint"],
        keys: %{p256dh: good["keys"]["p256dh"], auth: good["keys"]["auth"]}
      }

      assert {:ok, %{endpoint: _, ua_public: <<4, _::binary-64>>, auth: <<_::binary-16>>}} =
               WebPush.validate_subscription(atom_sub)
    end

    test "options and payload size are validated before anything is sent", %{bypass: bypass} do
      {sub, _, _} = browser_subscription(bypass)

      assert {:error, %Response{status: :invalid_request, reason: r}} =
               WebPush.send_once(sub, "x", ttl: -1)

      assert r =~ ":ttl"

      assert {:error, %Response{status: :invalid_request, reason: r}} =
               WebPush.send_once(sub, "x", urgency: :asap)

      assert r =~ ":urgency"

      assert {:error, %Response{status: :invalid_request, reason: r}} =
               WebPush.send_once(sub, "x", topic: String.duplicate("a", 33))

      assert r =~ ":topic"
      assert {:error, %Response{status: :invalid_request, reason: r}} = WebPush.send_once(sub, 42)
      assert r =~ "payload must be"

      assert {:error, %Response{status: :payload_too_large}} =
               WebPush.send_once(sub, String.duplicate("x", Encryption.max_plaintext() + 1))
    end

    test "more local validation: compressed point, non-string keys, unencodable payload, https endpoint, very_low urgency",
         %{bypass: bypass} do
      {good, _, _} = browser_subscription(bypass)

      # A 65-byte value that is not an uncompressed point (prefix 0x05).
      compressed =
        put_in(good, ["keys", "p256dh"], Base.url_encode64(<<5, 0::512>>, padding: false))

      assert {:error, %Response{reason: r}} = WebPush.send_once(compressed, "x")
      assert r =~ "uncompressed P-256 point"

      assert {:error, %Response{reason: r}} =
               WebPush.send_once(put_in(good, ["keys", "auth"], 42), "x")

      assert r =~ "must be a base64url string"

      assert {:error, %Response{status: :invalid_request, reason: r}} =
               WebPush.send_once(good, %{"bad" => {:tuple, 1}})

      assert r =~ "Failed to encode payload"

      # https endpoints validate (this one is never contacted: invalid auth length stops it).
      https_sub =
        %{good | "endpoint" => "https://push.example.com/x"} |> put_in(["keys", "auth"], "AAAA")

      assert {:error, %Response{reason: r}} = WebPush.send_once(https_sub, "x")
      assert r =~ "auth must be 16 bytes"

      # :very_low is sent as "very-low"; the rate-limit/breaker gate error path is exercised via SendGate.
      Bypass.expect_once(bypass, "POST", "/push/sub-1", fn conn ->
        assert Plug.Conn.get_req_header(conn, "urgency") == ["very-low"]
        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, _} = WebPush.send_once(good, "x", urgency: :very_low)

      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_webpush, 1)

      on_exit(fn ->
        Application.delete_env(:pushx, :rate_limit_enabled)
        Application.delete_env(:pushx, :rate_limit_webpush)
        PushX.RateLimiter.reset(:webpush)
      end)

      assert PushX.RateLimiter.check_and_increment(:webpush) == :ok

      assert {:error, %Response{status: :rate_limited, provider: :webpush}} =
               WebPush.send_once(good, "x")
    end

    test "a VAPID key that is configured but unusable is an auth_error at send time", %{
      bypass: bypass
    } do
      {sub, _, _} = browser_subscription(bypass)
      Application.put_env(:pushx, :webpush_vapid_private_key, "not-a-key")

      assert {:error, %Response{status: :auth_error, reason: reason}} =
               WebPush.send_once(sub, "x")

      assert reason =~ "base64url"
    end

    test "not configured → :not_configured (never retried)", %{bypass: bypass} do
      {sub, _, _} = browser_subscription(bypass)
      Application.delete_env(:pushx, :webpush_vapid_private_key)

      assert {:error, %Response{status: :not_configured, reason: reason} = resp} =
               WebPush.send(sub, "x")

      assert reason =~ "webpush_vapid"
      refute Response.retryable?(resp)
    end

    test "health_check reports webpush; generate_vapid_keys/0 produces usable keys" do
      assert %{webpush: %{configured: true, circuit: :closed}} = PushX.health_check()
      assert %{public_key: pub, private_key: priv} = WebPush.generate_vapid_keys()
      assert {:ok, _} = VAPID.resolve_keys(pub, priv)
    end
  end

  describe "batch and test delivery mode" do
    test "push_batch/4 over subscriptions", %{bypass: bypass} do
      {s1, _, _} = browser_subscription(bypass, "/push/a")
      {s2, _, _} = browser_subscription(bypass, "/push/b")

      Bypass.expect_once(bypass, "POST", "/push/a", fn conn -> Plug.Conn.resp(conn, 201, "") end)
      Bypass.expect_once(bypass, "POST", "/push/b", fn conn -> Plug.Conn.resp(conn, 410, "") end)

      assert [
               {^s1, {:ok, %Response{status: :sent}}},
               {^s2, {:error, %Response{status: :unregistered}}}
             ] =
               PushX.push_batch(:webpush, [s1, s2], "Hi", validate_tokens: true)
    end

    test "test delivery mode records the plaintext payload and needs no VAPID config", %{
      bypass: bypass
    } do
      import PushX.Test.Assertions
      Application.put_env(:pushx, :delivery, :test)
      Application.delete_env(:pushx, :webpush_vapid_private_key)
      on_exit(fn -> Application.delete_env(:pushx, :delivery) end)

      {sub, _, _} = browser_subscription(bypass)

      assert {:ok, %Response{status: :sent}} =
               PushX.push(:webpush, sub, PushX.Message.new("Hi", "There"))

      assert {:ok, _} = WebPush.send(sub, "raw")

      push = assert_pushed(%{provider: :webpush, target: ^sub, payload: %{"title" => "Hi"}})
      assert push.payload == %{"title" => "Hi", "body" => "There"}
      assert_pushed(%{provider: :webpush, payload: "raw"})
      # Validation still runs in test mode.
      assert {:error, %Response{status: :invalid_token}} =
               PushX.push(:webpush, %{"endpoint" => "x"}, "Hi")
    end
  end

  describe "named instances" do
    test "a :webpush instance has its own VAPID identity and pool; keys are validated at start",
         %{bypass: bypass} do
      tenant = VAPID.generate()

      {:ok, :tenant_web} =
        PushX.Instance.start(:tenant_web, :webpush,
          vapid_subject: "mailto:tenant@example.com",
          vapid_private_key: tenant.private_key,
          connect_timeout: 1
        )

      on_exit(fn ->
        PushX.Instance.stop(:tenant_web)
        PushX.JWTCache.invalidate({:vapid_jwt, :tenant_web, "http://localhost:#{bypass.port}"})
      end)

      {subscription, ua_private, auth} = browser_subscription(bypass, "/push/tenant")

      Bypass.expect_once(bypass, "POST", "/push/tenant", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        ["vapid t=" <> rest] = Plug.Conn.get_req_header(conn, "authorization")
        [jwt, k] = String.split(rest, ", k=")
        # Signed with the tenant's key (derived public key matches), subject is the tenant's.
        assert k == tenant.public_key

        assert {true, %JOSE.JWT{fields: %{"sub" => "mailto:tenant@example.com"}}, _} =
                 JOSE.JWT.verify_strict(vapid_jwk(tenant.public_key), ["ES256"], jwt)

        assert {:ok, plaintext} = Encryption.decrypt(body, ua_private, auth)
        assert JSON.decode!(plaintext)["title"] == "Tenant hello"
        Plug.Conn.resp(conn, 201, "")
      end)

      assert {:ok, %Response{status: :sent, provider: :webpush}} =
               PushX.push(:tenant_web, subscription, "Tenant hello")

      assert {:ok, %{provider: :webpush, enabled: true}} = PushX.Instance.status(:tenant_web)

      assert %{instances: %{tenant_web: %{provider: :webpush, circuit: :closed}}} =
               PushX.health_check()

      assert {:error, %Response{status: :invalid_request}} =
               PushX.subscribe(:tenant_web, ["t"], "x")

      assert {:error, {:missing_config, [:vapid_private_key]}} =
               PushX.Instance.start(:bad_web, :webpush, vapid_subject: "mailto:x@y")

      assert {:error, {:invalid_vapid_key, _}} =
               PushX.Instance.start(:bad_web2, :webpush,
                 vapid_subject: "mailto:x@y",
                 vapid_private_key: "nope"
               )

      assert {:error, {:invalid_vapid_key, reason}} =
               PushX.Instance.start(:bad_web3, :webpush,
                 vapid_subject: "mailto:x@y",
                 vapid_private_key: tenant.private_key,
                 vapid_public_key: VAPID.generate().public_key
               )

      assert reason =~ "does not match"
    end

    test "the Loader accepts :webpush specs" do
      tenant = VAPID.generate()

      ExUnit.CaptureLog.capture_log(fn ->
        assert %{started: [:loader_web]} =
                 Loader.load(
                   instances: [
                     {:loader_web, :webpush,
                      [
                        vapid_subject: "mailto:a@b",
                        vapid_private_key: tenant.private_key,
                        connect_timeout: 1
                      ]}
                   ]
                 )
      end)

      on_exit(fn -> PushX.Instance.stop(:loader_web) end)
      assert {:ok, %{provider: :webpush}} = PushX.Instance.status(:loader_web)
    end
  end
end
