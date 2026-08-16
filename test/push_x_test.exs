defmodule PushXTest do
  use ExUnit.Case
  doctest PushX

  alias PushX.Message

  describe "message/0" do
    test "creates an empty message" do
      message = PushX.message()
      assert %Message{} = message
      assert message.title == nil
      assert message.body == nil
    end
  end

  describe "message/2" do
    test "creates a message with title and body" do
      message = PushX.message("Hello", "World")
      assert message.title == "Hello"
      assert message.body == "World"
    end
  end

  describe "push/4 argument validation" do
    test "returns error for unknown instance name" do
      assert {:error, %PushX.Response{status: :unknown_error}} =
               PushX.push(:unknown, "token", "message")
    end
  end

  # Receives :on_invalid_token callbacks so tests can assert they fired.
  defmodule TokenSink do
    def invalid(provider, token, pid), do: send(pid, {:invalid_token, provider, token})
  end

  # Points the real APNS/FCM send paths at a Bypass server (test-only URL
  # overrides), stubs OAuth via :fcm_token_fetcher (test_helper.exs), and
  # disables retries so retryable failures return immediately.
  defp route_to_bypass(bypass) do
    Application.put_env(:pushx, :apns_url_override, "http://localhost:#{bypass.port}")
    Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
    Application.put_env(:pushx, :retry_enabled, false)
    PushX.JWTCache.invalidate(:apns_jwt)

    on_exit(fn ->
      Application.delete_env(:pushx, :apns_url_override)
      Application.delete_env(:pushx, :fcm_url_override)
      Application.delete_env(:pushx, :retry_enabled)
      PushX.JWTCache.invalidate(:apns_jwt)
    end)
  end

  defp apns_ok(conn, id \\ "id") do
    conn
    |> Plug.Conn.put_resp_header("apns-id", id)
    |> Plug.Conn.resp(200, "")
  end

  defp apns_error(conn, status, reason) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, ~s({"reason": "#{reason}"}))
  end

  describe "normalize_payload (via push)" do
    # normalize_payload/2 is private, so it is exercised through the real
    # PushX.push/4 → PushX.APNS.send/3 path and asserted on the wire.

    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      {:ok, bypass: bypass}
    end

    test "converts string message to Message struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # String "Hello" becomes title, body is empty
        assert payload["aps"]["alert"]["title"] == "Hello"
        assert payload["aps"]["alert"]["body"] == ""

        apns_ok(conn)
      end)

      assert {:ok, %PushX.Response{status: :sent, id: "id"}} =
               PushX.push(:apns, "token", "Hello", topic: "com.test.app")
    end

    test "passes through Message struct unchanged", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Title"
        assert payload["aps"]["alert"]["body"] == "Body"
        assert payload["aps"]["badge"] == 5

        apns_ok(conn)
      end)

      message = Message.new("Title", "Body") |> Message.badge(5)

      assert {:ok, _} = PushX.push(:apns, "token", message, topic: "com.test.app")
    end

    test "converts map with string keys to Message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Map Title"
        assert payload["aps"]["alert"]["body"] == "Map Body"
        assert payload["aps"]["badge"] == 3

        apns_ok(conn)
      end)

      map_payload = %{"title" => "Map Title", "body" => "Map Body", "badge" => 3}

      assert {:ok, _} = PushX.push(:apns, "token", map_payload, topic: "com.test.app")
    end

    test "converts map with atom keys to Message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Atom Title"
        assert payload["aps"]["alert"]["body"] == "Atom Body"
        assert payload["aps"]["sound"] == "ping.wav"

        apns_ok(conn)
      end)

      map_payload = %{title: "Atom Title", body: "Atom Body", sound: "ping.wav"}

      assert {:ok, _} = PushX.push(:apns, "token", map_payload, topic: "com.test.app")
    end

    test "passes through raw APNS payload", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Raw APNS payload should pass through unchanged
        assert payload["aps"]["content-available"] == 1
        assert payload["custom_key"] == "custom_value"

        apns_ok(conn)
      end)

      raw_payload = %{
        "aps" => %{"content-available" => 1},
        "custom_key" => "custom_value"
      }

      assert {:ok, _} = PushX.push(:apns, "token", raw_payload, topic: "com.test.app")
    end

    test "includes data from map payload", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Alert"
        assert payload["lock_id"] == "abc123"

        apns_ok(conn)
      end)

      map_payload = %{
        title: "Alert",
        body: "Door unlocked",
        data: %{"lock_id" => "abc123"}
      }

      assert {:ok, _} = PushX.push(:apns, "token", map_payload, topic: "com.test.app")
    end

    test "routes :fcm to PushX.FCM.send/3", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["token"] == "fcm-token"
        assert payload["message"]["notification"]["title"] == "Hello"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "fcm-msg"}))
      end)

      assert {:ok, %PushX.Response{status: :sent, id: "fcm-msg", provider: :fcm}} =
               PushX.push(:fcm, "fcm-token", "Hello")
    end
  end

  describe ":on_invalid_token callback" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)

      Application.put_env(:pushx, :on_invalid_token, {TokenSink, :invalid, [self()]})
      on_exit(fn -> Application.delete_env(:pushx, :on_invalid_token) end)

      {:ok, bypass: bypass}
    end

    test "fires with provider and token when APNS reports the token as dead", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/dead-token", fn conn ->
        apns_error(conn, 410, "Unregistered")
      end)

      assert {:error, %PushX.Response{status: :unregistered}} =
               PushX.push(:apns, "dead-token", "Hello", topic: "com.test.app")

      assert_receive {:invalid_token, :apns, "dead-token"}
    end

    test "fires for FCM push_data/4 too", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, ~s({"error": {"status": "UNREGISTERED", "message": "gone"}}))
      end)

      assert {:error, %PushX.Response{status: :unregistered}} =
               PushX.push_data(:fcm, "dead-fcm-token", %{action: "sync"})

      assert_receive {:invalid_token, :fcm, "dead-fcm-token"}
    end

    test "does not fire for failures that are not token problems", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        apns_error(conn, 500, "InternalServerError")
      end)

      assert {:error, %PushX.Response{status: :server_error}} =
               PushX.push(:apns, "token", "Hello", topic: "com.test.app")

      refute_receive {:invalid_token, _, _}, 100
    end
  end

  describe "push_data/4" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      {:ok, bypass: bypass}
    end

    test "sends a data-only FCM message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/test-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["data"] == %{"action" => "sync"}
        refute Map.has_key?(payload["message"], "notification")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"name": "data-msg"}))
      end)

      assert {:ok, %PushX.Response{status: :sent, id: "data-msg"}} =
               PushX.push_data(:fcm, "token", %{action: "sync"})
    end

    test "returns clear error for :apns provider" do
      result = PushX.push_data(:apns, "token", %{action: "sync"})

      assert {:error, %PushX.Response{status: :invalid_request, provider: :apns}} = result
      assert {:error, %PushX.Response{reason: reason}} = result
      assert reason =~ "only supported for FCM"
    end

    test "returns error for unknown instance" do
      result = PushX.push_data(:nonexistent_instance, "token", %{action: "sync"})

      assert {:error, %PushX.Response{status: :unknown_error}} = result
      assert {:error, %PushX.Response{reason: reason}} = result
      assert reason =~ "nonexistent_instance"
    end

    test "returns error for disabled instance" do
      {:ok, _} =
        PushX.Instance.start(:push_data_disabled, :apns,
          key_id: "KEY",
          team_id: "TEAM",
          private_key: Application.get_env(:pushx, :apns_private_key),
          mode: :sandbox
        )

      on_exit(fn -> PushX.Instance.stop(:push_data_disabled) end)
      PushX.Instance.disable(:push_data_disabled)

      result = PushX.push_data(:push_data_disabled, "token", %{action: "sync"})

      assert {:error, %PushX.Response{status: :provider_disabled}} = result
    end

    test "rejects APNS named instance with clear error" do
      {:ok, _} =
        PushX.Instance.start(:push_data_apns, :apns,
          key_id: "KEY",
          team_id: "TEAM",
          private_key: Application.get_env(:pushx, :apns_private_key),
          mode: :sandbox
        )

      on_exit(fn -> PushX.Instance.stop(:push_data_apns) end)

      result = PushX.push_data(:push_data_apns, "token", %{action: "sync"})

      assert {:error, %PushX.Response{status: :invalid_request, provider: :apns}} = result
      assert {:error, %PushX.Response{reason: reason}} = result
      assert reason =~ "only supported for FCM"
    end
  end

  describe "reconnect/0" do
    test "restarts Finch pool and returns :ok" do
      # Finch should be running
      assert Process.whereis(PushX.Config.finch_name()) != nil

      old_pid = Process.whereis(PushX.Config.finch_name())
      assert :ok = PushX.reconnect()

      # Finch should be running again with a new pid
      new_pid = Process.whereis(PushX.Config.finch_name())
      assert new_pid != nil
      assert new_pid != old_pid
    end

    test "is safe to call concurrently" do
      tasks =
        for _ <- 1..5 do
          Task.async(fn -> PushX.reconnect() end)
        end

      results = Task.await_many(tasks, 5000)
      assert Enum.all?(results, &(&1 == :ok))

      # Finch should still be running after concurrent reconnects
      assert Process.whereis(PushX.Config.finch_name()) != nil
    end
  end

  describe "push!/4" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      {:ok, bypass: bypass}
    end

    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn -> apns_ok(conn) end)

      assert :ok = PushX.push!(:apns, "token", "Hello", topic: "com.test.app")
    end

    test "returns :error on failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        apns_error(conn, 400, "BadDeviceToken")
      end)

      assert :error = PushX.push!(:apns, "token", "Hello", topic: "com.test.app")
    end

    test "push!/3 defaults opts (and therefore fails APNS topic validation locally)" do
      assert :error = PushX.push!(:apns, "token", "Hello")
    end
  end

  describe "health_check/0" do
    test "reports configuration and breaker state per provider" do
      assert %{
               apns: %{configured: true, circuit: apns_state},
               fcm: %{configured: fcm_configured, circuit: fcm_state}
             } = PushX.health_check()

      assert apns_state in [:closed, :open, :half_open]
      assert fcm_state in [:closed, :open, :half_open]
      # test_helper.exs sets fcm_project_id but no fcm_credentials.
      assert fcm_configured == PushX.Config.fcm_configured?()
    end
  end
end
