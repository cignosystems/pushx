defmodule PushX.WebPushTest do
  use ExUnit.Case, async: true

  alias PushX.{APNS, FCM, Token}

  describe "Token validation for web push" do
    test "Safari web push tokens are same format as iOS (64 hex chars)" do
      safari_token = String.duplicate("a", 64)
      assert Token.valid?(:apns, safari_token) == true
    end

    test "FCM web tokens can be shorter than mobile tokens" do
      # Web tokens from Firebase are typically 50-200 chars
      web_token = String.duplicate("abc123_-:", 10)
      assert byte_size(web_token) == 90

      # Should be valid with new minimum of 20
      short_web_token = String.duplicate("a", 50)
      assert Token.valid?(:fcm, short_web_token) == true
    end

    test "FCM web tokens accept colons and hyphens" do
      web_token = "dGVzdC10b2tlbi1mb3ItZmNt:APA91bG-" <> String.duplicate("a", 50)
      assert Token.valid?(:fcm, web_token) == true
    end
  end

  describe "APNS.web_notification/4" do
    test "creates basic web notification payload" do
      payload = APNS.web_notification("Hello", "World")

      assert payload["aps"]["alert"]["title"] == "Hello"
      assert payload["aps"]["alert"]["body"] == "World"
      assert payload["aps"]["alert"]["action"] == "View"
      assert payload["aps"]["url-args"] == []
    end

    test "creates payload with URL" do
      payload = APNS.web_notification("Hello", "World", "https://example.com/page/123")

      assert payload["aps"]["url-args"] == ["page", "123"]
    end

    test "creates payload with URL and query params" do
      payload =
        APNS.web_notification("Hello", "World", "https://example.com/page?id=123&ref=home")

      assert "page" in payload["aps"]["url-args"]
      assert "id=123" in payload["aps"]["url-args"]
      assert "ref=home" in payload["aps"]["url-args"]
    end

    test "creates payload with custom action" do
      payload = APNS.web_notification("Sale!", "50% off", "https://shop.com", action: "Shop Now")

      assert payload["aps"]["alert"]["action"] == "Shop Now"
    end

    test "creates payload with explicit url_args" do
      payload = APNS.web_notification("Update", "New version", nil, url_args: ["features", "v2"])

      assert payload["aps"]["url-args"] == ["features", "v2"]
    end
  end

  describe "APNS.web_notification_with_data/5" do
    test "creates payload with custom data" do
      payload =
        APNS.web_notification_with_data(
          "Order Update",
          "Your order shipped",
          "https://example.com/orders/123",
          %{"order_id" => "123", "carrier" => "FedEx"}
        )

      assert payload["aps"]["alert"]["title"] == "Order Update"
      assert payload["order_id"] == "123"
      assert payload["carrier"] == "FedEx"
    end
  end

  describe "FCM.web_notification/4" do
    test "creates basic web notification payload" do
      payload = FCM.web_notification("Hello", "World", "https://example.com")

      assert payload["notification"]["title"] == "Hello"
      assert payload["notification"]["body"] == "World"
      assert payload["webpush"]["fcm_options"]["link"] == "https://example.com"
    end

    test "creates payload with icon" do
      payload =
        FCM.web_notification("Hello", "World", "https://example.com",
          icon: "https://example.com/icon.png"
        )

      assert payload["notification"]["icon"] == "https://example.com/icon.png"
    end

    test "creates payload with image" do
      payload =
        FCM.web_notification("Hello", "World", "https://example.com",
          image: "https://example.com/image.jpg"
        )

      assert payload["notification"]["image"] == "https://example.com/image.jpg"
    end

    test "creates payload with badge" do
      payload =
        FCM.web_notification("Hello", "World", "https://example.com",
          badge: "https://example.com/badge.png"
        )

      assert payload["webpush"]["notification"]["badge"] == "https://example.com/badge.png"
    end

    test "creates payload with tag for grouping" do
      payload = FCM.web_notification("Hello", "World", "https://example.com", tag: "messages")

      assert payload["webpush"]["notification"]["tag"] == "messages"
    end

    test "creates payload with require_interaction" do
      payload =
        FCM.web_notification("Important", "Read this", "https://example.com",
          require_interaction: true
        )

      assert payload["webpush"]["notification"]["requireInteraction"] == true
    end

    test "omits empty webpush notification" do
      payload = FCM.web_notification("Hello", "World", "https://example.com")

      # Should only have fcm_options, not notification
      refute Map.has_key?(payload["webpush"], "notification")
    end
  end

  describe "FCM.notification/3" do
    test "still works for regular notifications" do
      payload = FCM.notification("Hello", "World")

      assert payload == %{"title" => "Hello", "body" => "World"}
    end

    test "includes image when provided" do
      payload = FCM.notification("Hello", "World", image: "https://example.com/img.jpg")

      assert payload["image"] == "https://example.com/img.jpg"
    end
  end

  describe "web push topic formats" do
    test "Safari web push uses web. prefix" do
      # Safari web push topics follow the format: web.{website-push-id}
      topic = "web.com.example.website"
      assert String.starts_with?(topic, "web.")
    end

    test "iOS topics use bundle ID format" do
      # iOS topics are just the bundle ID
      topic = "com.example.app"
      refute String.starts_with?(topic, "web.")
    end
  end
end
