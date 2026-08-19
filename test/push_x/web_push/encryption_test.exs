defmodule PushX.WebPush.EncryptionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PushX.WebPush.Encryption

  defp b64d(s), do: Base.url_decode64!(s, padding: false)
  defp b64(b), do: Base.url_encode64(b, padding: false)

  # RFC 8291, Appendix A — the complete worked example.
  @plaintext "When I grow up, I want to be a watermelon"
  @ua_private "q1dXpw3UpT5VOmu_cf_v6ih07Aems3njxI-JWgLcM94"
  @ua_public "BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4"
  @auth "BTBZMqHH6r4Tts7J_aSIgg"
  @salt "DGv6ra1nlYgDCS1FRnbzlw"
  @as_private "yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw"
  @as_public "BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8"
  @cek "oIhVW04MRdy2XN9CiKLxTg"
  @nonce "4h_95klXJ5E_qnoN"
  @body "DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN"

  describe "RFC 8291 Appendix A vectors" do
    test "key derivation reproduces CEK and NONCE" do
      {cek, nonce} =
        Encryption.derive(
          b64d(@ua_public),
          b64d(@auth),
          b64d(@salt),
          b64d(@as_public),
          b64d(@as_private)
        )

      assert b64(cek) == @cek
      assert b64(nonce) == @nonce
    end

    test "encrypt/3 with the RFC's salt and ephemeral key reproduces the exact body" do
      assert {:ok, body} =
               Encryption.encrypt(@plaintext, %{ua_public: b64d(@ua_public), auth: b64d(@auth)},
                 salt: b64d(@salt),
                 as_keys: {b64d(@as_public), b64d(@as_private)}
               )

      assert b64(body) == @body
    end

    test "the browser side decrypts the RFC body back to the plaintext" do
      assert {:ok, @plaintext} = Encryption.decrypt(b64d(@body), b64d(@ua_private), b64d(@auth))
    end
  end

  describe "validation" do
    test "rejects malformed subscription keys and oversized plaintext" do
      good = %{ua_public: b64d(@ua_public), auth: b64d(@auth)}

      assert {:error, :invalid_keys} = Encryption.encrypt("x", %{good | ua_public: <<5, 0::512>>})
      assert {:error, :invalid_keys} = Encryption.encrypt("x", %{good | ua_public: <<4, 0::64>>})
      assert {:error, :invalid_keys} = Encryption.encrypt("x", %{good | auth: <<0::64>>})
      # A 65-byte point that is not on the curve fails in ECDH → invalid_keys, never a raise.
      assert {:error, :invalid_keys} = Encryption.encrypt("x", %{good | ua_public: <<4, 1::512>>})

      assert {:ok, _} =
               Encryption.encrypt(String.duplicate("a", Encryption.max_plaintext()), good)

      assert {:error, :payload_too_large} =
               Encryption.encrypt(String.duplicate("a", Encryption.max_plaintext() + 1), good)
    end
  end

  describe "round trip" do
    property "any plaintext up to the limit encrypts to a body the UA can decrypt, with fresh randomness" do
      {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
      auth = :crypto.strong_rand_bytes(16)

      check all(plaintext <- binary(max_length: 300)) do
        assert {:ok, body} = Encryption.encrypt(plaintext, %{ua_public: ua_public, auth: auth})
        # header: salt(16) rs(4)=4096 idlen(1)=65 key(65)
        assert <<_salt::binary-16, 4096::32, 65, 4, _::binary-64, _::binary>> = body
        assert byte_size(body) == 86 + byte_size(plaintext) + 1 + 16
        assert {:ok, ^plaintext} = Encryption.decrypt(body, ua_private, auth)
      end
    end

    test "decrypt/3 reports tampered or malformed bodies instead of raising" do
      {ua_public, ua_private} = :crypto.generate_key(:ecdh, :prime256v1)
      auth = :crypto.strong_rand_bytes(16)
      {:ok, body} = Encryption.encrypt("hello", %{ua_public: ua_public, auth: auth})

      tampered = binary_part(body, 0, byte_size(body) - 1) <> <<0>>
      assert {:error, :decrypt_failed} = Encryption.decrypt(tampered, ua_private, auth)
      assert {:error, :malformed_body} = Encryption.decrypt(<<1, 2, 3>>, ua_private, auth)
    end

    test "two encryptions of the same plaintext differ (fresh salt and ephemeral key)" do
      {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1)
      keys = %{ua_public: ua_public, auth: :crypto.strong_rand_bytes(16)}
      {:ok, a} = Encryption.encrypt("same", keys)
      {:ok, b} = Encryption.encrypt("same", keys)
      refute a == b
    end
  end
end
