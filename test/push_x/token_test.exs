defmodule PushX.TokenTest do
  use ExUnit.Case, async: true

  alias PushX.Token

  describe "APNS token validation" do
    test "valid 64-character hex token" do
      token = String.duplicate("a", 64)
      assert Token.validate(:apns, token) == :ok
      assert Token.valid?(:apns, token) == true
    end

    test "valid token with mixed case hex" do
      token = "aAbBcCdDeEfF0123456789" <> String.duplicate("0", 42)
      assert Token.validate(:apns, token) == :ok
    end

    test "empty token" do
      assert Token.validate(:apns, "") == {:error, :empty}
      assert Token.validate(:apns, nil) == {:error, :empty}
    end

    test "too short token" do
      assert Token.validate(:apns, "abc123") == {:error, :invalid_length}
    end

    test "too long token" do
      token = String.duplicate("a", 65)
      assert Token.validate(:apns, token) == {:error, :invalid_length}
    end

    test "invalid characters (non-hex)" do
      # 'g' is not a valid hex character
      token = String.duplicate("g", 64)
      assert Token.validate(:apns, token) == {:error, :invalid_format}
    end

    test "token with spaces" do
      token = "a b c " <> String.duplicate("0", 58)
      assert Token.validate(:apns, token) == {:error, :invalid_format}
    end

    test "validate! raises on invalid token" do
      assert_raise ArgumentError, ~r/Invalid APNS token/, fn ->
        Token.validate!(:apns, "invalid")
      end
    end

    test "validate! returns :ok for valid token" do
      token = String.duplicate("a", 64)
      assert Token.validate!(:apns, token) == :ok
    end
  end

  describe "FCM token validation" do
    test "valid FCM token" do
      # FCM tokens are typically 140-250 chars
      token = String.duplicate("abc123_-:", 20)
      assert Token.validate(:fcm, token) == :ok
      assert Token.valid?(:fcm, token) == true
    end

    test "empty token" do
      assert Token.validate(:fcm, "") == {:error, :empty}
      assert Token.validate(:fcm, nil) == {:error, :empty}
    end

    test "too short token" do
      token = String.duplicate("a", 50)
      assert Token.validate(:fcm, token) == {:error, :invalid_length}
    end

    test "too long token" do
      token = String.duplicate("a", 501)
      assert Token.validate(:fcm, token) == {:error, :invalid_length}
    end

    test "valid token at minimum length" do
      token = String.duplicate("a", 100)
      assert Token.validate(:fcm, token) == :ok
    end

    test "valid token at maximum length" do
      token = String.duplicate("a", 500)
      assert Token.validate(:fcm, token) == :ok
    end

    test "invalid characters" do
      # FCM tokens don't allow spaces or special chars like @
      token = "abc@def " <> String.duplicate("0", 100)
      assert Token.validate(:fcm, token) == {:error, :invalid_format}
    end

    test "validate! raises on invalid token" do
      assert_raise ArgumentError, ~r/Invalid FCM token/, fn ->
        Token.validate!(:fcm, "short")
      end
    end
  end

  describe "error_message/2" do
    test "APNS error messages" do
      assert Token.error_message(:apns, :empty) == "APNS token cannot be empty"
      assert Token.error_message(:apns, :invalid_length) =~ "64 hexadecimal"
      assert Token.error_message(:apns, :invalid_format) =~ "hexadecimal"
    end

    test "FCM error messages" do
      assert Token.error_message(:fcm, :empty) == "FCM token cannot be empty"
      assert Token.error_message(:fcm, :invalid_length) =~ "100 and 500"
      assert Token.error_message(:fcm, :invalid_format) =~ "invalid characters"
    end
  end
end
