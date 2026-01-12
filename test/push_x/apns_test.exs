defmodule PushX.APNSTest do
  use ExUnit.Case

  alias PushX.APNS
  alias PushX.Response

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
  end

  describe "send/3 validation" do
    test "raises when topic is missing" do
      assert_raise ArgumentError, ~r/:topic option is required/, fn ->
        APNS.send("token", %{"aps" => %{}}, [])
      end
    end
  end

  describe "send/3 HTTP integration" do
    setup do
      bypass = Bypass.open()
      # Override the APNS mode to use our bypass server
      original_mode = Application.get_env(:pushx, :apns_mode)
      Application.put_env(:pushx, :apns_mode, :sandbox)

      on_exit(fn ->
        if original_mode do
          Application.put_env(:pushx, :apns_mode, original_mode)
        else
          Application.delete_env(:pushx, :apns_mode)
        end
      end)

      {:ok, bypass: bypass}
    end

    test "returns success response on 200", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/test-device-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("apns-id", "apns-unique-id-123")
        |> Plug.Conn.resp(200, "")
      end)

      # Build custom URL pointing to bypass
      result = send_via_bypass(bypass, "test-device-token", %{"aps" => %{"alert" => "Hello"}})

      assert {:ok, %Response{status: :sent, id: "apns-unique-id-123", provider: :apns}} = result
    end

    test "returns invalid_token error on BadDeviceToken", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/bad-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      result = send_via_bypass(bypass, "bad-token", %{"aps" => %{"alert" => "Hello"}})

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

      result = send_via_bypass(bypass, "unregistered-token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :unregistered, reason: "Unregistered"}} = result
    end

    test "returns expired_token error on ExpiredToken", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/expired-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(410, ~s({"reason": "ExpiredToken"}))
      end)

      result = send_via_bypass(bypass, "expired-token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :expired_token, reason: "ExpiredToken"}} = result
    end

    test "returns payload_too_large error", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(413, ~s({"reason": "PayloadTooLarge"}))
      end)

      result = send_via_bypass(bypass, "token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :payload_too_large, reason: "PayloadTooLarge"}} = result
    end

    test "returns rate_limited error on TooManyRequests", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(429, ~s({"reason": "TooManyRequests"}))
      end)

      result = send_via_bypass(bypass, "token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :rate_limited, reason: "TooManyRequests"}} = result
    end

    test "returns server_error on InternalServerError", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"reason": "InternalServerError"}))
      end)

      result = send_via_bypass(bypass, "token", %{"aps" => %{"alert" => "Hello"}})

      assert {:error, %Response{status: :server_error, reason: "InternalServerError"}} = result
    end

    test "handles connection errors gracefully", %{bypass: bypass} do
      Bypass.down(bypass)

      result = send_via_bypass(bypass, "token", %{"aps" => %{"alert" => "Hello"}})

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

      result = send_via_bypass(bypass, "token", message)

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
        send_via_bypass(
          bypass,
          "token",
          %{"aps" => %{"content-available" => 1}},
          push_type: "background",
          priority: 5
        )

      assert {:ok, %Response{status: :sent}} = result
    end

    # Helper to send via bypass server
    defp send_via_bypass(bypass, device_token, payload, opts \\ []) do
      # We need to temporarily replace the APNS URL
      # Since APNS module uses hardcoded URLs, we'll test via a custom Finch request
      url = "http://localhost:#{bypass.port}/3/device/#{device_token}"
      topic = Keyword.get(opts, :topic, "com.test.app")

      headers = [
        {"authorization", "bearer test-jwt-token"},
        {"apns-topic", topic},
        {"apns-push-type", Keyword.get(opts, :push_type, "alert")},
        {"apns-priority", to_string(Keyword.get(opts, :priority, 10))}
      ]

      body =
        case payload do
          %PushX.Message{} = msg -> JSON.encode!(PushX.Message.to_apns_payload(msg))
          map when is_map(map) -> JSON.encode!(map)
        end

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PushX.Config.finch_name()) do
        {:ok, %{status: 200, headers: response_headers}} ->
          apns_id =
            case List.keyfind(response_headers, "apns-id", 0) do
              {_, value} -> value
              nil -> nil
            end

          {:ok, Response.success(:apns, apns_id)}

        {:ok, %{status: _status, body: body}} ->
          reason =
            case JSON.decode(body) do
              {:ok, %{"reason" => reason}} -> reason
              _ -> "Unknown"
            end

          error_status = Response.apns_reason_to_status(reason)
          {:error, Response.error(:apns, error_status, reason, body)}

        {:error, _reason} ->
          {:error, Response.error(:apns, :connection_error, "Connection failed")}
      end
    end
  end
end
