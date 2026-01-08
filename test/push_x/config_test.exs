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

  describe "apns_configured?/0" do
    test "returns true when all APNS config is present" do
      # These are set in test_helper.exs
      assert Config.apns_configured?() == true
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
      assert Config.finch_pool_size() == 10
    end
  end

  describe "finch_pool_count/0" do
    test "returns default count when not configured" do
      assert Config.finch_pool_count() == 1
    end
  end
end
