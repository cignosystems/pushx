defmodule PushX.APNSTest do
  use ExUnit.Case

  alias PushX.APNS
  alias PushX.Response

  doctest PushX.APNS

  describe "notification/2" do
    test "creates a basic notification payload" do
      payload = APNS.notification("Hello", "World")

      assert payload == %{
               "aps" => %{
                 "alert" => %{"title" => "Hello", "body" => "World"},
                 "sound" => "default"
               }
             }
    end
  end

  describe "notification/3" do
    test "includes badge when provided" do
      payload = APNS.notification("Hello", "World", 5)

      assert payload["aps"]["badge"] == 5
    end

    test "omits badge when nil" do
      payload = APNS.notification("Hello", "World", nil)

      refute Map.has_key?(payload["aps"], "badge")
    end
  end

  describe "notification_with_data/4" do
    test "merges custom data into payload" do
      payload = APNS.notification_with_data("Hello", "World", %{"lock_id" => "abc123"})

      assert payload["aps"]["alert"]["title"] == "Hello"
      assert payload["lock_id"] == "abc123"
    end

    test "includes badge when provided" do
      payload = APNS.notification_with_data("Hello", "World", %{"key" => "value"}, 3)

      assert payload["aps"]["badge"] == 3
    end

    test "data with 'aps' key does not overwrite notification" do
      payload =
        APNS.notification_with_data("Hello", "World", %{
          "aps" => %{"alert" => "HACKED"},
          "safe_key" => "value"
        })

      assert payload["aps"]["alert"]["title"] == "Hello"
      assert payload["safe_key"] == "value"
    end

    test "data with atom :aps key does not overwrite notification" do
      payload =
        APNS.notification_with_data("Hello", "World", %{
          aps: %{"alert" => "HACKED"},
          safe_key: "value"
        })

      json = JSON.encode!(payload) |> JSON.decode!()
      assert json["aps"]["alert"]["title"] == "Hello"
      refute json["aps"]["alert"] == "HACKED"
    end
  end

  describe "silent_notification/1" do
    test "creates a content-available notification" do
      payload = APNS.silent_notification()

      assert payload == %{"aps" => %{"content-available" => 1}}
    end

    test "includes custom data" do
      payload = APNS.silent_notification(%{"action" => "sync"})

      assert payload["aps"]["content-available"] == 1
      assert payload["action"] == "sync"
    end

    test "data with 'aps' key does not overwrite content-available" do
      payload = APNS.silent_notification(%{"aps" => "HACKED", "action" => "sync"})

      assert payload["aps"]["content-available"] == 1
      assert payload["action"] == "sync"
    end

    test "data with atom :aps key does not overwrite content-available" do
      payload = APNS.silent_notification(%{aps: "HACKED", action: "sync"})

      json = JSON.encode!(payload) |> JSON.decode!()
      assert json["aps"] == %{"content-available" => 1}
    end
  end

  describe "send/3 validation" do
    test "returns error when topic is missing" do
      assert {:error,
              %PushX.Response{status: :invalid_request, reason: ":topic option is required"}} =
               APNS.send("token", %{"aps" => %{}}, [])
    end

    test "rejects token containing URL-special characters" do
      assert {:error, %PushX.Response{status: :invalid_token, reason: reason}} =
               APNS.send("../../etc/passwd", %{"aps" => %{}}, topic: "com.test.app")

      assert reason =~ "invalid characters"
    end

    test "rejects token containing whitespace" do
      assert {:error, %PushX.Response{status: :invalid_token}} =
               APNS.send("token with spaces", %{"aps" => %{}}, topic: "com.test.app")
    end

    test "rejects token containing query separator" do
      assert {:error, %PushX.Response{status: :invalid_token}} =
               APNS.send("token?evil=1", %{"aps" => %{}}, topic: "com.test.app")
    end

    test "rejects empty :topic before any other validation" do
      assert {:error,
              %PushX.Response{status: :invalid_request, reason: ":topic option is required"}} =
               APNS.send("token", %{"aps" => %{}}, topic: "")
    end

    test "rejects unknown :mode" do
      assert {:error, %PushX.Response{status: :invalid_request, reason: reason}} =
               APNS.send("token", %{"aps" => %{}}, topic: "com.test.app", mode: :preview)

      assert reason =~ "Invalid :mode"
    end

    test "rejects payload that exceeds 4 KB" do
      # Build a >4 KB string payload
      huge = String.duplicate("a", 5_000)

      assert {:error, %PushX.Response{status: :payload_too_large, reason: reason}} =
               APNS.send(String.duplicate("a", 64), %{"aps" => %{"alert" => huge}},
                 topic: "com.test.app"
               )

      assert reason =~ "exceeds APNS limit"
    end

    test "rejects un-encodable payload terms" do
      # PIDs aren't JSON-encodable
      payload = %{"aps" => %{}, "self" => self()}

      assert {:error, %PushX.Response{status: :invalid_request, reason: reason}} =
               APNS.send(String.duplicate("a", 64), payload, topic: "com.test.app")

      assert reason =~ "Failed to encode payload"
    end
  end

  # Drives the real PushX.APNS.send/3 path against Bypass via the test-only
  # :apns_url_override seam. Retries are disabled so retryable failures
  # (5xx, 429, connection errors) return immediately instead of backing off.
  describe "send/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :apns_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)
      PushX.JWTCache.invalidate(:apns_jwt)

      on_exit(fn ->
        Application.delete_env(:pushx, :apns_url_override)
        Application.delete_env(:pushx, :retry_enabled)
        PushX.JWTCache.invalidate(:apns_jwt)
      end)

      {:ok, bypass: bypass}
    end

    test "returns success response on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/test-device-token", fn conn ->
        # The provider JWT signed with the configured key must reach the wire.
        ["bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")
        assert {:ok, %{"kid" => "TEST_KEY_ID"}} = Joken.peek_header(jwt)
        assert {:ok, %{"iss" => "TEST_TEAM_ID"}} = Joken.peek_claims(jwt)
        assert Plug.Conn.get_req_header(conn, "apns-topic") == ["com.test.app"]

        conn
        |> Plug.Conn.put_resp_header("apns-id", "apns-unique-id-123")
        |> Plug.Conn.resp(200, "")
      end)

      result =
        APNS.send("test-device-token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:ok, %Response{status: :sent, id: "apns-unique-id-123", provider: :apns}} = result
    end

    test "returns invalid_token error on BadDeviceToken", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/bad-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      result = APNS.send("bad-token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error,
              %Response{status: :invalid_token, reason: "BadDeviceToken", provider: :apns}} =
               result
    end

    test "returns unregistered error on Unregistered", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/unregistered-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(410, ~s({"reason": "Unregistered"}))
      end)

      result =
        APNS.send("unregistered-token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :unregistered, reason: "Unregistered"}} = result
    end

    test "returns expired_token error on ExpiredToken", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/expired-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(410, ~s({"reason": "ExpiredToken"}))
      end)

      result =
        APNS.send("expired-token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :expired_token, reason: "ExpiredToken"}} = result
    end

    test "returns payload_too_large error", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(413, ~s({"reason": "PayloadTooLarge"}))
      end)

      result = APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :payload_too_large, reason: "PayloadTooLarge"}} = result
    end

    test "returns rate_limited error on TooManyRequests", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"reason": "TooManyRequests"}))
      end)

      result = APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :rate_limited, reason: "TooManyRequests"}} = result
    end

    test "returns server_error on InternalServerError", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"reason": "InternalServerError"}))
      end)

      result = APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :server_error, reason: "InternalServerError"}} = result
    end

    test "handles connection errors gracefully", %{bypass: bypass} do
      Bypass.down(bypass)

      result = APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert {:error, %Response{status: :connection_error, provider: :apns}} = result
    end

    test "sends with Message struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Verify the Message was converted to APNS format
        assert payload["aps"]["alert"]["title"] == "Test Title"
        assert payload["aps"]["alert"]["body"] == "Test Body"
        assert payload["aps"]["badge"] == 5

        conn
        |> Plug.Conn.put_resp_header("apns-id", "msg-id")
        |> Plug.Conn.resp(200, "")
      end)

      message =
        PushX.Message.new("Test Title", "Test Body")
        |> PushX.Message.badge(5)

      result = APNS.send("token", message, topic: "com.test.app")

      assert {:ok, %Response{status: :sent}} = result
    end

    test "includes custom headers when provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        # Verify headers
        assert Plug.Conn.get_req_header(conn, "apns-topic") == ["com.test.app"]
        assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["background"]
        assert Plug.Conn.get_req_header(conn, "apns-priority") == ["5"]

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      result =
        APNS.send("token", %{"aps" => %{"content-available" => 1}},
          topic: "com.test.app",
          push_type: "background",
          priority: 5
        )

      assert {:ok, %Response{status: :sent}} = result
    end

    test "falls back to the HTTP status when the error body is not JSON", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        Plug.Conn.resp(conn, 502, "bad gateway")
      end)

      assert {:error, %Response{status: :unknown_error, reason: "HTTP 502"}} =
               APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")
    end

    test "surfaces retry-after on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.resp(429, ~s({"reason": "TooManyRequests"}))
      end)

      assert {:error, %Response{status: :rate_limited, retry_after: 30}} =
               APNS.send("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")
    end

    test "send/2 and send_once/2 default opts and therefore require :topic" do
      assert {:error, %Response{status: :invalid_request, reason: ":topic option is required"}} =
               APNS.send("token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :invalid_request, reason: ":topic option is required"}} =
               APNS.send_once("token", %{"aps" => %{"alert" => "Hello"}})
    end

    test "emits a telemetry exception event and re-raises when the request itself raises" do
      Application.put_env(:pushx, :apns_url_override, "bogus://nowhere")

      test_pid = self()
      handler = "apns-exception-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:pushx, :push, :exception],
        fn event, _measurements, metadata, _ -> send(test_pid, {event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert_raise ArgumentError, fn ->
        APNS.send_once("token", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")
      end

      assert_receive {[:pushx, :push, :exception], %{provider: :apns, kind: :error}}
    end
  end

  describe "APNS not configured" do
    test "send/3 returns :not_configured without signing or sending" do
      original = Application.get_env(:pushx, :apns_key_id)
      Application.delete_env(:pushx, :apns_key_id)
      on_exit(fn -> Application.put_env(:pushx, :apns_key_id, original) end)

      assert {:error, %Response{status: :not_configured, provider: :apns, reason: reason} = resp} =
               APNS.send("token", %{"aps" => %{"alert" => "Hi"}}, topic: "com.test.app")

      assert reason =~ ":apns_key_id"
      refute Response.retryable?(resp)
    end
  end

  describe "client-side rate limit gate" do
    setup do
      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_apns, 1)
      Application.put_env(:pushx, :rate_limit_window_ms, 60_000)
      PushX.RateLimiter.reset(:apns)

      on_exit(fn ->
        Application.delete_env(:pushx, :rate_limit_enabled)
        Application.delete_env(:pushx, :rate_limit_apns)
        Application.delete_env(:pushx, :rate_limit_window_ms)
        PushX.RateLimiter.reset(:apns)
      end)

      :ok
    end

    test "send_once/3 is gated once the budget is spent" do
      assert PushX.RateLimiter.check_and_increment(:apns) == :ok

      assert {:error, %Response{status: :rate_limited, provider: :apns}} =
               APNS.send_once("token", %{"aps" => %{"alert" => "Hi"}}, topic: "com.test.app")
    end
  end

  describe "full send path via URL override" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :apns_url_override, "http://localhost:#{bypass.port}")
      PushX.JWTCache.invalidate(:apns_jwt)

      on_exit(fn ->
        Application.delete_env(:pushx, :apns_url_override)
        PushX.JWTCache.invalidate(:apns_jwt)
      end)

      {:ok, bypass: bypass}
    end

    test "ExpiredProviderToken invalidates the cached JWT and retries once", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token1", fn conn ->
        attempt = Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(403, ~s({"reason": "ExpiredProviderToken"}))
        else
          conn
          |> Plug.Conn.put_resp_header("apns-id", "retry-ok")
          |> Plug.Conn.resp(200, "")
        end
      end)

      assert {:ok, %Response{status: :sent, id: "retry-ok"}} =
               APNS.send("token1", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert Agent.get(counter, & &1) == 2
    end

    test "a second provider-token rejection surfaces :auth_error without looping", %{
      bypass: bypass
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token2", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(403, ~s({"reason": "InvalidProviderToken"}))
      end)

      assert {:error, %Response{status: :auth_error, reason: "InvalidProviderToken"}} =
               APNS.send("token2", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert Agent.get(counter, & &1) == 2
    end

    test "Message priority/ttl/collapse_key reach the wire as APNS headers", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/3/device/hdr-token", fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_header("apns-id", "hdr-id")
        |> Plug.Conn.resp(200, "")
      end)

      message =
        PushX.Message.new("Title", "Body")
        |> PushX.Message.priority(:normal)
        |> PushX.Message.ttl(3600)
        |> PushX.Message.collapse_key("updates")

      assert {:ok, %Response{status: :sent}} =
               APNS.send("hdr-token", message, topic: "com.test.app")

      assert_receive {:headers, headers}
      headers = Map.new(headers)

      assert headers["apns-priority"] == "5"
      assert headers["apns-collapse-id"] == "updates"
      expiration = String.to_integer(headers["apns-expiration"])
      assert expiration >= System.system_time(:second) + 3590
    end

    test "background push_type defaults to apns-priority 5", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/3/device/bg-token", fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_header("apns-id", "bg-id")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, _} =
               APNS.send("bg-token", APNS.silent_notification(),
                 topic: "com.test.app",
                 push_type: "background"
               )

      assert_receive {:headers, headers}
      headers = Map.new(headers)
      assert headers["apns-push-type"] == "background"
      assert headers["apns-priority"] == "5"
    end

    test "explicit priority still wins for background pushes", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/3/device/bg-token2", fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_header("apns-id", "bg-id2")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, _} =
               APNS.send("bg-token2", APNS.silent_notification(),
                 topic: "com.test.app",
                 push_type: "background",
                 priority: 10
               )

      assert_receive {:headers, headers}
      assert Map.new(headers)["apns-priority"] == "10"
    end

    test "alert pushes keep the default priority 10", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/3/device/alert-token", fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_header("apns-id", "alert-id")
        |> Plug.Conn.resp(200, "")
      end)

      assert {:ok, _} =
               APNS.send("alert-token", %{"aps" => %{"alert" => "Hi"}}, topic: "com.test.app")

      assert_receive {:headers, headers}
      assert Map.new(headers)["apns-priority"] == "10"
    end

    test "explicit opts win over Message-derived options", %{bypass: bypass} do
      test_pid = self()

      Bypass.expect_once(bypass, "POST", "/3/device/hdr-token2", fn conn ->
        send(test_pid, {:headers, conn.req_headers})

        conn
        |> Plug.Conn.put_resp_header("apns-id", "hdr-id2")
        |> Plug.Conn.resp(200, "")
      end)

      message = PushX.Message.new("Title", "Body") |> PushX.Message.priority(:normal)

      assert {:ok, _} =
               APNS.send("hdr-token2", message, topic: "com.test.app", priority: 10)

      assert_receive {:headers, headers}
      assert Map.new(headers)["apns-priority"] == "10"
    end

    test "TooManyProviderTokenUpdates does not regenerate the JWT", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token3", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"reason": "TooManyProviderTokenUpdates"}))
      end)

      assert {:error, %Response{status: :auth_error, reason: "TooManyProviderTokenUpdates"}} =
               APNS.send("token3", %{"aps" => %{"alert" => "Hello"}}, topic: "com.test.app")

      assert Agent.get(counter, & &1) == 1
    end
  end
end
