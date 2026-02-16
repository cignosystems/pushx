defmodule PushX.InstanceTest do
  use ExUnit.Case

  alias PushX.Instance
  alias PushX.Response

  defp test_private_key, do: Application.get_env(:pushx, :apns_private_key)

  defp apns_config(overrides \\ []) do
    Keyword.merge(
      [
        key_id: "TEST_KEY_ID",
        team_id: "TEST_TEAM_ID",
        private_key: test_private_key(),
        mode: :sandbox
      ],
      overrides
    )
  end

  # Helper to ensure cleanup after each test
  defp start_and_cleanup(name, provider, config) do
    {:ok, ^name} = Instance.start(name, provider, config)
    on_exit(fn -> Instance.stop(name) end)
    :ok
  end

  describe "start/3" do
    test "starts an APNS instance" do
      assert {:ok, :start_apns} = Instance.start(:start_apns, :apns, apns_config())
      assert {:ok, %{provider: :apns, enabled: true}} = Instance.status(:start_apns)
      Instance.stop(:start_apns)
    end

    test "rejects reserved name :apns" do
      assert {:error, :reserved_name} = Instance.start(:apns, :apns, apns_config())
    end

    test "rejects reserved name :fcm" do
      assert {:error, :reserved_name} =
               Instance.start(:fcm, :fcm, project_id: "proj", credentials: %{})
    end

    test "rejects duplicate name" do
      start_and_cleanup(:dup_test, :apns, apns_config())

      assert {:error, :already_started} = Instance.start(:dup_test, :apns, apns_config())
    end

    test "validates required APNS config" do
      assert {:error, {:missing_config, [:key_id, :team_id, :private_key]}} =
               Instance.start(:bad_apns, :apns, [])
    end

    test "validates partial APNS config" do
      assert {:error, {:missing_config, [:team_id, :private_key]}} =
               Instance.start(:bad_apns2, :apns, key_id: "KEY")
    end

    test "validates required FCM config" do
      assert {:error, {:missing_config, [:project_id, :credentials]}} =
               Instance.start(:bad_fcm, :fcm, [])
    end

    test "validates partial FCM config" do
      assert {:error, {:missing_config, [:credentials]}} =
               Instance.start(:bad_fcm2, :fcm, project_id: "proj")
    end
  end

  describe "stop/1" do
    test "stops a running instance" do
      {:ok, _} = Instance.start(:stop_test, :apns, apns_config())

      assert :ok = Instance.stop(:stop_test)
      assert {:error, :not_found} = Instance.status(:stop_test)
    end

    test "returns error for unknown instance" do
      assert {:error, :not_found} = Instance.stop(:nonexistent)
    end

    test "cleans up ETS row on stop" do
      {:ok, _} = Instance.start(:ets_cleanup, :apns, apns_config())
      assert {:ok, _} = Instance.resolve(:ets_cleanup)

      :ok = Instance.stop(:ets_cleanup)
      assert {:error, :not_found} = Instance.resolve(:ets_cleanup)
    end
  end

  describe "enable/1 and disable/1" do
    setup do
      start_and_cleanup(:toggle_test, :apns, apns_config())
    end

    test "starts enabled by default" do
      assert {:ok, %{enabled: true}} = Instance.status(:toggle_test)
    end

    test "disable sets enabled to false" do
      assert :ok = Instance.disable(:toggle_test)
      assert {:ok, %{enabled: false}} = Instance.status(:toggle_test)
    end

    test "enable re-enables a disabled instance" do
      :ok = Instance.disable(:toggle_test)
      :ok = Instance.enable(:toggle_test)
      assert {:ok, %{enabled: true}} = Instance.status(:toggle_test)
    end

    test "disable returns error for unknown instance" do
      assert {:error, :not_found} = Instance.disable(:nonexistent)
    end

    test "enable returns error for unknown instance" do
      assert {:error, :not_found} = Instance.enable(:nonexistent)
    end
  end

  describe "status/1" do
    test "returns provider and enabled status" do
      start_and_cleanup(:status_test, :apns, apns_config())

      assert {:ok, %{provider: :apns, enabled: true}} = Instance.status(:status_test)
    end

    test "returns error for unknown instance" do
      assert {:error, :not_found} = Instance.status(:nonexistent)
    end
  end

  describe "resolve/1" do
    test "returns full instance info" do
      start_and_cleanup(:resolve_test, :apns, apns_config())

      assert {:ok, info} = Instance.resolve(:resolve_test)
      assert info.provider == :apns
      assert info.enabled == true
      assert info.name == :resolve_test
      assert is_atom(info.finch_name)
    end

    test "returns disabled for disabled instance" do
      start_and_cleanup(:resolve_disabled, :apns, apns_config())
      Instance.disable(:resolve_disabled)

      assert {:error, :disabled} = Instance.resolve(:resolve_disabled)
    end

    test "returns not_found for unknown instance" do
      assert {:error, :not_found} = Instance.resolve(:nonexistent)
    end
  end

  describe "reconfigure/2" do
    test "restarts instance with merged config" do
      {:ok, _} = Instance.start(:reconfig, :apns, apns_config(mode: :prod))
      on_exit(fn -> Instance.stop(:reconfig) end)

      assert {:ok, :reconfig} = Instance.reconfigure(:reconfig, mode: :sandbox)
      assert {:ok, %{provider: :apns, enabled: true}} = Instance.status(:reconfig)
    end

    test "preserves provider across reconfigure" do
      {:ok, _} = Instance.start(:reconfig_prov, :apns, apns_config())
      on_exit(fn -> Instance.stop(:reconfig_prov) end)

      {:ok, _} = Instance.reconfigure(:reconfig_prov, mode: :sandbox)
      {:ok, info} = Instance.resolve(:reconfig_prov)
      assert info.provider == :apns
    end

    test "returns error for unknown instance" do
      assert {:error, :not_found} = Instance.reconfigure(:nonexistent, mode: :sandbox)
    end
  end

  describe "list/0" do
    test "returns all running instances" do
      start_and_cleanup(:list_a, :apns, apns_config())
      start_and_cleanup(:list_b, :apns, apns_config())

      instances = Instance.list()
      names = Enum.map(instances, & &1.name)

      assert :list_a in names
      assert :list_b in names
    end

    test "includes provider and enabled status" do
      start_and_cleanup(:list_info, :apns, apns_config())
      Instance.disable(:list_info)

      entry = Enum.find(Instance.list(), &(&1.name == :list_info))
      assert entry.provider == :apns
      assert entry.enabled == false
    end
  end

  describe "PushX.push/4 with instances" do
    test "returns error for unknown instance" do
      result = PushX.push(:nonexistent_instance, "token", "hello")

      assert {:error, %Response{status: :unknown_error}} = result
      assert {:error, %Response{reason: reason}} = result
      assert reason =~ "nonexistent_instance"
    end

    test "returns error for disabled instance" do
      start_and_cleanup(:push_disabled, :apns, apns_config())
      Instance.disable(:push_disabled)

      result = PushX.push(:push_disabled, "token", "hello", topic: "com.test")

      assert {:error, %Response{status: :provider_disabled}} = result
      assert {:error, %Response{reason: reason}} = result
      assert reason =~ "push_disabled"
    end
  end

  describe "APNS instance Finch pool" do
    setup do
      bypass = Bypass.open()
      start_and_cleanup(:apns_pool, :apns, apns_config())
      {:ok, bypass: bypass}
    end

    test "creates a working Finch pool", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/test-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("apns-id", "instance-apns-id")
        |> Plug.Conn.resp(200, "")
      end)

      {:ok, info} = Instance.resolve(:apns_pool)

      url = "http://localhost:#{bypass.port}/3/device/test-token"

      headers = [
        {"authorization", "bearer test-token"},
        {"apns-topic", "com.test.app"},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]

      body = JSON.encode!(%{"aps" => %{"alert" => "Hello"}})

      result =
        Finch.build(:post, url, headers, body)
        |> Finch.request(info.finch_name)

      assert {:ok, %{status: 200}} = result
    end

    test "handles error responses via Finch pool", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/bad-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      {:ok, info} = Instance.resolve(:apns_pool)

      url = "http://localhost:#{bypass.port}/3/device/bad-token"

      headers = [
        {"authorization", "bearer test-token"},
        {"apns-topic", "com.test.app"},
        {"apns-push-type", "alert"},
        {"apns-priority", "10"}
      ]

      body = JSON.encode!(%{"aps" => %{"alert" => "Hello"}})

      result =
        Finch.build(:post, url, headers, body)
        |> Finch.request(info.finch_name)

      assert {:ok, %{status: 400, body: resp_body}} = result
      assert %{"reason" => "BadDeviceToken"} = JSON.decode!(resp_body)
    end

    test "handles connection errors via Finch pool", %{bypass: bypass} do
      Bypass.down(bypass)

      {:ok, info} = Instance.resolve(:apns_pool)

      url = "http://localhost:#{bypass.port}/3/device/token"

      headers = [
        {"authorization", "bearer test-token"},
        {"apns-topic", "com.test.app"}
      ]

      body = JSON.encode!(%{"aps" => %{"alert" => "Hello"}})

      result =
        Finch.build(:post, url, headers, body)
        |> Finch.request(info.finch_name)

      assert {:error, _reason} = result
    end
  end

  describe "concurrent instances" do
    test "multiple APNS instances can run simultaneously" do
      start_and_cleanup(:apns_sandbox, :apns, apns_config(mode: :sandbox))
      start_and_cleanup(:apns_prod, :apns, apns_config(mode: :prod))

      assert {:ok, sandbox} = Instance.resolve(:apns_sandbox)
      assert {:ok, prod} = Instance.resolve(:apns_prod)

      # Each instance has its own Finch pool
      assert sandbox.finch_name != prod.finch_name
      assert sandbox.finch_name == :"PushX.Finch.apns_sandbox"
      assert prod.finch_name == :"PushX.Finch.apns_prod"
    end

    test "stopping one instance doesn't affect others" do
      start_and_cleanup(:concurrent_a, :apns, apns_config())
      start_and_cleanup(:concurrent_b, :apns, apns_config())

      # Manually stop one (bypass on_exit cleanup)
      :ok = Instance.stop(:concurrent_a)

      # Other instance still works
      assert {:ok, _} = Instance.resolve(:concurrent_b)
      assert {:error, :not_found} = Instance.resolve(:concurrent_a)
    end

    test "disabling one instance doesn't affect others" do
      start_and_cleanup(:disable_a, :apns, apns_config())
      start_and_cleanup(:disable_b, :apns, apns_config())

      Instance.disable(:disable_a)

      assert {:error, :disabled} = Instance.resolve(:disable_a)
      assert {:ok, _} = Instance.resolve(:disable_b)
    end
  end

  describe "reconnect/1" do
    test "restarts instance Finch pool" do
      start_and_cleanup(:reconnect_test, :apns, apns_config())

      {:ok, info} = Instance.resolve(:reconnect_test)
      old_pid = Process.whereis(info.finch_name)
      assert old_pid != nil

      assert :ok = Instance.reconnect(:reconnect_test)

      new_pid = Process.whereis(info.finch_name)
      assert new_pid != nil
      assert new_pid != old_pid
    end

    test "returns error for unknown instance" do
      assert {:error, :not_found} = Instance.reconnect(:nonexistent)
    end
  end
end
