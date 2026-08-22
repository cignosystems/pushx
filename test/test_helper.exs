# Configure test environment
Application.put_env(:pushx, :apns_key_id, "TEST_KEY_ID")
Application.put_env(:pushx, :apns_team_id, "TEST_TEAM_ID")
Application.put_env(:pushx, :fcm_project_id, "test-project")
# The Web Push tests run a local (plain http) push service; production only
# accepts https endpoints.
Application.put_env(:pushx, :webpush_allow_http, true)

# Throwaway APNS signing key: generated per VM by PushX.Test (the same helper
# library users get for starting instances in tests). APNS ES256 requires a
# P-256 key; nothing is committed and the key is tied to nothing.
Application.put_env(:pushx, :apns_private_key, PushX.Test.apns_private_key())

# Stub OAuth token source for FCM. Replaces Goth.fetch/1 via the
# :fcm_token_fetcher seam so the real FCM send paths (static and named
# instances) can be exercised against Bypass without a Goth process or
# service-account credentials. Tests that need the failure branch point the
# seam at `fetch_error/1` for their duration.
defmodule PushX.TestOAuth do
  @token "test-oauth-token"

  def token, do: @token

  def fetch(_goth_name), do: {:ok, %{token: @token}}

  def fetch_error(_goth_name), do: {:error, :oauth_down}
end

Application.put_env(:pushx, :fcm_token_fetcher, {PushX.TestOAuth, :fetch, []})

# capture_log: the suite intentionally exercises failure paths (rate limits,
# open breakers, retries, JWT rejections), so their warnings are expected
# noise. Captured logs are still printed for failing tests.
ExUnit.start(capture_log: true)
