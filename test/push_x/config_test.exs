defmodule PushX.ConfigTest do
  use ExUnit.Case

  alias PushX.Config

  describe "get/2" do
    test "returns configured value" do
      Application.put_env(:pushx, :test_key, "test_value")
      assert Config.get(:test_key) == "test_value"
      Application.delete_env(:pushx, :test_key)
    end

    test "returns default when not configured" do
      assert Config.get(:nonexistent_key, "default") == "default"
    end

    test "returns nil when not configured and no default" do
      assert Config.get(:nonexistent_key) == nil
    end
  end

  describe "get!/1" do
    test "returns configured value" do
      Application.put_env(:pushx, :required_key, "value")
      assert Config.get!(:required_key) == "value"
      Application.delete_env(:pushx, :required_key)
    end

    test "raises when not configured" do
      assert_raise ArgumentError, ~r/required but not set/, fn ->
        Config.get!(:missing_required_key)
      end
    end
  end

  describe "apns_key_id/0" do
    test "returns configured key id" do
      # Set in test_helper.exs
      assert Config.apns_key_id() == "TEST_KEY_ID"
    end
  end

  describe "apns_team_id/0" do
    test "returns configured team id" do
      assert Config.apns_team_id() == "TEST_TEAM_ID"
    end
  end

  describe "apns_private_key/0" do
    test "returns raw PEM string" do
      # Already set as raw string in test_helper.exs
      key = Config.apns_private_key()
      assert String.starts_with?(key, "-----BEGIN EC PRIVATE KEY-----")
    end

    test "reads from file when configured with {:file, path}" do
      # Create a temp file
      path = Path.join(System.tmp_dir!(), "test_apns_key.pem")
      File.write!(path, "-----BEGIN EC PRIVATE KEY-----\ntest\n-----END EC PRIVATE KEY-----")

      original = Application.get_env(:pushx, :apns_private_key)
      Application.put_env(:pushx, :apns_private_key, {:file, path})

      assert Config.apns_private_key() ==
               "-----BEGIN EC PRIVATE KEY-----\ntest\n-----END EC PRIVATE KEY-----"

      Application.put_env(:pushx, :apns_private_key, original)
      File.rm(path)
    end

    test "reads from env var when configured with {:system, var}" do
      original = Application.get_env(:pushx, :apns_private_key)
      System.put_env("TEST_APNS_KEY", "test-key-from-env")
      Application.put_env(:pushx, :apns_private_key, {:system, "TEST_APNS_KEY"})

      assert Config.apns_private_key() == "test-key-from-env"

      Application.put_env(:pushx, :apns_private_key, original)
      System.delete_env("TEST_APNS_KEY")
    end

    test "raises when env var not set" do
      original = Application.get_env(:pushx, :apns_private_key)
      Application.put_env(:pushx, :apns_private_key, {:system, "NONEXISTENT_VAR_12345"})

      assert_raise RuntimeError, ~r/not set/, fn ->
        Config.apns_private_key()
      end

      Application.put_env(:pushx, :apns_private_key, original)
    end
  end

  describe "apns_mode/0" do
    test "returns default :prod when not configured" do
      original = Application.get_env(:pushx, :apns_mode)
      Application.delete_env(:pushx, :apns_mode)

      assert Config.apns_mode() == :prod

      if original, do: Application.put_env(:pushx, :apns_mode, original)
    end

    test "returns configured mode" do
      Application.put_env(:pushx, :apns_mode, :sandbox)
      assert Config.apns_mode() == :sandbox
      Application.put_env(:pushx, :apns_mode, :prod)
    end
  end

  describe "apns_configured?/0" do
    test "returns true when all APNS config is present" do
      # These are set in test_helper.exs
      assert Config.apns_configured?() == true
    end

    test "returns false when key_id is missing" do
      original = Application.get_env(:pushx, :apns_key_id)
      Application.delete_env(:pushx, :apns_key_id)

      assert Config.apns_configured?() == false

      Application.put_env(:pushx, :apns_key_id, original)
    end
  end

  describe "fcm_project_id/0" do
    test "returns configured project id" do
      Application.put_env(:pushx, :fcm_project_id, "test-project")
      assert Config.fcm_project_id() == "test-project"
    end
  end

  describe "fcm_credentials/0" do
    test "returns {:file, path} when configured with file" do
      Application.put_env(:pushx, :fcm_credentials, {:file, "/path/to/creds.json"})
      assert Config.fcm_credentials() == {:file, "/path/to/creds.json"}
    end

    test "parses JSON when configured with {:json, string}" do
      Application.put_env(:pushx, :fcm_credentials, {:json, ~s({"project_id": "test"})})
      assert Config.fcm_credentials() == %{"project_id" => "test"}
    end

    test "returns map when configured as map" do
      creds = %{"project_id" => "test", "client_email" => "test@test.com"}
      Application.put_env(:pushx, :fcm_credentials, creds)
      assert Config.fcm_credentials() == creds
    end

    test "reads from env var when configured with {:system, var}" do
      System.put_env("TEST_FCM_CREDS", ~s({"project_id": "from-env"}))
      Application.put_env(:pushx, :fcm_credentials, {:system, "TEST_FCM_CREDS"})

      assert Config.fcm_credentials() == %{"project_id" => "from-env"}

      System.delete_env("TEST_FCM_CREDS")
    end

    test "raises when env var not set" do
      Application.put_env(:pushx, :fcm_credentials, {:system, "NONEXISTENT_FCM_VAR"})

      assert_raise RuntimeError, ~r/not set/, fn ->
        Config.fcm_credentials()
      end
    end
  end

  describe "fcm_configured?/0" do
    test "returns true when FCM config is present" do
      Application.put_env(:pushx, :fcm_project_id, "test")
      Application.put_env(:pushx, :fcm_credentials, %{})
      assert Config.fcm_configured?() == true
    end

    test "returns false when project_id is missing" do
      original_id = Application.get_env(:pushx, :fcm_project_id)
      Application.delete_env(:pushx, :fcm_project_id)

      assert Config.fcm_configured?() == false

      if original_id, do: Application.put_env(:pushx, :fcm_project_id, original_id)
    end
  end

  describe "finch_name/0" do
    test "returns default name when not configured" do
      assert Config.finch_name() == PushX.Finch
    end

    test "returns configured name" do
      Application.put_env(:pushx, :finch_name, MyApp.Finch)
      assert Config.finch_name() == MyApp.Finch
      Application.delete_env(:pushx, :finch_name)
    end
  end

  describe "finch_pool_size/0" do
    test "returns default size when not configured" do
      # Default increased to 25 in v0.6.0 for better handling of traffic bursts
      assert Config.finch_pool_size() == 25
    end

    test "returns configured size" do
      Application.put_env(:pushx, :finch_pool_size, 20)
      assert Config.finch_pool_size() == 20
      Application.delete_env(:pushx, :finch_pool_size)
    end
  end

  describe "finch_pool_count/0" do
    test "returns default count when not configured" do
      # Default increased to 2 in v0.6.0 for better handling of traffic bursts
      assert Config.finch_pool_count() == 2
    end

    test "returns configured count" do
      Application.put_env(:pushx, :finch_pool_count, 4)
      assert Config.finch_pool_count() == 4
      Application.delete_env(:pushx, :finch_pool_count)
    end
  end

  describe "retry_enabled?/0" do
    test "returns true by default" do
      original = Application.get_env(:pushx, :retry_enabled)
      Application.delete_env(:pushx, :retry_enabled)

      assert Config.retry_enabled?() == true

      if original != nil, do: Application.put_env(:pushx, :retry_enabled, original)
    end

    test "returns configured value" do
      Application.put_env(:pushx, :retry_enabled, false)
      assert Config.retry_enabled?() == false
      Application.put_env(:pushx, :retry_enabled, true)
    end
  end

  describe "retry_max_attempts/0" do
    test "returns default of 3" do
      original = Application.get_env(:pushx, :retry_max_attempts)
      Application.delete_env(:pushx, :retry_max_attempts)

      assert Config.retry_max_attempts() == 3

      if original, do: Application.put_env(:pushx, :retry_max_attempts, original)
    end
  end

  describe "retry_base_delay_ms/0" do
    test "returns default of 10_000" do
      original = Application.get_env(:pushx, :retry_base_delay_ms)
      Application.delete_env(:pushx, :retry_base_delay_ms)

      assert Config.retry_base_delay_ms() == 10_000

      if original, do: Application.put_env(:pushx, :retry_base_delay_ms, original)
    end
  end

  describe "retry_max_delay_ms/0" do
    test "returns default of 60_000" do
      original = Application.get_env(:pushx, :retry_max_delay_ms)
      Application.delete_env(:pushx, :retry_max_delay_ms)

      assert Config.retry_max_delay_ms() == 60_000

      if original, do: Application.put_env(:pushx, :retry_max_delay_ms, original)
    end
  end
end
