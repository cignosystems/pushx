defmodule PushX.InstanceTest do
  use ExUnit.Case

  alias PushX.Instance
  alias PushX.Response

  defp test_private_key, do: Application.get_env(:pushx, :apns_private_key)

  # connect_timeout: 1 — instance pools eagerly dial the real provider hosts;
  # failing that dial instantly keeps teardown fast (finch >= 0.22 waits for
  # an in-flight connect on shutdown). Sends still work: the URL overrides
  # route them through Finch's default HTTP/1 pool to Bypass.
  defp apns_config(overrides \\ []) do
    Keyword.merge(
      [
        key_id: "TEST_KEY_ID",
        team_id: "TEST_TEAM_ID",
        private_key: test_private_key(),
        mode: :sandbox,
        connect_timeout: 1
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

    test "rejects a malformed private key PEM" do
      assert {:error, {:invalid_private_key, _reason}} =
               Instance.start(:bad_pem, :apns, apns_config(private_key: "not a pem"))
    end

    test "rejects a {:file, path} private key whose file is missing" do
      assert {:error, {:invalid_private_key, _reason}} =
               Instance.start(
                 :bad_key_file,
                 :apns,
                 apns_config(private_key: {:file, "/nonexistent/AuthKey.p8"})
               )
    end

    test "rejects a {:system, var} private key whose env var is unset" do
      assert {:error, {:invalid_private_key, _reason}} =
               Instance.start(
                 :bad_key_env,
                 :apns,
                 apns_config(private_key: {:system, "PUSHX_TEST_UNSET_ENV_VAR"})
               )
    end

    test "validates required FCM config" do
      assert {:error, {:missing_config, [:project_id, :credentials]}} =
               Instance.start(:bad_fcm, :fcm, [])
    end

    test "validates partial FCM config" do
      assert {:error, {:missing_config, [:credentials]}} =
               Instance.start(:bad_fcm2, :fcm, project_id: "proj")
    end

    # Goth prefetches eagerly and raises on unusable credentials, which
    # crash-loops up to PushX.Instance.DynamicSupervisor and kills every
    # named instance — so unusable credentials must be rejected *before*
    # anything starts, and start/3 must not report success for them.
    test "rejects FCM credentials without the service-account keys" do
      assert {:error, {:invalid_credentials, reason}} =
               Instance.start(:bad_fcm3, :fcm, project_id: "p", credentials: %{"type" => "x"})

      assert reason =~ ~s(missing "private_key")

      assert {:error, {:invalid_credentials, reason}} =
               Instance.start(:bad_fcm4, :fcm,
                 project_id: "p",
                 credentials: %{"private_key" => PushX.TestCredentials.fcm_private_key_pem()}
               )

      assert reason =~ ~s(missing "client_email")
      refute :bad_fcm3 in Instance.list()
      refute :bad_fcm4 in Instance.list()
    end

    test "rejects FCM credentials whose private key cannot sign RS256" do
      base = PushX.TestCredentials.fcm()

      assert {:error, {:invalid_credentials, "\"private_key\" is not a valid PEM"}} =
               Instance.start(:bad_fcm5, :fcm,
                 project_id: "p",
                 credentials: %{base | "private_key" => "-----BEGIN GARBAGE-----"}
               )

      # A valid PEM of the wrong kind (the P-256 APNS test key) cannot RS256-sign.
      assert {:error, {:invalid_credentials, _reason}} =
               Instance.start(:bad_fcm6, :fcm,
                 project_id: "p",
                 credentials: %{base | "private_key" => test_private_key()}
               )
    end

    test "rejects FCM credentials that are neither a map nor JSON" do
      assert {:error, {:invalid_credentials, reason}} =
               Instance.start(:bad_fcm7, :fcm, project_id: "p", credentials: "not json")

      assert reason =~ "decoded service-account map"

      assert {:error, {:invalid_credentials, _}} =
               Instance.start(:bad_fcm8, :fcm, project_id: "p", credentials: 42)
    end

    test "accepts FCM credentials as a JSON string" do
      json = JSON.encode!(PushX.TestCredentials.fcm())
      start_and_cleanup(:json_creds, :fcm, project_id: "p", credentials: json)
      assert {:ok, %{provider: :fcm}} = Instance.status(:json_creds)
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

    test "rejects a bad private key and leaves the running instance untouched" do
      start_and_cleanup(:reconfig_bad_key, :apns, apns_config())

      assert {:error, {:invalid_private_key, _reason}} =
               Instance.reconfigure(:reconfig_bad_key, private_key: "garbage")

      assert {:ok, %{provider: :apns, enabled: true}} = Instance.status(:reconfig_bad_key)
    end

    test "rejects bad FCM credentials and leaves the running instance untouched" do
      start_and_cleanup(:reconfig_bad_creds, :fcm, fcm_config())

      assert {:error, {:invalid_credentials, _reason}} =
               Instance.reconfigure(:reconfig_bad_creds, credentials: %{"type" => "x"})

      assert {:ok, %{provider: :fcm, enabled: true}} = Instance.status(:reconfig_bad_creds)
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

  # -- Real send paths ------------------------------------------------------
  # These drive PushX.push/4 → Instance.send/4 end-to-end against Bypass via
  # the test-only URL overrides. FCM OAuth is stubbed through
  # :fcm_token_fetcher (test_helper.exs), which also means no Goth process is
  # started for FCM instances in the suite. Retries are disabled so retryable
  # failures return immediately.

  defp route_to_bypass(bypass) do
    Application.put_env(:pushx, :apns_url_override, "http://localhost:#{bypass.port}")
    Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{bypass.port}")
    Application.put_env(:pushx, :retry_enabled, false)

    on_exit(fn ->
      Application.delete_env(:pushx, :apns_url_override)
      Application.delete_env(:pushx, :fcm_url_override)
      Application.delete_env(:pushx, :retry_enabled)
    end)
  end

  # Instances get their *own* token fetcher (the global :fcm_token_fetcher
  # never applies to instances), which also means no Goth is started for them.
  defp fcm_config(overrides \\ []) do
    Keyword.merge(
      [
        project_id: "tenant-project",
        credentials: PushX.TestCredentials.fcm(),
        token_fetcher: {PushX.TestOAuth, :fetch, []},
        connect_timeout: 1
      ],
      overrides
    )
  end

  defp apns_ok(conn, id \\ "instance-apns-id") do
    conn
    |> Plug.Conn.put_resp_header("apns-id", id)
    |> Plug.Conn.resp(200, "")
  end

  defp apns_error(conn, status, reason) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, ~s({"reason": "#{reason}"}))
  end

  defp fcm_ok(conn, name \\ "projects/tenant-project/messages/m-1") do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, ~s({"name": "#{name}"}))
  end

  describe "APNS instance send path" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      start_and_cleanup(:apns_send, :apns, apns_config())
      on_exit(fn -> PushX.JWTCache.invalidate({:apns_jwt, :apns_send}) end)
      {:ok, bypass: bypass}
    end

    test "signs with the instance credentials and returns the apns-id", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/test-token", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body)["aps"]["alert"]["title"] == "Hello"

        ["bearer " <> jwt] = Plug.Conn.get_req_header(conn, "authorization")

        assert Joken.peek_header(jwt) ==
                 {:ok, %{"alg" => "ES256", "kid" => "TEST_KEY_ID", "typ" => "JWT"}}

        assert {:ok, %{"iss" => "TEST_TEAM_ID", "iat" => _}} = Joken.peek_claims(jwt)

        assert Plug.Conn.get_req_header(conn, "apns-topic") == ["com.test.app"]
        assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["alert"]
        assert Plug.Conn.get_req_header(conn, "apns-priority") == ["10"]

        apns_ok(conn)
      end)

      assert {:ok, %Response{status: :sent, id: "instance-apns-id", provider: :apns}} =
               PushX.push(:apns_send, "test-token", "Hello", topic: "com.test.app")
    end

    test "maps APNS error reasons and keeps the raw body", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/bad-token", fn conn ->
        apns_error(conn, 400, "BadDeviceToken")
      end)

      assert {:error, %Response{status: :invalid_token, reason: "BadDeviceToken", raw: raw}} =
               PushX.push(:apns_send, "bad-token", "Hello", topic: "com.test.app")

      assert raw =~ "BadDeviceToken"
    end

    test "falls back to the HTTP status when the error body is not JSON", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        Plug.Conn.resp(conn, 502, "gateway blew up")
      end)

      assert {:error, %Response{status: :unknown_error, reason: "HTTP 502"}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")
    end

    test "surfaces retry-after on 429", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "12")
        |> apns_error(429, "TooManyRequests")
      end)

      assert {:error, %Response{status: :rate_limited, retry_after: 12}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")
    end

    test "returns connection_error when the server is down", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, %Response{status: :connection_error, provider: :apns}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")
    end

    test "retry: :none makes a single attempt on the instance path", %{bypass: bypass} do
      Application.put_env(:pushx, :retry_enabled, true)
      Application.put_env(:pushx, :retry_base_delay_ms, 60_000)
      on_exit(fn -> Application.delete_env(:pushx, :retry_base_delay_ms) end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token", fn conn ->
        Agent.update(counter, &(&1 + 1))
        apns_error(conn, 500, "InternalServerError")
      end)

      assert {:error, %Response{status: :server_error}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app", retry: :none)

      assert Agent.get(counter, & &1) == 1
    end

    test "requires :topic without touching the network" do
      assert {:error, %Response{status: :invalid_request, reason: ":topic option is required"}} =
               PushX.push(:apns_send, "token", "Hello")
    end

    test "rejects an invalid :mode" do
      assert {:error, %Response{status: :invalid_request, reason: reason}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app", mode: :staging)

      assert reason =~ "Invalid :mode :staging"
    end

    test "rejects device tokens with unsafe characters" do
      assert {:error, %Response{status: :invalid_token}} =
               PushX.push(:apns_send, "../evil token", "Hello", topic: "com.test.app")
    end

    test "rejects oversized payloads, with the larger limit for voip", %{bypass: bypass} do
      # ~4.5 KB: over the 4096-byte alert limit, under the 5120-byte voip limit.
      big = %{"aps" => %{"alert" => String.duplicate("x", 4_500)}}

      assert {:error, %Response{status: :payload_too_large, reason: reason}} =
               PushX.push(:apns_send, "token", big, topic: "com.test.app")

      assert reason =~ "exceeds APNS limit of 4096"

      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["voip"]
        apns_ok(conn)
      end)

      assert {:ok, %Response{status: :sent}} =
               PushX.push(:apns_send, "token", big, topic: "com.test.app", push_type: "voip")
    end

    test "returns invalid_request when the payload cannot be JSON-encoded" do
      assert {:error, %Response{status: :invalid_request, reason: reason}} =
               PushX.push(:apns_send, "token", %{"aps" => {:not, :json}}, topic: "com.test.app")

      assert reason =~ "Failed to encode payload"
    end

    test "Message delivery fields become APNS headers; explicit opts win", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        assert Plug.Conn.get_req_header(conn, "apns-priority") == ["5"]
        assert Plug.Conn.get_req_header(conn, "apns-collapse-id") == ["thread-9"]
        assert Plug.Conn.get_req_header(conn, "apns-topic") == ["com.override.app"]
        apns_ok(conn)
      end)

      message =
        PushX.Message.new("Title", "Body")
        |> PushX.Message.priority(:normal)
        |> PushX.Message.collapse_key("thread-9")

      assert {:ok, _} = PushX.push(:apns_send, "token", message, topic: "com.override.app")
    end

    test "background pushes default to apns-priority 5", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        assert Plug.Conn.get_req_header(conn, "apns-push-type") == ["background"]
        assert Plug.Conn.get_req_header(conn, "apns-priority") == ["5"]
        apns_ok(conn)
      end)

      assert {:ok, _} =
               PushX.push(:apns_send, "token", %{"aps" => %{"content-available" => 1}},
                 topic: "com.test.app",
                 push_type: "background"
               )
    end

    test "ExpiredProviderToken invalidates the instance JWT and retries once", %{bypass: bypass} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token", fn conn ->
        case Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end) do
          1 -> apns_error(conn, 403, "ExpiredProviderToken")
          _ -> apns_ok(conn, "after-refresh")
        end
      end)

      assert {:ok, %Response{status: :sent, id: "after-refresh"}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")

      assert Agent.get(counter, & &1) == 2
    end

    test "a second stale-JWT rejection is returned as auth_error, not retried again", %{
      bypass: bypass
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.expect(bypass, "POST", "/3/device/token", fn conn ->
        Agent.update(counter, &(&1 + 1))
        apns_error(conn, 403, "InvalidProviderToken")
      end)

      assert {:error, %Response{status: :auth_error, reason: "InvalidProviderToken"}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")

      assert Agent.get(counter, & &1) == 2
    end

    test "TooManyProviderTokenUpdates is auth_error and does not regenerate", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn ->
        apns_error(conn, 429, "TooManyProviderTokenUpdates")
      end)

      assert {:error, %Response{status: :auth_error, reason: "TooManyProviderTokenUpdates"}} =
               PushX.push(:apns_send, "token", "Hello", topic: "com.test.app")
    end
  end

  describe "APNS instance private key sources" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      {:ok, bypass: bypass}
    end

    test "{:file, path} is read at start and at signing time", %{bypass: bypass} do
      path =
        Path.join(
          System.tmp_dir!(),
          "pushx-instance-key-#{System.unique_integer([:positive])}.p8"
        )

      File.write!(path, test_private_key())
      on_exit(fn -> File.rm(path) end)

      start_and_cleanup(:file_key, :apns, apns_config(private_key: {:file, path}))
      on_exit(fn -> PushX.JWTCache.invalidate({:apns_jwt, :file_key}) end)

      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn -> apns_ok(conn) end)

      assert {:ok, %Response{status: :sent}} =
               PushX.push(:file_key, "token", "Hello", topic: "com.test.app")
    end

    test "a key file that disappears after start yields auth_error, not a crash" do
      path =
        Path.join(
          System.tmp_dir!(),
          "pushx-instance-key-#{System.unique_integer([:positive])}.p8"
        )

      File.write!(path, test_private_key())
      start_and_cleanup(:vanishing_key, :apns, apns_config(private_key: {:file, path}))
      on_exit(fn -> PushX.JWTCache.invalidate({:apns_jwt, :vanishing_key}) end)
      File.rm!(path)

      assert {:error, %Response{status: :auth_error, reason: reason}} =
               PushX.push(:vanishing_key, "token", "Hello", topic: "com.test.app")

      assert reason =~ "JWT generation failed"
    end

    test "{:system, var} is resolved from the environment", %{bypass: bypass} do
      System.put_env("PUSHX_TEST_INSTANCE_KEY", test_private_key())
      on_exit(fn -> System.delete_env("PUSHX_TEST_INSTANCE_KEY") end)

      start_and_cleanup(
        :env_key,
        :apns,
        apns_config(private_key: {:system, "PUSHX_TEST_INSTANCE_KEY"})
      )

      on_exit(fn -> PushX.JWTCache.invalidate({:apns_jwt, :env_key}) end)

      Bypass.expect_once(bypass, "POST", "/3/device/token", fn conn -> apns_ok(conn) end)

      assert {:ok, %Response{status: :sent}} =
               PushX.push(:env_key, "token", "Hello", topic: "com.test.app")
    end

    test "a private key of the wrong shape gets an actionable message" do
      for bad <- [nil, 42, {:vault, "path"}] do
        assert {:error, {:invalid_private_key, reason}} =
                 Instance.start(:bad_key_shape, :apns, apns_config(private_key: bad))

        assert reason =~ ":private_key must be a PEM string, {:file, path} or {:system"
      end
    end

    test "an unset {:system, var} is rejected at start" do
      System.delete_env("PUSHX_TEST_UNSET_KEY")

      assert {:error, {:invalid_private_key, reason}} =
               Instance.start(
                 :unset_env_key,
                 :apns,
                 apns_config(private_key: {:system, "PUSHX_TEST_UNSET_KEY"})
               )

      assert reason =~ "PUSHX_TEST_UNSET_KEY not set"
    end
  end

  describe "FCM instance send path" do
    setup do
      bypass = Bypass.open()
      route_to_bypass(bypass)
      start_and_cleanup(:fcm_send, :fcm, fcm_config())
      {:ok, bypass: bypass}
    end

    test "does not start a Goth process when the instance has its own token fetcher" do
      assert Process.whereis(:"PushX.Goth.fcm_send") == nil
      assert Process.whereis(:"PushX.Finch.fcm_send") != nil
    end

    test "the global :fcm_token_fetcher does not apply to instances (Goth would be started)" do
      # Inspect the child specs without starting them: an instance without its
      # own :token_fetcher gets a Goth child even though the suite configures a
      # global fetcher — instance credentials are the instance's own.
      config = fcm_config() |> Keyword.delete(:token_fetcher)

      {:ok, {_flags, children}} =
        PushX.Instance.Supervisor.init(name: :inspect_only, provider: :fcm, config: config)

      assert Enum.any?(children, &(&1.id == Goth))

      {:ok, {_flags, children}} =
        PushX.Instance.Supervisor.init(name: :inspect_only, provider: :fcm, config: fcm_config())

      refute Enum.any?(children, &(&1.id == Goth))
    end

    test "returns connection_error (not :not_configured) when an instance's Goth is down" do
      # Instance path with no per-instance fetcher and no Goth registered under
      # its name: this is what a crashed/restarting Goth child looks like.
      assert {:error, %Response{status: :connection_error, reason: reason}} =
               PushX.FCM.fetch_access_token(:"PushX.Goth.ghost", nil)
               |> then(fn {:error, reason} -> PushX.FCM.oauth_error_response(reason) end)

      assert reason =~ "restarting"
    end

    test "the per-instance token fetcher is used and its failures are contained" do
      start_and_cleanup(
        :fetcher_inst,
        :fcm,
        fcm_config(token_fetcher: {PushX.TestOAuth, :fetch_error, []})
        |> Keyword.delete(:credentials)
      )

      Application.put_env(:pushx, :retry_enabled, false)
      on_exit(fn -> Application.delete_env(:pushx, :retry_enabled) end)

      assert {:error, %Response{status: :connection_error, reason: reason}} =
               PushX.push(:fetcher_inst, "t", "Hello")

      assert reason =~ "OAuth token error"

      # A fetcher tuple of the wrong shape is rejected at start.
      assert {:error, {:invalid_token_fetcher, _}} =
               Instance.start(:bad_fetcher, :fcm, project_id: "p", token_fetcher: "MyMod.fetch")

      # With a fetcher, credentials are optional; without either, credentials
      # are still required.
      assert {:error, {:missing_config, [:credentials]}} =
               Instance.start(:no_oauth, :fcm, project_id: "p")
    end

    test "sends to the instance's project with the fetched OAuth token", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer #{PushX.TestOAuth.token()}"]

        assert payload["message"]["token"] == "fcm-token"
        assert payload["message"]["notification"]["title"] == "Hello"

        fcm_ok(conn)
      end)

      assert {:ok,
              %Response{
                status: :sent,
                id: "projects/tenant-project/messages/m-1",
                provider: :fcm
              }} = PushX.push(:fcm_send, "fcm-token", "Hello")
    end

    test "returns success without an id when the response has no name", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, "{}")
      end)

      assert {:ok, %Response{status: :sent, id: nil}} = PushX.push(:fcm_send, "t", "Hello")
    end

    test "topic and condition targets work on the instance path; APNS instances reject them", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body)["message"]["topic"] == "tenant-news"
        fcm_ok(conn)
      end)

      assert {:ok, %Response{status: :sent}} =
               PushX.push(:fcm_send, {:topic, "tenant-news"}, "Hi")

      assert {:error, %Response{status: :invalid_request}} =
               PushX.push(:fcm_send, {:topic, "/topics/x"}, "Hi")

      start_and_cleanup(:apns_for_topics, :apns, apns_config())

      assert {:error, %Response{status: :invalid_request, reason: reason}} =
               PushX.push(:apns_for_topics, {:topic, "news"}, "Hi", topic: "com.test.app")

      assert reason =~ "device tokens only"
    end

    test "push_data/4 sends a data-only message through the instance", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["data"] == %{"action" => "sync", "id" => "7"}
        refute Map.has_key?(payload["message"], "notification")

        fcm_ok(conn, "data-1")
      end)

      assert {:ok, %Response{status: :sent, id: "data-1"}} =
               PushX.push_data(:fcm_send, "t", %{action: "sync", id: 7})
    end

    test "Message delivery fields and the apns override reach the wire", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        payload = JSON.decode!(body)

        assert payload["message"]["android"] == %{
                 "priority" => "NORMAL",
                 "ttl" => "3600s",
                 "collapse_key" => "updates"
               }

        assert payload["message"]["apns"]["headers"]["apns-priority"] == "5"

        fcm_ok(conn)
      end)

      message =
        PushX.Message.new("Title", "Body")
        |> PushX.Message.priority(:normal)
        |> PushX.Message.ttl(3600)
        |> PushX.Message.collapse_key("updates")

      assert {:ok, _} =
               PushX.push(:fcm_send, "t", message,
                 apns: %{"headers" => %{"apns-priority" => "5"}}
               )
    end

    test "maps FCM error codes, including UNREGISTERED nested in details", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          404,
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
        )
      end)

      assert {:error, %Response{status: :unregistered} = resp} =
               PushX.push(:fcm_send, "dead", "Hello")

      assert Response.should_remove_token?(resp)
    end

    test "handles error bodies with a numeric code and non-JSON bodies", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"error": {"code": 400, "message": "Bad request"}}))
      end)

      assert {:error, %Response{status: :unknown_error, reason: "Bad request"}} =
               PushX.push(:fcm_send, "t", "Hello")

      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        Plug.Conn.resp(conn, 503, "unavailable")
      end)

      assert {:error, %Response{status: :unknown_error, reason: "HTTP 503"}} =
               PushX.push(:fcm_send, "t", "Hello")
    end

    test "surfaces retry-after on QUOTA_EXCEEDED", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.put_resp_header("retry-after", "3")
        |> Plug.Conn.resp(
          429,
          ~s({"error": {"status": "QUOTA_EXCEEDED", "message": "slow down"}})
        )
      end)

      assert {:error, %Response{status: :rate_limited, retry_after: 3}} =
               PushX.push(:fcm_send, "t", "Hello")
    end

    test "returns connection_error when the server is down", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:error, %Response{status: :connection_error, provider: :fcm}} =
               PushX.push(:fcm_send, "t", "Hello")
    end

    test "the global :fcm_token_fetcher does not affect an instance's sends", %{bypass: bypass} do
      # Point the global fetcher at a failing one; the instance keeps using its
      # own and the send still goes through.
      Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch_error, []})

      on_exit(fn ->
        Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})
      end)

      Bypass.expect_once(bypass, "POST", "/v1/projects/tenant-project/messages:send", fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") ==
                 ["Bearer #{PushX.TestOAuth.token()}"]

        fcm_ok(conn)
      end)

      assert {:ok, %Response{status: :sent}} = PushX.push(:fcm_send, "t", "Hello")
    end

    test "rejects oversized payloads locally" do
      assert {:error, %Response{status: :payload_too_large}} =
               PushX.push(:fcm_send, "t", %{
                 "title" => "Hi",
                 "body" => String.duplicate("x", 5_000)
               })
    end

    test "returns invalid_request when the payload cannot be JSON-encoded" do
      assert {:error, %Response{status: :invalid_request, reason: reason}} =
               PushX.push(:fcm_send, "t", %{"notification" => %{"title" => {:not, :json}}})

      assert reason =~ "Failed to encode payload"
    end
  end

  describe "Instance.Supervisor.goth_source/1" do
    test "accepts decoded credentials or a JSON string" do
      creds = %{"type" => "service_account", "project_id" => "p"}

      assert PushX.Instance.Supervisor.goth_source(credentials: creds) ==
               {:service_account, creds}

      assert PushX.Instance.Supervisor.goth_source(credentials: JSON.encode!(creds)) ==
               {:service_account, creds}
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

  describe "circuit breaker and rate limiter on the instance path" do
    setup do
      Application.put_env(:pushx, :circuit_breaker_enabled, true)
      Application.put_env(:pushx, :circuit_breaker_threshold, 3)

      on_exit(fn ->
        Application.delete_env(:pushx, :circuit_breaker_enabled)
        Application.delete_env(:pushx, :circuit_breaker_threshold)
        PushX.CircuitBreaker.reset(:apns)
        PushX.CircuitBreaker.reset(:gated_instance)
      end)

      :ok
    end

    test "an open breaker for the instance key blocks sends without touching the network" do
      start_and_cleanup(:gated_instance, :apns, apns_config())

      for _ <- 1..3, do: PushX.CircuitBreaker.record_failure(:gated_instance)
      assert PushX.CircuitBreaker.state(:gated_instance) == :open

      assert {:error, %Response{status: :circuit_open}} =
               PushX.push(:gated_instance, "some-token", "Hello", topic: "com.test.app")
    end

    test "instance breaker state is independent of the static provider breaker" do
      start_and_cleanup(:gated_instance, :apns, apns_config())

      for _ <- 1..3, do: PushX.CircuitBreaker.record_failure(:apns)
      assert PushX.CircuitBreaker.state(:apns) == :open

      # The instance key is unaffected by the static :apns breaker.
      assert PushX.CircuitBreaker.state(:gated_instance) == :closed
    end
  end

  describe "per-key rate limiting" do
    setup do
      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_apns, 2)
      Application.put_env(:pushx, :rate_limit_window_ms, 60_000)

      on_exit(fn ->
        Application.delete_env(:pushx, :rate_limit_enabled)
        Application.delete_env(:pushx, :rate_limit_apns)
        Application.delete_env(:pushx, :rate_limit_window_ms)
        PushX.RateLimiter.reset_all()
        PushX.RateLimiter.reset(:tenant_x)
      end)

      :ok
    end

    test "instance keys count separately but use the provider's limit" do
      assert PushX.RateLimiter.check_and_increment(:tenant_x, :apns) == :ok
      assert PushX.RateLimiter.check_and_increment(:tenant_x, :apns) == :ok
      assert PushX.RateLimiter.check_and_increment(:tenant_x, :apns) == {:error, :rate_limited}

      # The static :apns budget is untouched by the instance key.
      assert PushX.RateLimiter.check_and_increment(:apns) == :ok
    end

    test "an exhausted instance budget short-circuits sends before the network" do
      # A client-side rate limit is retryable; disable retries so the gated
      # result comes back immediately instead of after a 60 s backoff.
      Application.put_env(:pushx, :retry_enabled, false)
      on_exit(fn -> Application.delete_env(:pushx, :retry_enabled) end)
      start_and_cleanup(:tenant_x, :apns, apns_config())

      # Consume the budget (limit 2) directly, then the real send path must
      # be gated without building a request.
      assert PushX.RateLimiter.check_and_increment(:tenant_x, :apns) == :ok
      assert PushX.RateLimiter.check_and_increment(:tenant_x, :apns) == :ok

      assert {:error, %Response{status: :rate_limited, provider: :apns}} =
               PushX.push(:tenant_x, "token", "Hello", topic: "com.test.app")
    end
  end
end
