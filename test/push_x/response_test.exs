defmodule PushX.ResponseTest do
  use ExUnit.Case
  doctest PushX.Response

  alias PushX.Response

  describe "success/2" do
    test "creates a success response" do
      response = Response.success(:apns, "apns-id-123")

      assert response.provider == :apns
      assert response.status == :sent
      assert response.id == "apns-id-123"
      assert response.reason == nil
    end

    test "creates a success response without id" do
      response = Response.success(:fcm)

      assert response.provider == :fcm
      assert response.status == :sent
      assert response.id == nil
    end
  end

  describe "error/3" do
    test "creates an error response" do
      response = Response.error(:apns, :invalid_token, "BadDeviceToken")

      assert response.provider == :apns
      assert response.status == :invalid_token
      assert response.reason == "BadDeviceToken"
    end
  end

  describe "error/4" do
    test "creates an error response with raw data" do
      raw = ~s({"reason": "BadDeviceToken"})
      response = Response.error(:apns, :invalid_token, "BadDeviceToken", raw)

      assert response.provider == :apns
      assert response.status == :invalid_token
      assert response.reason == "BadDeviceToken"
      assert response.raw == raw
    end
  end

  describe "success?/1" do
    test "returns true for sent status" do
      response = Response.success(:apns)
      assert Response.success?(response) == true
    end

    test "returns false for error status" do
      response = Response.error(:apns, :invalid_token)
      assert Response.success?(response) == false
    end
  end

  describe "should_remove_token?/1" do
    test "returns true for invalid_token" do
      response = Response.error(:apns, :invalid_token)
      assert Response.should_remove_token?(response) == true
    end

    test "returns true for expired_token" do
      response = Response.error(:apns, :expired_token)
      assert Response.should_remove_token?(response) == true
    end

    test "returns true for unregistered" do
      response = Response.error(:fcm, :unregistered)
      assert Response.should_remove_token?(response) == true
    end

    test "returns false for rate_limited" do
      response = Response.error(:fcm, :rate_limited)
      assert Response.should_remove_token?(response) == false
    end

    test "returns false for server_error" do
      response = Response.error(:apns, :server_error)
      assert Response.should_remove_token?(response) == false
    end

    test "returns false for auth_error" do
      response = Response.error(:apns, :auth_error)
      assert Response.should_remove_token?(response) == false
    end

    test "returns false for invalid_request" do
      response = Response.error(:apns, :invalid_request)
      assert Response.should_remove_token?(response) == false
    end
  end

  describe "retryable?/1" do
    test "returns false for auth_error" do
      response = Response.error(:apns, :auth_error, "JWT failed")
      assert Response.retryable?(response) == false
    end

    test "returns false for invalid_request" do
      response = Response.error(:apns, :invalid_request, ":topic required")
      assert Response.retryable?(response) == false
    end

    test "returns true for connection_error" do
      response = Response.error(:apns, :connection_error)
      assert Response.retryable?(response) == true
    end
  end

  describe "apns_reason_to_status/1" do
    test "maps known APNS errors" do
      assert Response.apns_reason_to_status("BadDeviceToken") == :invalid_token
      assert Response.apns_reason_to_status("Unregistered") == :unregistered
      assert Response.apns_reason_to_status("ExpiredToken") == :expired_token
      assert Response.apns_reason_to_status("PayloadTooLarge") == :payload_too_large
      assert Response.apns_reason_to_status("TooManyRequests") == :rate_limited
      assert Response.apns_reason_to_status("InternalServerError") == :server_error
      assert Response.apns_reason_to_status("ServiceUnavailable") == :server_error
      assert Response.apns_reason_to_status("Shutdown") == :server_error
    end

    test "returns unknown_error for unrecognized reasons" do
      assert Response.apns_reason_to_status("SomeNewError") == :unknown_error
    end
  end

  describe "fcm_error_to_status/1" do
    test "maps known FCM errors" do
      assert Response.fcm_error_to_status("INVALID_ARGUMENT") == :invalid_token
      assert Response.fcm_error_to_status("UNREGISTERED") == :unregistered
      assert Response.fcm_error_to_status("SENDER_ID_MISMATCH") == :invalid_token
      assert Response.fcm_error_to_status("QUOTA_EXCEEDED") == :rate_limited
      assert Response.fcm_error_to_status("UNAVAILABLE") == :server_error
      assert Response.fcm_error_to_status("INTERNAL") == :server_error
    end

    test "returns unknown_error for unrecognized codes" do
      assert Response.fcm_error_to_status("NEW_ERROR_CODE") == :unknown_error
    end
  end
end
