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

# capture_log: the suite intentionally exercises failure paths (rate limits,
# open breakers, retries, JWT rejections), so their warnings are expected
# noise. Captured logs are still printed for failing tests.
ExUnit.start(capture_log: true)
