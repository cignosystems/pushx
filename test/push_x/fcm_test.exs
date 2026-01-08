defmodule PushX.FCMTest do
  use ExUnit.Case

  alias PushX.FCM

  describe "notification/2" do
    test "creates a basic notification payload" do
      payload = FCM.notification("Hello", "World")

      assert payload == %{
               "title" => "Hello",
               "body" => "World"
             }
    end
  end

  describe "notification/3" do
    test "includes image when provided" do
      payload = FCM.notification("Hello", "World", image: "https://example.com/img.png")

      assert payload["image"] == "https://example.com/img.png"
    end

    test "omits image when not provided" do
      payload = FCM.notification("Hello", "World", [])

      refute Map.has_key?(payload, "image")
    end
  end
end
