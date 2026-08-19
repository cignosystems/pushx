defmodule Mix.Tasks.Pushx.DoctorTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Pushx.Doctor
  alias Mix.Tasks.Pushx.Vapid
  alias PushX.WebPush.VAPID

  # The suite's test_helper configures APNS (generated key) and FCM
  # (project id + token fetcher); the doctor should be happy with that.
  test "passes with the suite's configuration and reports each check" do
    out = capture_io(fn -> Doctor.run([]) end)

    assert out =~ "APNS  ✔ configured (key TEST_KEY_ID, team TEST_TEAM_ID"
    assert out =~ "private key resolves and signs ES256"
    assert out =~ "FCM   ✔ project test-project"
    assert out =~ "token fetcher PushX.TestOAuth.fetch/1"
    assert out =~ "Delivery: live"
    assert out =~ "Retries:  enabled"
    assert out =~ "All checks passed."
  end

  test "fails (Mix.Error) on an APNS key that cannot sign, listing the problem" do
    original = Application.get_env(:pushx, :apns_private_key)
    Application.put_env(:pushx, :apns_private_key, "-----BEGIN GARBAGE-----")
    on_exit(fn -> Application.put_env(:pushx, :apns_private_key, original) end)

    out =
      capture_io(fn ->
        err = assert_raise Mix.Error, fn -> Doctor.run([]) end
        assert err.message =~ "found 1 problem(s)"
        assert err.message =~ "APNS private key"
      end)

    assert out =~ "✘ private key"
  end

  test "fails when FCM has a project but no OAuth source; validates service-account files" do
    Application.put_env(:pushx, :fcm_token_fetcher, nil)

    on_exit(fn ->
      Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})
    end)

    capture_io(fn ->
      err = assert_raise Mix.Error, fn -> Doctor.run([]) end
      assert err.message =~ "no OAuth source"
    end)

    # A real-looking service account file passes the RS256 check.
    path = Path.join(System.tmp_dir!(), "pushx-doctor-#{System.unique_integer([:positive])}.json")
    File.write!(path, JSON.encode!(PushX.Test.fcm_credentials()))
    on_exit(fn -> File.rm(path) end)
    Application.put_env(:pushx, :fcm_credentials, {:file, path})
    on_exit(fn -> Application.delete_env(:pushx, :fcm_credentials) end)

    out = capture_io(fn -> Doctor.run([]) end)
    assert out =~ "service-account credentials resolve and sign RS256"
    assert out =~ "All checks passed."

    # And a broken one fails.
    File.write!(path, ~s({"type": "service_account"}))

    capture_io(fn ->
      err = assert_raise Mix.Error, fn -> Doctor.run([]) end
      assert err.message =~ "FCM credentials"
    end)
  end

  test "reports unconfigured providers as skipped, not failed, and flags test delivery" do
    saved =
      for k <- [:apns_key_id, :fcm_project_id, :fcm_token_fetcher],
          do: {k, Application.get_env(:pushx, k)}

    for {k, _} <- saved, do: Application.delete_env(:pushx, k)
    Application.put_env(:pushx, :delivery, :test)

    on_exit(fn ->
      for {k, v} <- saved, do: Application.put_env(:pushx, k, v)
      Application.delete_env(:pushx, :delivery)
    end)

    out = capture_io(fn -> Doctor.run([]) end)
    assert out =~ "APNS  – not configured"
    assert out =~ "FCM   – not configured"
    assert out =~ "Delivery: test  ⚠"
    assert out =~ "All checks passed."
  end

  test "checks Web Push VAPID configuration when present" do
    keys = PushX.WebPush.generate_vapid_keys()
    Application.put_env(:pushx, :webpush_vapid_subject, "mailto:ops@example.com")
    Application.put_env(:pushx, :webpush_vapid_private_key, keys.private_key)

    on_exit(fn ->
      Application.delete_env(:pushx, :webpush_vapid_subject)
      Application.delete_env(:pushx, :webpush_vapid_private_key)
    end)

    out = capture_io(fn -> Doctor.run([]) end)
    assert out =~ "WEB   ✔ Web Push configured (subject mailto:ops@example.com)"
    assert out =~ "VAPID key resolves"

    Application.put_env(:pushx, :webpush_vapid_private_key, "garbage")

    capture_io(fn ->
      err = assert_raise Mix.Error, fn -> Doctor.run([]) end
      assert err.message =~ "Web Push VAPID key"
    end)
  end

  test "mix pushx.vapid prints a usable key pair with config snippets" do
    out = capture_io(fn -> Vapid.run([]) end)
    [_, pub] = Regex.run(~r/webpush_vapid_public_key: "([^"]+)"/, out)
    [_, priv] = Regex.run(~r/WEBPUSH_VAPID_PRIVATE_KEY="([^"]+)"/, out)
    assert {:ok, _} = VAPID.resolve_keys(pub, priv)
    assert out =~ "applicationServerKey"
  end
end
