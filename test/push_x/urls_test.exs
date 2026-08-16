defmodule PushX.URLsTest do
  use ExUnit.Case

  alias PushX.URLs

  # The production hosts are what every real send goes to; pin them so a
  # typo can never ship, and pin the test-only overrides the suite relies on.

  test "APNS URLs default to Apple's production and sandbox hosts" do
    Application.delete_env(:pushx, :apns_url_override)

    assert URLs.apns(:prod) == "https://api.push.apple.com"
    assert URLs.apns(:sandbox) == "https://api.sandbox.push.apple.com"
    assert URLs.apns_prod() == "https://api.push.apple.com"
    assert URLs.apns_sandbox() == "https://api.sandbox.push.apple.com"
  end

  test ":apns_url_override replaces the host for both modes" do
    Application.put_env(:pushx, :apns_url_override, "http://localhost:4001")
    on_exit(fn -> Application.delete_env(:pushx, :apns_url_override) end)

    assert URLs.apns(:prod) == "http://localhost:4001"
    assert URLs.apns(:sandbox) == "http://localhost:4001"
  end

  test "FCM send URL targets the v1 API for the given project" do
    Application.delete_env(:pushx, :fcm_url_override)

    assert URLs.fcm_send_url("my-project") ==
             "https://fcm.googleapis.com/v1/projects/my-project/messages:send"

    assert URLs.fcm_origin() == "https://fcm.googleapis.com"
  end

  test ":fcm_url_override replaces the origin but keeps the v1 path" do
    Application.put_env(:pushx, :fcm_url_override, "http://localhost:4002")
    on_exit(fn -> Application.delete_env(:pushx, :fcm_url_override) end)

    assert URLs.fcm_send_url("my-project") ==
             "http://localhost:4002/v1/projects/my-project/messages:send"
  end
end
