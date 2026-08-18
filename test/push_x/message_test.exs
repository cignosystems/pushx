defmodule PushX.MessageTest do
  use ExUnit.Case
  doctest PushX.Message

  alias PushX.Message

  describe "new/0" do
    test "creates an empty message with defaults" do
      message = Message.new()
      assert message.title == nil
      assert message.body == nil
      assert message.badge == nil
      assert message.sound == nil
      assert message.data == %{}
      # nil = let each provider apply its own default
      assert message.priority == nil
    end
  end

  describe "new/2" do
    test "creates a message with title and body" do
      message = Message.new("Hello", "World")
      assert message.title == "Hello"
      assert message.body == "World"
    end
  end

  describe "builder pattern" do
    test "sets title" do
      message = Message.new() |> Message.title("Test Title")
      assert message.title == "Test Title"
    end

    test "sets body" do
      message = Message.new() |> Message.body("Test Body")
      assert message.body == "Test Body"
    end

    test "sets badge" do
      message = Message.new() |> Message.badge(5)
      assert message.badge == 5
    end

    test "sets sound" do
      message = Message.new() |> Message.sound("alert.wav")
      assert message.sound == "alert.wav"
    end

    test "sets data" do
      message = Message.new() |> Message.data(%{key: "value"})
      assert message.data == %{key: "value"}
    end

    test "adds to data with put_data" do
      message =
        Message.new()
        |> Message.put_data(:key1, "value1")
        |> Message.put_data(:key2, "value2")

      assert message.data == %{key1: "value1", key2: "value2"}
    end

    test "sets category" do
      message = Message.new() |> Message.category("INVITE")
      assert message.category == "INVITE"
    end

    test "sets thread_id" do
      message = Message.new() |> Message.thread_id("thread-123")
      assert message.thread_id == "thread-123"
    end

    test "sets image" do
      message = Message.new() |> Message.image("https://example.com/image.png")
      assert message.image == "https://example.com/image.png"
    end

    test "sets priority" do
      message = Message.new() |> Message.priority(:normal)
      assert message.priority == :normal
    end

    test "sets ttl" do
      message = Message.new() |> Message.ttl(3600)
      assert message.ttl == 3600
    end

    test "sets collapse_key" do
      message = Message.new() |> Message.collapse_key("updates")
      assert message.collapse_key == "updates"
    end

    test "chains multiple setters" do
      message =
        Message.new()
        |> Message.title("Alert")
        |> Message.body("Something happened")
        |> Message.badge(1)
        |> Message.sound("default")
        |> Message.data(%{event: "door_unlock"})

      assert message.title == "Alert"
      assert message.body == "Something happened"
      assert message.badge == 1
      assert message.sound == "default"
      assert message.data == %{event: "door_unlock"}
    end
  end

  describe "to_apns_payload/1" do
    test "converts simple message to APNS format" do
      message = Message.new("Hello", "World")
      payload = Message.to_apns_payload(message)

      assert payload == %{
               "aps" => %{
                 "alert" => %{"title" => "Hello", "body" => "World"},
                 "sound" => "default"
               }
             }
    end

    test "includes badge when set" do
      message = Message.new("Hello", "World") |> Message.badge(5)
      payload = Message.to_apns_payload(message)

      assert payload["aps"]["badge"] == 5
    end

    test "includes custom data" do
      message =
        Message.new("Hello", "World")
        |> Message.data(%{"lock_id" => "abc123"})

      payload = Message.to_apns_payload(message)

      assert payload["lock_id"] == "abc123"
    end

    test "includes category when set" do
      message = Message.new("Hello", "World") |> Message.category("INVITE")
      payload = Message.to_apns_payload(message)

      assert payload["aps"]["category"] == "INVITE"
    end

    test "includes thread-id when set" do
      message = Message.new("Hello", "World") |> Message.thread_id("thread-123")
      payload = Message.to_apns_payload(message)

      assert payload["aps"]["thread-id"] == "thread-123"
    end

    test "data with 'aps' key does not overwrite notification" do
      message =
        Message.new("Hello", "World")
        |> Message.data(%{"aps" => %{"alert" => "HACKED"}, "safe_key" => "safe_value"})

      payload = Message.to_apns_payload(message)

      assert payload["aps"]["alert"]["title"] == "Hello"
      assert payload["aps"]["alert"]["body"] == "World"
      assert payload["safe_key"] == "safe_value"
      refute payload["aps"]["alert"] == "HACKED"
    end

    test "data with atom :aps key does not overwrite notification" do
      message =
        Message.new("Hello", "World")
        |> Message.data(%{aps: %{"alert" => "HACKED"}, safe_key: "safe_value"})

      payload = Message.to_apns_payload(message)

      # The result must JSON-encode without producing duplicate "aps" keys
      json = JSON.encode!(payload)
      decoded = JSON.decode!(json)

      assert decoded["aps"]["alert"]["title"] == "Hello"
      assert decoded["aps"]["alert"]["body"] == "World"
      refute decoded["aps"]["alert"] == "HACKED"
    end
  end

  describe "to_fcm_payload/1" do
    test "converts simple message to FCM format" do
      message = Message.new("Hello", "World")
      payload = Message.to_fcm_payload(message)

      assert payload == %{
               "notification" => %{
                 "title" => "Hello",
                 "body" => "World"
               }
             }
    end

    test "includes image when set" do
      message = Message.new("Hello", "World") |> Message.image("https://example.com/img.png")
      payload = Message.to_fcm_payload(message)

      assert payload["notification"]["image"] == "https://example.com/img.png"
    end

    test "returns empty map for empty message" do
      message = Message.new()
      payload = Message.to_fcm_payload(message)

      assert payload == %{}
    end
  end

  describe "to_apns_options/1" do
    test "maps priority to APNS numeric priority" do
      assert Message.new("T", "B") |> Message.priority(:high) |> Message.to_apns_options() ==
               [priority: 10]

      assert Message.new("T", "B") |> Message.priority(:normal) |> Message.to_apns_options() ==
               [priority: 5]
    end

    test "returns no options for a plain message" do
      assert Message.new("T", "B") |> Message.to_apns_options() == []
    end

    test "maps ttl to an absolute expiration timestamp" do
      now = System.system_time(:second)
      [expiration: exp] = Message.new("T", "B") |> Message.ttl(3600) |> Message.to_apns_options()

      assert exp >= now + 3600
      assert exp <= now + 3601
    end

    test "ttl 0 maps to expiration 0 (attempt once, do not store)" do
      assert Message.new("T", "B") |> Message.ttl(0) |> Message.to_apns_options() ==
               [expiration: 0]
    end

    test "maps collapse_key to collapse_id" do
      assert Message.new("T", "B")
             |> Message.collapse_key("updates")
             |> Message.to_apns_options() == [collapse_id: "updates"]
    end
  end

  describe "to_fcm_android/1" do
    test "returns nil when no delivery fields are set" do
      assert Message.new("T", "B") |> Message.to_fcm_android() == nil
    end

    test "maps priority, ttl, and collapse_key" do
      android =
        Message.new("T", "B")
        |> Message.priority(:normal)
        |> Message.ttl(3600)
        |> Message.collapse_key("updates")
        |> Message.to_fcm_android()

      assert android == %{
               "priority" => "NORMAL",
               "ttl" => "3600s",
               "collapse_key" => "updates"
             }
    end

    test "maps :high priority to HIGH" do
      assert Message.new("T", "B") |> Message.priority(:high) |> Message.to_fcm_android() ==
               %{"priority" => "HIGH"}
    end
  end

  describe "iOS-specific fields and localization" do
    test "map to the APNS aps/alert dictionaries" do
      payload =
        Message.new("Title", "Body")
        |> Message.subtitle("Sub")
        |> Message.mutable_content()
        |> Message.content_available()
        |> Message.interruption_level(:time_sensitive)
        |> Message.relevance_score(0.8)
        |> Message.localized_title("T_KEY", ["a"])
        |> Message.localized_subtitle("S_KEY")
        |> Message.localized_body("B_KEY", ["x", "y"])
        |> Message.to_apns_payload()

      assert payload["aps"]["alert"] == %{
               "title" => "Title",
               "subtitle" => "Sub",
               "body" => "Body",
               "title-loc-key" => "T_KEY",
               "title-loc-args" => ["a"],
               "subtitle-loc-key" => "S_KEY",
               "loc-key" => "B_KEY",
               "loc-args" => ["x", "y"]
             }

      assert payload["aps"]["mutable-content"] == 1
      assert payload["aps"]["content-available"] == 1
      assert payload["aps"]["interruption-level"] == "time-sensitive"
      assert payload["aps"]["relevance-score"] == 0.8
    end

    test "defaults are inert: an unset message produces the same aps as before" do
      assert Message.new("Hi", "There") |> Message.to_apns_payload() ==
               %{
                 "aps" => %{
                   "alert" => %{"title" => "Hi", "body" => "There"},
                   "sound" => "default"
                 }
               }

      assert Message.new() |> Message.to_fcm_apns() == nil
      assert Message.new() |> Message.to_fcm_android() == nil
    end

    test "localization-only alerts (no literal title/body) still produce an alert dictionary" do
      payload = Message.new() |> Message.localized_body("B_KEY") |> Message.to_apns_payload()
      assert payload["aps"]["alert"] == %{"loc-key" => "B_KEY"}
      # No title → no default sound injected.
      refute Map.has_key?(payload["aps"], "sound")
    end

    test "interruption levels are validated; relevance score is 0..1" do
      assert Message.new()
             |> Message.interruption_level(:critical)
             |> Message.to_apns_payload()
             |> get_in(["aps", "interruption-level"]) == "critical"

      # Bind through a variable so the deliberately bad calls aren't flagged
      # by the compiler's type checker as constant mismatches.
      bad_level = Enum.random([:loud])
      bad_score = Enum.random([1.5])

      assert_raise FunctionClauseError, fn ->
        Message.interruption_level(Message.new(), bad_level)
      end

      assert_raise FunctionClauseError, fn ->
        Message.relevance_score(Message.new(), bad_score)
      end

      assert %Message{relevance_score: 1.0} = Message.new() |> Message.relevance_score(1)
    end

    test "to_fcm_apns/1 carries the iOS-only keys, not title/body (FCM sends those)" do
      message =
        Message.new("Title", "Body")
        |> Message.subtitle("Sub")
        |> Message.mutable_content()
        |> Message.interruption_level(:passive)
        |> Message.localized_body("B_KEY", ["1"])

      assert Message.to_fcm_apns(message) == %{
               "payload" => %{
                 "aps" => %{
                   "mutable-content" => 1,
                   "interruption-level" => "passive",
                   "alert" => %{"subtitle" => "Sub", "loc-key" => "B_KEY", "loc-args" => ["1"]}
                 }
               }
             }
    end

    test "to_fcm_android/1 carries localization under android.notification" do
      android =
        Message.new("T", "B")
        |> Message.priority(:high)
        |> Message.localized_title("T_KEY", ["a"])
        |> Message.localized_body("B_KEY")
        |> Message.to_fcm_android()

      assert android == %{
               "priority" => "HIGH",
               "notification" => %{
                 "title_loc_key" => "T_KEY",
                 "title_loc_args" => ["a"],
                 "body_loc_key" => "B_KEY"
               }
             }
    end
  end
end
