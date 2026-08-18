defmodule PushX.FCMTest do
  use ExUnit.Case

  alias PushX.FCM
  alias PushX.Response

  defmodule Sink do
    def invalid(provider, token, pid), do: send(pid, {:invalid_token, provider, token})
  end

  defmodule Fetchers do
    def raise_it(_), do: raise("vault down")
    def exit_it(_), do: exit({:noproc, {GenServer, :call, [MyApp.Goth, :fetch, 5000]}})
    def error_it(_), do: {:error, :timeout}
    def wrong_shape(_), do: {:ok, "bare"}
    def with_arg(goth_name, extra), do: {:ok, %{token: "#{goth_name}-#{extra}"}}
  end

  doctest PushX.FCM

  describe "notification/2" do
    test "creates a basic notification payload" do
      payload = FCM.notification("Hello", "World")

      assert payload == %{
               "title" => "Hello",
               "body" => "World"
             }
    end
  end

  describe "notification/3" do
    test "includes image when provided" do
      payload = FCM.notification("Hello", "World", image: "https://example.com/img.png")

      assert payload["image"] == "https://example.com/img.png"
    end

    test "omits image when not provided" do
      payload = FCM.notification("Hello", "World", [])

      refute Map.has_key?(payload, "image")
    end
  end

  # These tests drive the *real* send path — PushX.FCM.send/3, send_once/3,
  # send_data/3, send_web/5 — against a Bypass server via the test-only
  # :fcm_url_override seam. OAuth is stubbed by :fcm_token_fetcher (see
  # test_helper.exs). Retries are disabled so retryable failures (5xx, 429,
  # connection errors) return immediately instead of backing off.
  describe "send/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)

      on_exit(fn ->
        Application.delete_env(:pushx, :fcm_url_override)
        Application.delete_env(:pushx, :retry_enabled)
      end)

      {:ok, bypass: bypass}
    end

    test "returns success response on 200 with message ID", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # The OAuth token from the fetcher seam must reach the wire.
        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer #{PushX.TestOAuth.token()}"]

        assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]

        # Verify request structure
        assert payload["message"]["token"] == "test-device-token"
        assert payload["message"]["notification"]["title"] == "Hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "projects/test-project/messages/msg-123"}))
      end)

      result = FCM.send("test-device-token", %{"title" => "Hello", "body" => "World"})

      assert {:ok,
              %Response{
                status: :sent,
                id: "projects/test-project/messages/msg-123",
                provider: :fcm
              }} = result
    end

    test "returns success even without message ID in response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({}))
      end)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:ok, %Response{status: :sent, id: nil, provider: :fcm}} = result
    end

    test "honours :project_id override in the request URL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/other-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      assert {:ok, %Response{status: :sent}} =
               FCM.send("token", %{"title" => "Hi", "body" => "There"},
                 project_id: "other-project"
               )
    end

    test "returns invalid_request error on INVALID_ARGUMENT (must not remove tokens)", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          400,
          ~s({"error": {"status": "INVALID_ARGUMENT", "message": "Invalid token"}})
        )
      end)

      result = FCM.send("bad-token", %{"title" => "Hi", "body" => "There"})

      assert {:error,
              %Response{status: :invalid_request, reason: "Invalid token", provider: :fcm} = resp} =
               result

      refute Response.should_remove_token?(resp)
    end

    test "returns unregistered error on UNREGISTERED", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          ~s({"error": {"status": "UNREGISTERED", "message": "Token not registered"}})
        )
      end)

      result = FCM.send("unregistered-token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unregistered, reason: "Token not registered"} = resp} =
               result

      assert Response.should_remove_token?(resp)
    end

    test "returns unregistered when UNREGISTERED is in details array (NOT_FOUND wrapper)",
         %{bypass: bypass} do
      # FCM often returns UNREGISTERED wrapped in details with NOT_FOUND as top-level status
      error_body =
        JSON.encode!(%{
          "error" => %{
            "code" => 404,
            "message" => "Requested entity was not found.",
            "status" => "NOT_FOUND",
            "details" => [
              %{
                "@type" => "type.googleapis.com/google.firebase.fcm.v1.FcmError",
                "errorCode" => "UNREGISTERED"
              }
            ]
          }
        })

      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, error_body)
      end)

      result = FCM.send("old-token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unregistered, reason: "Requested entity was not found."}} =
               result
    end

    test "returns rate_limited error on QUOTA_EXCEEDED and surfaces retry-after", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "7")
        |> Plug.Conn.resp(
          429,
          ~s({"error": {"status": "QUOTA_EXCEEDED", "message": "Rate limit exceeded"}})
        )
      end)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:error,
              %Response{status: :rate_limited, reason: "Rate limit exceeded", retry_after: 7}} =
               result
    end

    test "returns server_error on UNAVAILABLE", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          503,
          ~s({"error": {"status": "UNAVAILABLE", "message": "Service unavailable"}})
        )
      end)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :server_error, reason: "Service unavailable"}} = result
    end

    test "returns server_error on INTERNAL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error": {"status": "INTERNAL", "message": "Internal error"}}))
      end)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :server_error, reason: "Internal error"}} = result
    end

    test "returns unknown_error with raw body on a non-JSON error response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        Plug.Conn.resp(conn, 502, "<html>Bad Gateway</html>")
      end)

      result = FCM.send_once("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unknown_error, reason: "HTTP 502"} = resp} = result
      assert resp.raw == "<html>Bad Gateway</html>"
    end

    test "handles connection errors gracefully", %{bypass: bypass} do
      Bypass.down(bypass)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :connection_error, provider: :fcm}} = result
    end

    test "retry: :none returns a retryable failure immediately even with retries enabled", %{
      bypass: bypass
    } do
      # The describe's setup disables retries; turn them on with a long
      # backoff so a blocking retry would be observable as a stall.
      Application.put_env(:pushx, :retry_enabled, true)
      Application.put_env(:pushx, :retry_base_delay_ms, 60_000)
      on_exit(fn -> Application.delete_env(:pushx, :retry_base_delay_ms) end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "30")
        |> Plug.Conn.resp(429, ~s({"error": {"status": "QUOTA_EXCEEDED", "message": "slow"}}))
      end)

      {us, result} =
        :timer.tc(fn ->
          FCM.send("token", %{"title" => "Hi", "body" => "There"}, retry: :none)
        end)

      assert {:error, %Response{status: :rate_limited, retry_after: 30}} = result
      assert Agent.get(counter, & &1) == 1
      assert us < 5_000_000
    end

    test "returns connection_error when the OAuth token cannot be fetched" do
      # No request reaches the server: the token is fetched before sending, and
      # an unexpected request would surface as a Bypass 500 / different status.
      Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch_error, []})

      on_exit(fn ->
        Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})
      end)

      assert {:error, %Response{status: :connection_error, provider: :fcm, reason: reason}} =
               FCM.send_once("token", %{"title" => "Hi", "body" => "There"})

      assert reason =~ "OAuth token error"
      assert reason =~ "oauth_down"
    end

    test "rejects oversized payloads before fetching a token or sending" do
      huge = String.duplicate("x", 5_000)

      assert {:error, %Response{status: :payload_too_large, provider: :fcm, reason: reason}} =
               FCM.send_once("token", %{"title" => "Hi", "body" => huge})

      assert reason =~ "exceeds FCM limit"
    end

    test "returns invalid_request when the payload cannot be JSON-encoded" do
      # A tuple has no JSON representation.
      assert {:error, %Response{status: :invalid_request, provider: :fcm, reason: reason}} =
               FCM.send_once("token", %{"title" => {:not, :json}, "body" => "There"})

      assert reason =~ "Failed to encode payload"
    end

    test "sends with Message struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Verify the Message was converted to FCM format
        assert payload["message"]["notification"]["title"] == "Test Title"
        assert payload["message"]["notification"]["body"] == "Test Body"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      message = PushX.Message.new("Test Title", "Test Body")
      result = FCM.send("token", message)

      assert {:ok, %Response{status: :sent}} = result
    end

    test "sends data-only message when payload has data key but no notification", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["token"] == "token"
        assert payload["message"]["data"]["action"] == "sync"
        refute Map.has_key?(payload["message"], "notification")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      result = FCM.send("token", %{"data" => %{action: "sync"}})

      assert {:ok, %Response{status: :sent}} = result
    end

    test "sends notification with data when payload has both keys", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["notification"]["title"] == "Alert"
        assert payload["message"]["data"]["event_id"] == "1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      result =
        FCM.send("token", %{
          "notification" => %{"title" => "Alert", "body" => "Something happened"},
          "data" => %{"event_id" => "1"}
        })

      assert {:ok, %Response{status: :sent}} = result
    end

    test "sends data-only message with Message struct when no title/body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["data"]["action"] == "sync"
        refute Map.has_key?(payload["message"], "notification")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      message = PushX.Message.new() |> PushX.Message.data(%{action: "sync"})
      result = FCM.send("token", message)

      assert {:ok, %Response{status: :sent}} = result
    end

    test "includes data payload when provided", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Data values should be stringified
        assert payload["message"]["data"]["key"] == "value"
        assert payload["message"]["data"]["count"] == "42"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      result =
        FCM.send("token", %{"title" => "Hi", "body" => "There"}, data: %{key: "value", count: 42})

      assert {:ok, %Response{status: :sent}} = result
    end

    test "handles error response with code instead of status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"error": {"code": 400, "message": "Bad request"}}))
      end)

      result = FCM.send("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unknown_error, reason: "Bad request"}} = result
    end

    test "validate_only: true is a dry run at the envelope level, on all builders", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)
        assert payload["validate_only"] == true
        assert is_map(payload["message"])

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "projects/test-project/messages/fake_message_id"}))
      end)

      assert {:ok, %Response{status: :sent}} =
               FCM.send("token", %{"title" => "Hi", "body" => "There"}, validate_only: true)

      assert {:ok, _} = FCM.send("token", PushX.Message.new("Hi", "There"), validate_only: true)
      assert {:ok, _} = FCM.send_data("token", %{a: 1}, validate_only: true)
      assert {:ok, _} = PushX.push(:fcm, "token", "Hi", validate_only: true)

      # Not a dry run unless explicitly true.
      %{"message" => _} = built = FCM.build_message("t", %{"title" => "x"}, validate_only: false)
      refute Map.has_key?(built, "validate_only")
    end

    test "send_web/5 sends a webpush envelope with the link", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["token"] == "web-token"
        assert payload["message"]["notification"]["title"] == "New article"
        assert payload["message"]["notification"]["icon"] == "/icon.png"
        assert payload["message"]["webpush"]["fcm_options"]["link"] == "https://example.com/p/1"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "web-msg"}))
      end)

      link = "https://example.com/p/1"

      assert {:ok, %Response{status: :sent, id: "web-msg"}} =
               FCM.send_web("web-token", "New article", "Just published", link, icon: "/icon.png")
    end

    test "emits a telemetry exception event and re-raises when the request itself raises" do
      # An override with an unsupported scheme makes Finch.build/4 raise inside
      # the instrumented block; the exception must be reported, then re-raised.
      Application.put_env(:pushx, :fcm_url_override, "bogus://nowhere")

      test_pid = self()
      handler = "fcm-exception-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:pushx, :push, :exception],
        fn event, _measurements, metadata, _ -> send(test_pid, {event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert_raise ArgumentError, fn ->
        FCM.send_once("token", %{"title" => "Hi", "body" => "There"})
      end

      assert_receive {[:pushx, :push, :exception], %{provider: :fcm, kind: :error}}
    end
  end

  describe "topic and condition targets" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)

      on_exit(fn ->
        Application.delete_env(:pushx, :fcm_url_override)
        Application.delete_env(:pushx, :retry_enabled)
      end)

      {:ok, bypass: bypass}
    end

    test "{:topic, name} sends a topic message (no token field)", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["topic"] == "news"
        refute Map.has_key?(payload["message"], "token")
        assert payload["message"]["notification"]["title"] == "Breaking"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "projects/test-project/messages/topic-1"}))
      end)

      assert {:ok, %Response{status: :sent, id: "projects/test-project/messages/topic-1"}} =
               FCM.send({:topic, "news"}, %{"title" => "Breaking", "body" => "..."})
    end

    test "{:condition, expr} sends a condition message, also for data-only", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["condition"] == "'news' in topics && 'sports' in topics"
        refute Map.has_key?(payload["message"], "token")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "m"}))
      end)

      cond_target = {:condition, "'news' in topics && 'sports' in topics"}
      assert {:ok, _} = FCM.send(cond_target, PushX.Message.new("Match", "report"))
      assert {:ok, _} = FCM.send_data(cond_target, %{event: "kickoff"})
      assert {:ok, _} = PushX.push(:fcm, cond_target, "Match report")
      assert {:ok, _} = PushX.push_data(:fcm, cond_target, %{event: "kickoff"})
    end

    test "invalid targets are rejected locally with :invalid_request" do
      for bad <- [
            {:topic, "/topics/news"},
            {:topic, "has space"},
            {:topic, ""},
            {:condition, ""},
            {:foo, "x"},
            42,
            ""
          ] do
        assert {:error, %Response{status: :invalid_request, reason: reason}} =
                 FCM.send_once(bad, %{"title" => "Hi", "body" => "There"}),
               "expected #{inspect(bad)} to be rejected"

        assert reason =~ "Invalid FCM"
      end
    end

    test "topics never trigger token cleanup" do
      # A topic-scoped error can't be about a device, so :on_invalid_token
      # must not fire (and should_remove_token? is false for the statuses
      # FCM returns for topics anyway).
      Application.put_env(:pushx, :on_invalid_token, {PushX.FCMTest.Sink, :invalid, [self()]})
      on_exit(fn -> Application.delete_env(:pushx, :on_invalid_token) end)

      # No Bypass expectation: force the local validation error path.
      assert {:error, _} = PushX.push(:fcm, {:topic, "bad topic"}, "Hi")
      refute_receive {:invalid_token, _, _}, 50
    end
  end

  describe "topic subscription management" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)

      on_exit(fn ->
        Application.delete_env(:pushx, :fcm_url_override)
        Application.delete_env(:pushx, :retry_enabled)
      end)

      {:ok, bypass: bypass}
    end

    test "subscribe/3 posts to iid/v1:batchAdd and maps per-token results in order", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/iid/v1:batchAdd", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload == %{"to" => "/topics/news", "registration_tokens" => ["t1", "t2", "t3"]}

        assert Plug.Conn.get_req_header(conn, "authorization") == [
                 "Bearer #{PushX.TestOAuth.token()}"
               ]

        assert Plug.Conn.get_req_header(conn, "access_token_auth") == ["true"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"results": [{}, {"error": "NOT_FOUND"}, {}]}))
      end)

      assert {:ok, [{"t1", :ok}, {"t2", {:error, "NOT_FOUND"}}, {"t3", :ok}]} =
               FCM.subscribe(["t1", "t2", "t3"], "news")
    end

    test "unsubscribe/3 uses batchRemove; the facade routes :fcm and rejects :apns", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/iid/v1:batchRemove", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"results": [{}]}))
      end)

      assert {:ok, [{"t1", :ok}]} = PushX.unsubscribe(:fcm, ["t1"], "news")

      assert {:error, %Response{status: :invalid_request}} =
               PushX.subscribe(:apns, ["t1"], "news")

      assert {:error, %Response{status: :unknown_error}} =
               PushX.subscribe(:no_such_instance, ["t1"], "news")
    end

    test "chunks at 1000 tokens per request and concatenates results", %{bypass: bypass} do
      {:ok, sizes} = Agent.start_link(fn -> [] end)

      Bypass.expect(bypass, "POST", "/iid/v1:batchAdd", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        n = length(JSON.decode!(body)["registration_tokens"])
        Agent.update(sizes, &(&1 ++ [n]))
        results = List.duplicate(%{}, n) |> JSON.encode!()

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"results": #{results}}))
      end)

      tokens = for i <- 1..2_500, do: "tok-#{i}"
      assert {:ok, results} = FCM.subscribe(tokens, "big")
      assert length(results) == 2_500
      assert Enum.all?(results, &match?({_, :ok}, &1))
      assert Agent.get(sizes, & &1) == [1_000, 1_000, 500]
    end

    test "validates the topic and the token list locally; empty list is a no-op" do
      assert {:error, %Response{status: :invalid_request}} = FCM.subscribe(["t"], "/topics/x")
      assert {:error, %Response{status: :invalid_request}} = FCM.subscribe(["t", 42], "news")
      assert {:error, %Response{status: :invalid_request}} = FCM.subscribe("t", "news")
      assert {:ok, []} = FCM.subscribe([], "news")
    end

    test "request-level failures come back as a Response for the whole batch", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/iid/v1:batchAdd", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          401,
          ~s({"error": {"status": "UNAUTHENTICATED", "message": "bad token"}})
        )
      end)

      assert {:error, %Response{provider: :fcm, reason: "bad token"}} =
               FCM.subscribe(["t1"], "news")

      Bypass.down(bypass)
      assert {:error, %Response{status: :connection_error}} = FCM.subscribe(["t1"], "news")
    end

    test "test delivery mode reports every token :ok without contacting anything" do
      Application.put_env(:pushx, :delivery, :test)
      on_exit(fn -> Application.delete_env(:pushx, :delivery) end)
      assert {:ok, [{"a", :ok}, {"b", :ok}]} = FCM.subscribe(["a", "b"], "news")
    end
  end

  describe "APNS rejects non-token targets" do
    test "with a clear :invalid_request instead of :invalid_token" do
      assert {:error, %Response{status: :invalid_request, provider: :apns, reason: reason}} =
               PushX.push(:apns, {:topic, "news"}, "Hi", topic: "com.test.app")

      assert reason =~ "device tokens only"
    end
  end

  describe "send_data/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)

      on_exit(fn ->
        Application.delete_env(:pushx, :fcm_url_override)
        Application.delete_env(:pushx, :retry_enabled)
      end)

      {:ok, bypass: bypass}
    end

    test "sends data-only message without notification", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer #{PushX.TestOAuth.token()}"]

        # Should have data but no notification
        assert payload["message"]["token"] == "token"
        assert payload["message"]["data"]["action"] == "sync"
        assert payload["message"]["data"]["id"] == "123"
        refute Map.has_key?(payload["message"], "notification")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "data-msg-id"}))
      end)

      result = FCM.send_data("token", %{action: "sync", id: 123})

      assert {:ok, %Response{status: :sent, id: "data-msg-id"}} = result
    end

    test "returns success without an id when the response has no name", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({}))
      end)

      assert {:ok, %Response{status: :sent, id: nil}} = FCM.send_data("token", %{a: 1})
    end

    test "stringifies all data values", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # All values should be strings
        assert payload["message"]["data"]["number"] == "42"
        assert payload["message"]["data"]["boolean"] == "true"
        assert payload["message"]["data"]["string"] == "text"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "msg-id"}))
      end)

      result = FCM.send_data("token", %{number: 42, boolean: true, string: "text"})

      assert {:ok, %Response{status: :sent}} = result
    end

    test "maps FCM error responses like the notification path", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
          ~s({"error": {"status": "UNREGISTERED", "message": "Token not registered"}})
        )
      end)

      assert {:error, %Response{status: :unregistered, reason: "Token not registered"}} =
               FCM.send_data("dead-token", %{action: "sync"})
    end

    test "returns connection_error when the server is down", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, %Response{status: :connection_error, provider: :fcm}} =
               FCM.send_data("token", %{action: "sync"})
    end

    test "returns connection_error when the OAuth token cannot be fetched" do
      Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch_error, []})

      on_exit(fn ->
        Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})
      end)

      assert {:error, %Response{status: :connection_error, reason: reason}} =
               FCM.send_data_once("token", %{action: "sync"})

      assert reason =~ "OAuth token error"
    end

    test "rejects oversized data payloads locally" do
      assert {:error, %Response{status: :payload_too_large}} =
               FCM.send_data_once("token", %{blob: String.duplicate("x", 5_000)})
    end

    test "emits a telemetry exception event and re-raises when the request itself raises" do
      Application.put_env(:pushx, :fcm_url_override, "bogus://nowhere")

      test_pid = self()
      handler = "fcm-data-exception-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:pushx, :push, :exception],
        fn event, _measurements, metadata, _ -> send(test_pid, {event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert_raise ArgumentError, fn -> FCM.send_data_once("token", %{a: 1}) end

      assert_receive {[:pushx, :push, :exception], %{provider: :fcm, kind: :error}}
    end
  end

  describe "FCM not configured" do
    # Without the test fetcher seam the real Goth.fetch/1 runs; with no Goth
    # process (FCM unconfigured) it exits the caller with :noproc. The
    # documented contract is {:error, %Response{}} — never an exit.
    setup do
      Application.put_env(:pushx, :fcm_token_fetcher, nil)
      Application.put_env(:pushx, :retry_enabled, false)
      # Hermetic: "not configured" means no credentials either.
      original_creds = Application.get_env(:pushx, :fcm_credentials)
      Application.delete_env(:pushx, :fcm_credentials)

      on_exit(fn ->
        Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})
        Application.delete_env(:pushx, :retry_enabled)

        if original_creds,
          do: Application.put_env(:pushx, :fcm_credentials, original_creds),
          else: Application.delete_env(:pushx, :fcm_credentials)
      end)

      :ok
    end

    test "send/3, send_data/3 and PushX.push/4 return a non-retryable :not_configured" do
      for result <- [
            FCM.send("token", %{"title" => "Hi", "body" => "There"}),
            FCM.send_data("token", %{action: "sync"}),
            PushX.push(:fcm, "token", "Hi")
          ] do
        assert {:error, %Response{status: :not_configured, provider: :fcm, reason: reason} = resp} =
                 result

        assert reason =~ "FCM is not configured"
        refute Response.retryable?(resp)
      end
    end

    test "a missing :fcm_project_id is :not_configured before any token is fetched" do
      original = Application.get_env(:pushx, :fcm_project_id)
      Application.delete_env(:pushx, :fcm_project_id)
      on_exit(fn -> Application.put_env(:pushx, :fcm_project_id, original) end)

      assert {:error, %Response{status: :not_configured, reason: reason}} =
               FCM.send_once("token", %{"title" => "Hi", "body" => "There"})

      assert reason =~ ":fcm_project_id"

      # An explicit :project_id on the call still needs a token source, which
      # is absent here, so it fails on the OAuth step instead.
      assert {:error, %Response{status: :not_configured, reason: reason}} =
               FCM.send_once("token", %{"title" => "Hi", "body" => "There"}, project_id: "p")

      assert reason =~ "OAuth process"
    end

    test "fetch_access_token/2 reports a missing OAuth process as an error tuple" do
      assert {:error, {:oauth_not_running, PushX.Goth}} = FCM.fetch_access_token(PushX.Goth, nil)

      # Static Goth missing with no credentials configured → misconfiguration.
      assert {:error, %Response{status: :not_configured}} =
               FCM.oauth_error_response({:oauth_not_running, PushX.Goth})

      # Static Goth missing but credentials ARE configured → it crashed or is
      # restarting: transient, retryable, must not be reported as config.
      Application.put_env(:pushx, :fcm_credentials, %{"type" => "service_account"})
      on_exit(fn -> Application.delete_env(:pushx, :fcm_credentials) end)

      assert {:error, %Response{status: :connection_error, reason: reason}} =
               FCM.oauth_error_response({:oauth_not_running, PushX.Goth})

      assert reason =~ "restarting"

      assert {:error, %Response{status: :connection_error, reason: reason}} =
               FCM.oauth_error_response(%RuntimeError{message: "token endpoint 503"})

      assert reason =~ "OAuth token error"
    end

    test "a caller-supplied fetcher is guarded: raise/exit/{:error,_} → connection_error, bad shape → auth_error" do
      raising = {PushX.FCMTest.Fetchers, :raise_it, []}
      exiting = {PushX.FCMTest.Fetchers, :exit_it, []}
      erroring = {PushX.FCMTest.Fetchers, :error_it, []}
      wrong_shape = {PushX.FCMTest.Fetchers, :wrong_shape, []}
      with_arg = {PushX.FCMTest.Fetchers, :with_arg, ["extra"]}

      for fetcher <- [raising, exiting, erroring] do
        assert {:error, reason} = FCM.fetch_access_token(PushX.Goth, fetcher)
        assert {:error, %Response{status: :connection_error}} = FCM.oauth_error_response(reason)
      end

      assert {:error, {:bad_fetcher_return, {:ok, "bare"}} = reason} =
               FCM.fetch_access_token(PushX.Goth, wrong_shape)

      assert {:error, %Response{status: :auth_error}} = FCM.oauth_error_response(reason)

      # goth_name is prepended to args, per the documented contract.
      assert {:ok, "Elixir.PushX.Goth-extra"} = FCM.fetch_access_token(PushX.Goth, with_arg)
    end
  end

  describe "client-side rate limit gate" do
    setup do
      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_fcm, 1)
      Application.put_env(:pushx, :rate_limit_window_ms, 60_000)
      PushX.RateLimiter.reset(:fcm)

      on_exit(fn ->
        Application.delete_env(:pushx, :rate_limit_enabled)
        Application.delete_env(:pushx, :rate_limit_fcm)
        Application.delete_env(:pushx, :rate_limit_window_ms)
        PushX.RateLimiter.reset(:fcm)
      end)

      :ok
    end

    test "send_once/3 and send_data_once/3 are gated once the budget is spent" do
      # Spend the single slot without touching the network.
      assert PushX.RateLimiter.check_and_increment(:fcm) == :ok

      assert {:error, %Response{status: :rate_limited, provider: :fcm}} =
               FCM.send_once("token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :rate_limited, provider: :fcm}} =
               FCM.send_data_once("token", %{action: "sync"})
    end
  end

  describe "build_message/3 with Message delivery fields" do
    test "Message priority/ttl/collapse_key land in the android block" do
      message =
        PushX.Message.new("Title", "Body")
        |> PushX.Message.priority(:normal)
        |> PushX.Message.ttl(3600)
        |> PushX.Message.collapse_key("updates")

      %{"message" => built} = FCM.build_message("tok", message, [])

      assert built["android"] == %{
               "priority" => "NORMAL",
               "ttl" => "3600s",
               "collapse_key" => "updates"
             }
    end

    test "opts android keys win over Message-derived keys" do
      message = PushX.Message.new("Title", "Body") |> PushX.Message.priority(:normal)

      %{"message" => built} =
        FCM.build_message("tok", message, android: %{"priority" => "HIGH"})

      assert built["android"]["priority"] == "HIGH"
    end

    test "Message iOS fields become an apns override, deep-merged under explicit :apns opts" do
      message =
        PushX.Message.new("Title", "Body")
        |> PushX.Message.mutable_content()
        |> PushX.Message.subtitle("Sub")

      %{"message" => built} = FCM.build_message("tok", message, [])

      assert built["apns"] == %{
               "payload" => %{
                 "aps" => %{"mutable-content" => 1, "alert" => %{"subtitle" => "Sub"}}
               }
             }

      # Explicit headers are kept alongside the derived payload; explicit
      # payload keys win over derived ones.
      %{"message" => built} =
        FCM.build_message("tok", message,
          apns: %{
            "headers" => %{"apns-priority" => "5"},
            "payload" => %{"aps" => %{"mutable-content" => 0}}
          }
        )

      assert built["apns"] == %{
               "headers" => %{"apns-priority" => "5"},
               "payload" => %{
                 "aps" => %{"mutable-content" => 0, "alert" => %{"subtitle" => "Sub"}}
               }
             }

      # Localization lands under android.notification and merges with :android opts.
      %{"message" => built} =
        FCM.build_message("tok", PushX.Message.new("T", "B") |> PushX.Message.localized_body("K"),
          android: %{"notification" => %{"channel_id" => "orders"}, "priority" => "HIGH"}
        )

      assert built["android"] == %{
               "priority" => "HIGH",
               "notification" => %{"body_loc_key" => "K", "channel_id" => "orders"}
             }
    end

    test "no android block when nothing is set" do
      %{"message" => built} = FCM.build_message("tok", PushX.Message.new("T", "B"), [])
      refute Map.has_key?(built, "android")
    end
  end
end
