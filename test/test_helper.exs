# Configure test environment
Application.put_env(:pushx, :apns_key_id, "TEST_KEY_ID")
Application.put_env(:pushx, :apns_team_id, "TEST_TEAM_ID")
Application.put_env(:pushx, :fcm_project_id, "test-project")

# INTENTIONALLY COMMITTED TEST KEY - NOT A REAL SECRET
# This is a randomly generated EC private key for testing JWT signing only.
# It is NOT associated with any Apple Developer account and cannot be used
# to send real push notifications. This pattern is standard practice for
# testing cryptographic operations in open-source libraries.
test_private_key = """
-----BEGIN EC PRIVATE KEY-----
MHQCAQEEIPuV3ghp1FUfoEQ+CAz+9wy7/E9rABKM/ZOE97UfpxeNoAcGBSuBBAAK
oUQDQgAE8xOUetsCa8EfOlXEuMwMt+dXxvLbRHT2n3M5Zu4pYL3HQH8R0Y45LjBC
dMxeXbAw7EO/23NPTfSfA1pXmXdVzw==
-----END EC PRIVATE KEY-----
"""

Application.put_env(:pushx, :apns_private_key, test_private_key)

ExUnit.start()
