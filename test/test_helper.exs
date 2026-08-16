# Configure test environment
Application.put_env(:pushx, :apns_key_id, "TEST_KEY_ID")
Application.put_env(:pushx, :apns_team_id, "TEST_TEAM_ID")
Application.put_env(:pushx, :fcm_project_id, "test-project")

# INTENTIONALLY COMMITTED TEST KEY - NOT A REAL SECRET
# This is a randomly generated P-256 EC private key for testing JWT signing
# only (APNS ES256 requires the P-256 curve — a key on any other curve cannot
# sign and is rejected by Instance credential validation). It is NOT
# associated with any Apple Developer account and cannot be used to send real
# push notifications. This pattern is standard practice for testing
# cryptographic operations in open-source libraries.
test_private_key = """
-----BEGIN EC PRIVATE KEY-----
MHcCAQEEIBqYTnB1ScQtMW4isi0bp6n41uusdwHAjIFlUXEyvHjHoAoGCCqGSM49
AwEHoUQDQgAEQUmMA/btEreya8c3XdFuHXHpc39lsn9FZQHYYVYps36KXTTWaVAC
J7BDAU8edFnAS0L40PGdujHkRdi2vKVCLA==
-----END EC PRIVATE KEY-----
"""

Application.put_env(:pushx, :apns_private_key, test_private_key)

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

# Service-account credentials for FCM instance tests. Instance.start/3
# test-signs the credentials' private key (RS256) before starting anything,
# so a throwaway RSA key is generated once per test run instead of being
# committed. Nothing about it is tied to any Google project.
defmodule PushX.TestCredentials do
  @key {__MODULE__, :fcm}

  def fcm do
    :persistent_term.get(@key, nil) || generate()
  end

  def fcm_private_key_pem, do: fcm()["private_key"]

  defp generate do
    rsa = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])

    creds = %{
      "type" => "service_account",
      "project_id" => "tenant-project",
      "private_key" => pem,
      "client_email" => "pushx-test@tenant-project.iam.gserviceaccount.com"
    }

    :persistent_term.put(@key, creds)
    creds
  end
end

# capture_log: the suite intentionally exercises failure paths (rate limits,
# open breakers, retries, JWT rejections), so their warnings are expected
# noise. Captured logs are still printed for failing tests.
ExUnit.start(capture_log: true)
