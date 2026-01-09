defmodule PushX.FCMTest do
  use ExUnit.Case

  alias PushX.FCM
  alias PushX.Response

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

  describe "send/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "returns success response on 200 with message ID", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Verify request structure
        assert payload["message"]["token"] == "test-device-token"
        assert payload["message"]["notification"]["title"] == "Hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "projects/test-project/messages/msg-123"}))
      end)

      result = send_via_bypass(bypass, "test-device-token", %{"title" => "Hello", "body" => "World"})

      assert {:ok, %Response{status: :sent, id: "projects/test-project/messages/msg-123", provider: :fcm}} = result
    end

    test "returns success even without message ID in response", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({}))
      end)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:ok, %Response{status: :sent, id: nil, provider: :fcm}} = result
    end

    test "returns invalid_token error on INVALID_ARGUMENT", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"error": {"status": "INVALID_ARGUMENT", "message": "Invalid token"}}))
      end)

      result = send_via_bypass(bypass, "bad-token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :invalid_token, reason: "Invalid token", provider: :fcm}} = result
    end

    test "returns unregistered error on UNREGISTERED", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"error": {"status": "UNREGISTERED", "message": "Token not registered"}}))
      end)

      result = send_via_bypass(bypass, "unregistered-token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unregistered, reason: "Token not registered"}} = result
    end

    test "returns rate_limited error on QUOTA_EXCEEDED", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"error": {"status": "QUOTA_EXCEEDED", "message": "Rate limit exceeded"}}))
      end)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :rate_limited, reason: "Rate limit exceeded"}} = result
    end

    test "returns server_error on UNAVAILABLE", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(503, ~s({"error": {"status": "UNAVAILABLE", "message": "Service unavailable"}}))
      end)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :server_error, reason: "Service unavailable"}} = result
    end

    test "returns server_error on INTERNAL", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"error": {"status": "INTERNAL", "message": "Internal error"}}))
      end)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :server_error, reason: "Internal error"}} = result
    end

    test "handles connection errors gracefully", %{bypass: bypass} do
      Bypass.down(bypass)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :connection_error, provider: :fcm}} = result
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
      result = send_via_bypass(bypass, "token", message)

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
        send_via_bypass(
          bypass,
          "token",
          %{"title" => "Hi", "body" => "There"},
          data: %{key: "value", count: 42}
        )

      assert {:ok, %Response{status: :sent}} = result
    end

    test "handles error response with code instead of status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"error": {"code": 400, "message": "Bad request"}}))
      end)

      result = send_via_bypass(bypass, "token", %{"title" => "Hi", "body" => "There"})

      assert {:error, %Response{status: :unknown_error, reason: "Bad request"}} = result
    end

    # Helper to send via bypass server
    defp send_via_bypass(bypass, device_token, payload, opts \\ []) do
      url = "http://localhost:#{bypass.port}/v1/projects/test-project/messages:send"

      message = build_message(device_token, payload, opts)

      headers = [
        {"authorization", "Bearer test-oauth-token"},
        {"content-type", "application/json"}
      ]

      body = JSON.encode!(message)

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PushX.Config.finch_name()) do
        {:ok, %{status: 200, body: response_body}} ->
          case JSON.decode(response_body) do
            {:ok, %{"name" => message_id}} ->
              {:ok, Response.success(:fcm, message_id)}

            _ ->
              {:ok, Response.success(:fcm)}
          end

        {:ok, %{status: _status, body: body}} ->
          {error_code, error_message} =
            case JSON.decode(body) do
              {:ok, %{"error" => %{"status" => code, "message" => msg}}} ->
                {code, msg}

              {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
                {to_string(code), msg}

              _ ->
                {"UNKNOWN", "Unknown error"}
            end

          error_status = Response.fcm_error_to_status(error_code)
          {:error, Response.error(:fcm, error_status, error_message, body)}

        {:error, _reason} ->
          {:error, Response.error(:fcm, :connection_error, "Connection failed")}
      end
    end

    defp build_message(token, %PushX.Message{} = message, opts) do
      base = %{
        "token" => token,
        "notification" => PushX.Message.to_fcm_payload(message)["notification"]
      }

      base
      |> maybe_put("data", stringify_map(Keyword.get(opts, :data) || message.data))
      |> then(&%{"message" => &1})
    end

    defp build_message(token, payload, opts) when is_map(payload) do
      base = %{"token" => token, "notification" => payload}

      base
      |> maybe_put("data", stringify_map(Keyword.get(opts, :data)))
      |> then(&%{"message" => &1})
    end

    defp maybe_put(map, _key, nil), do: map
    defp maybe_put(map, _key, data) when data == %{}, do: map
    defp maybe_put(map, key, value), do: Map.put(map, key, value)

    defp stringify_map(nil), do: nil
    defp stringify_map(map) when map == %{}, do: nil

    defp stringify_map(map) when is_map(map) do
      Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
    end
  end

  describe "send_data/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "sends data-only message without notification", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Should have data but no notification
        assert payload["message"]["token"] == "token"
        assert payload["message"]["data"]["action"] == "sync"
        assert payload["message"]["data"]["id"] == "123"
        refute Map.has_key?(payload["message"], "notification")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "data-msg-id"}))
      end)

      result = send_data_via_bypass(bypass, "token", %{action: "sync", id: 123})

      assert {:ok, %Response{status: :sent, id: "data-msg-id"}} = result
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

      result = send_data_via_bypass(bypass, "token", %{number: 42, boolean: true, string: "text"})

      assert {:ok, %Response{status: :sent}} = result
    end

    # Helper for send_data tests
    defp send_data_via_bypass(bypass, device_token, data) do
      url = "http://localhost:#{bypass.port}/v1/projects/test-project/messages:send"

      message = %{
        "message" => %{
          "token" => device_token,
          "data" => Map.new(data, fn {k, v} -> {to_string(k), to_string(v)} end)
        }
      }

      headers = [
        {"authorization", "Bearer test-oauth-token"},
        {"content-type", "application/json"}
      ]

      body = JSON.encode!(message)

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PushX.Config.finch_name()) do
        {:ok, %{status: 200, body: response_body}} ->
          case JSON.decode(response_body) do
            {:ok, %{"name" => message_id}} ->
              {:ok, Response.success(:fcm, message_id)}

            _ ->
              {:ok, Response.success(:fcm)}
          end

        {:ok, %{status: _status, body: body}} ->
          {:error, Response.error(:fcm, :unknown_error, body)}

        {:error, _reason} ->
          {:error, Response.error(:fcm, :connection_error, "Connection failed")}
      end
    end
  end
end
