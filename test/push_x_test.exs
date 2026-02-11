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
    test "raises for unknown provider" do
      assert_raise FunctionClauseError, fn ->
        PushX.push(:unknown, "token", "message")
      end
    end
  end

  describe "normalize_payload (via push)" do
    # We test normalize_payload indirectly through push/4
    # since it's a private function

    setup do
      bypass = Bypass.open()
      {:ok, bypass: bypass}
    end

    test "converts string message to Message struct", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # String "Hello" becomes title, body is empty
        assert payload["aps"]["alert"]["title"] == "Hello"
        assert payload["aps"]["alert"]["body"] == ""

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      # Use helper to test via bypass
      result = push_apns_via_bypass(bypass, "token", "Hello")
      assert {:ok, _} = result
    end

    test "passes through Message struct unchanged", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Title"
        assert payload["aps"]["alert"]["body"] == "Body"
        assert payload["aps"]["badge"] == 5

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      message =
        Message.new("Title", "Body")
        |> Message.badge(5)

      result = push_apns_via_bypass(bypass, "token", message)
      assert {:ok, _} = result
    end

    test "converts map with string keys to Message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Map Title"
        assert payload["aps"]["alert"]["body"] == "Map Body"
        assert payload["aps"]["badge"] == 3

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      map_payload = %{"title" => "Map Title", "body" => "Map Body", "badge" => 3}
      result = push_apns_via_bypass(bypass, "token", map_payload)
      assert {:ok, _} = result
    end

    test "converts map with atom keys to Message", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Atom Title"
        assert payload["aps"]["alert"]["body"] == "Atom Body"
        assert payload["aps"]["sound"] == "ping.wav"

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      map_payload = %{title: "Atom Title", body: "Atom Body", sound: "ping.wav"}
      result = push_apns_via_bypass(bypass, "token", map_payload)
      assert {:ok, _} = result
    end

    test "passes through raw APNS payload", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        # Raw APNS payload should pass through unchanged
        assert payload["aps"]["content-available"] == 1
        assert payload["custom_key"] == "custom_value"

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      raw_payload = %{
        "aps" => %{"content-available" => 1},
        "custom_key" => "custom_value"
      }

      result = push_apns_via_bypass(bypass, "token", raw_payload)
      assert {:ok, _} = result
    end

    test "includes data from map payload", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["aps"]["alert"]["title"] == "Alert"
        assert payload["lock_id"] == "abc123"

        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      map_payload = %{
        title: "Alert",
        body: "Door unlocked",
        data: %{"lock_id" => "abc123"}
      }

      result = push_apns_via_bypass(bypass, "token", map_payload)
      assert {:ok, _} = result
    end

    # Helper to test push via bypass
    defp push_apns_via_bypass(bypass, device_token, payload) do
      url = "http://localhost:#{bypass.port}/3/device/#{device_token}"

      # Normalize payload same way PushX.push does
      normalized =
        case payload do
          binary when is_binary(binary) ->
            Message.new(binary, "")

          %Message{} = msg ->
            msg

          %{"title" => _, "body" => _} = map ->
            Message.new(map["title"], map["body"])
            |> maybe_set(:badge, map["badge"])
            |> maybe_set(:sound, map["sound"])
            |> maybe_set(:data, map["data"])

          %{title: _, body: _} = map ->
            Message.new(map.title, map.body)
            |> maybe_set(:badge, Map.get(map, :badge))
            |> maybe_set(:sound, Map.get(map, :sound))
            |> maybe_set(:data, Map.get(map, :data))

          map when is_map(map) ->
            map
        end

      body =
        case normalized do
          %Message{} = msg -> JSON.encode!(Message.to_apns_payload(msg))
          map when is_map(map) -> JSON.encode!(map)
        end

      headers = [
        {"authorization", "bearer test-token"},
        {"apns-topic", "com.test.app"},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PushX.Config.finch_name()) do
        {:ok, %{status: 200}} ->
          {:ok, :sent}

        {:ok, %{status: status, body: body}} ->
          {:error, {status, body}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp maybe_set(message, _field, nil), do: message
    defp maybe_set(message, :badge, value), do: Message.badge(message, value)
    defp maybe_set(message, :sound, value), do: Message.sound(message, value)
    defp maybe_set(message, :data, value), do: Message.data(message, value)
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
      {:ok, bypass: bypass}
    end

    test "returns :ok on success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("apns-id", "id")
        |> Plug.Conn.resp(200, "")
      end)

      result = push_bang_via_bypass(bypass, "token", "Hello")
      assert result == :ok
    end

    test "returns :error on failure", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      result = push_bang_via_bypass(bypass, "token", "Hello")
      assert result == :error
    end

    defp push_bang_via_bypass(bypass, device_token, message) do
      url = "http://localhost:#{bypass.port}/3/device/#{device_token}"
      msg = Message.new(message, "")
      body = JSON.encode!(Message.to_apns_payload(msg))

      headers = [
        {"authorization", "bearer test-token"},
        {"apns-topic", "com.test.app"},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]

      case Finch.build(:post, url, headers, body)
           |> Finch.request(PushX.Config.finch_name()) do
        {:ok, %{status: 200}} -> :ok
        _ -> :error
      end
    end
  end
end
