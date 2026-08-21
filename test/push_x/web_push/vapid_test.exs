defmodule PushX.WebPush.VAPIDTest do
  use ExUnit.Case, async: true

  alias PushX.WebPush.VAPID

  test "generate/0 produces a matching base64url key pair that resolve_keys/2 accepts" do
    %{public_key: pub, private_key: priv} = VAPID.generate()
    assert {:ok, %{public: raw_pub, private: raw_priv}} = VAPID.resolve_keys(pub, priv)
    assert byte_size(raw_pub) == 65 and binary_part(raw_pub, 0, 1) == <<4>>
    assert byte_size(raw_priv) == 32
    # Public key is optional: derived from the private scalar.
    assert {:ok, %{public: ^raw_pub}} = VAPID.resolve_keys(nil, priv)
  end

  test "accepts a PEM EC private key and derives the public key" do
    pem = PushX.Test.apns_private_key()

    assert {:ok, %{public: <<4, _::binary-64>>, private: <<_::binary-32>>}} =
             VAPID.resolve_keys(nil, pem)
  end

  test "rejects mismatched or malformed keys with a readable reason" do
    %{public_key: pub_a} = VAPID.generate()
    %{private_key: priv_b} = VAPID.generate()

    assert {:error, "VAPID public key does not match the private key"} =
             VAPID.resolve_keys(pub_a, priv_b)

    assert {:error, reason} = VAPID.resolve_keys(pub_a, "not base64url!!")
    assert reason =~ "base64url"

    assert {:error, reason} =
             VAPID.resolve_keys(pub_a, Base.url_encode64(<<1, 2, 3>>, padding: false))

    assert reason =~ "32 bytes"
    assert {:error, reason} = VAPID.resolve_keys("AAAA", priv_b)
    assert reason =~ "65-byte"
    assert {:error, _} = VAPID.resolve_keys(nil, "-----BEGIN GARBAGE-----\n")
  end

  test "validate_subject/1 accepts mailto: and https: contact URIs only (RFC 8292 §2.1)" do
    assert :ok = VAPID.validate_subject("mailto:ops@example.com")
    assert :ok = VAPID.validate_subject("https://example.com/contact")

    for bad <- ["ops@example.com", "http://example.com", "mailto:", "https://", nil, 42] do
      assert {:error, reason} = VAPID.validate_subject(bad)
      assert reason =~ "mailto: or https:"
    end
  end

  test "a private scalar that the curve rejects is reported, not raised" do
    # 32 bytes of zeros passes the length check but is not a valid scalar.
    zero_scalar = Base.url_encode64(<<0::256>>, padding: false)
    assert {:error, reason} = VAPID.resolve_keys(nil, zero_scalar)
    assert reason =~ "not a valid P-256 scalar"
    # Same when the caller also supplies a public key.
    %{public_key: pub} = VAPID.generate()
    assert {:error, _} = VAPID.resolve_keys(pub, zero_scalar)
  end

  test "authorization/4 surfaces a signing failure instead of raising" do
    %{public_key: pub} = VAPID.generate()
    public = Base.url_decode64!(pub, padding: false)

    assert {:error, reason} =
             VAPID.authorization(
               "https://push.example.test/x",
               %{public: public, private: :not_a_scalar},
               "mailto:ops@example.com",
               :vapid_unit_test
             )

    assert reason =~ "VAPID JWT signing failed"
  end

  test "more key-shape errors are readable" do
    {:ok, rsa_pem} = {:ok, PushX.Test.fcm_credentials()["private_key"]}
    assert {:error, reason} = VAPID.resolve_keys(nil, rsa_pem)
    assert reason =~ "not an EC private key"
    assert {:error, reason} = VAPID.resolve_keys(nil, 42)
    assert reason =~ "base64url string or PEM"
    assert {:error, reason} = VAPID.resolve_keys(42, VAPID.generate().private_key)
    assert reason =~ "public key must be a base64url string"
    assert {:error, reason} = VAPID.resolve_keys("!!!", VAPID.generate().private_key)
    assert reason =~ "not base64url"
  end

  test "origin/1 keeps scheme, host and non-default port only" do
    assert VAPID.origin("https://fcm.googleapis.com/fcm/send/abc:APA91") ==
             "https://fcm.googleapis.com"

    assert VAPID.origin("https://updates.push.services.mozilla.com/wpush/v2/x") ==
             "https://updates.push.services.mozilla.com"

    assert VAPID.origin("http://localhost:4001/push/1") == "http://localhost:4001"
    assert VAPID.origin("https://web.push.apple.com:443/QAbc") == "https://web.push.apple.com"
  end

  test "sign/4 produces an ES256 JWT with aud/exp/sub verifiable by the public key" do
    %{public_key: pub, private_key: priv} = VAPID.generate()
    {:ok, keys} = VAPID.resolve_keys(pub, priv)

    {:ok, jwt} =
      VAPID.sign("https://push.example", "mailto:ops@example.com", keys.public, keys.private)

    <<4, x::binary-32, y::binary-32>> = keys.public

    jwk =
      JOSE.JWK.from_map(%{
        "kty" => "EC",
        "crv" => "P-256",
        "x" => Base.url_encode64(x, padding: false),
        "y" => Base.url_encode64(y, padding: false)
      })

    assert {true, %JOSE.JWT{fields: claims}, %JOSE.JWS{alg: {_, :ES256}}} =
             JOSE.JWT.verify_strict(jwk, ["ES256"], jwt)

    assert claims["aud"] == "https://push.example"
    assert claims["sub"] == "mailto:ops@example.com"
    assert claims["exp"] > System.system_time(:second) + 11 * 3600
    assert claims["exp"] <= System.system_time(:second) + 24 * 3600
  end

  test "authorization/4 formats the header and caches the JWT per origin and scope" do
    %{public_key: pub, private_key: priv} = VAPID.generate()
    {:ok, keys} = VAPID.resolve_keys(pub, priv)
    on_exit(fn -> PushX.JWTCache.invalidate({:vapid_jwt, :vapid_test, "https://a.example"}) end)

    {:ok, header} =
      VAPID.authorization("https://a.example/endpoint/1", keys, "mailto:a@b", :vapid_test)

    assert "vapid t=" <> rest = header
    [jwt, k] = String.split(rest, ", k=")
    assert k == pub
    assert length(String.split(jwt, ".")) == 3

    # Same origin, same scope → cached (identical token); different endpoint path doesn't matter.
    {:ok, header2} =
      VAPID.authorization("https://a.example/endpoint/2", keys, "mailto:a@b", :vapid_test)

    assert header2 == header
  end
end
