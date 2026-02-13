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
      assert message.priority == :high
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
end
