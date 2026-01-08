defmodule PushX.APNSTest do
  use ExUnit.Case

  alias PushX.APNS

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
end
