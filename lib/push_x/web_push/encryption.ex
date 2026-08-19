defmodule PushX.WebPush.Encryption do
  @moduledoc false

  # RFC 8291 message encryption for Web Push ("aes128gcm", RFC 8188 content
  # coding), single record. Everything here is pure `:crypto`:
  #
  #   ecdh_secret = ECDH(as_private, ua_public)                     (P-256)
  #   PRK_key     = HKDF-Extract(salt = auth_secret, IKM = ecdh_secret)
  #   IKM         = HKDF-Expand(PRK_key, "WebPush: info" || 0x00 || ua_public || as_public, 32)
  #   PRK         = HKDF-Extract(salt, IKM)
  #   CEK         = HKDF-Expand(PRK, "Content-Encoding: aes128gcm" || 0x00, 16)
  #   NONCE       = HKDF-Expand(PRK, "Content-Encoding: nonce" || 0x00, 12)
  #   body        = salt(16) || rs(4) || idlen(1) || as_public(65) || AES-128-GCM(plaintext || 0x02)
  #
  # `encrypt/3` takes the ephemeral key pair and salt as options so the RFC's
  # Appendix A vectors can be reproduced bit-for-bit in tests; callers in the
  # send path pass nothing and get fresh randomness.

  @record_size 4096
  # Header 86 bytes (16 + 4 + 1 + 65) + 1 delimiter + 16 GCM tag must fit in
  # the 4096-byte record every push service is required to accept.
  @max_plaintext @record_size - 86 - 1 - 16

  @type subscription_keys :: %{ua_public: binary(), auth: binary()}

  @doc "Maximum plaintext size in bytes for a single-record message."
  @spec max_plaintext() :: pos_integer()
  def max_plaintext, do: @max_plaintext

  @doc """
  Encrypts `plaintext` for the subscription's `ua_public` (65-byte uncompressed
  P-256 point) and 16-byte `auth` secret. Returns the complete aes128gcm body.

  Options (tests only): `:salt` (16 bytes), `:as_keys` (`{as_public, as_private}`).
  """
  @spec encrypt(binary(), subscription_keys(), keyword()) ::
          {:ok, binary()} | {:error, :payload_too_large | :invalid_keys}
  def encrypt(plaintext, %{ua_public: ua_public, auth: auth}, opts \\ [])
      when is_binary(plaintext) do
    cond do
      byte_size(plaintext) > @max_plaintext ->
        {:error, :payload_too_large}

      byte_size(ua_public) != 65 or binary_part(ua_public, 0, 1) != <<4>> or byte_size(auth) != 16 ->
        {:error, :invalid_keys}

      true ->
        salt = Keyword.get_lazy(opts, :salt, fn -> :crypto.strong_rand_bytes(16) end)

        {as_public, as_private} =
          Keyword.get_lazy(opts, :as_keys, fn -> :crypto.generate_key(:ecdh, :prime256v1) end)

        {cek, nonce} = derive(ua_public, auth, salt, as_public, as_private)

        # Single record: plaintext || 0x02 (last-record delimiter), no padding.
        {ciphertext, tag} =
          :crypto.crypto_one_time_aead(
            :aes_128_gcm,
            cek,
            nonce,
            plaintext <> <<2>>,
            <<>>,
            16,
            true
          )

        {:ok, salt <> <<@record_size::32, 65>> <> as_public <> ciphertext <> tag}
    end
  rescue
    ErlangError -> {:error, :invalid_keys}
  end

  @doc false
  # Exposed for tests (RFC 8291 A.1 intermediate values) and for decrypting in
  # tests that play the browser: returns {content_encryption_key, nonce}.
  @spec derive(binary(), binary(), binary(), binary(), binary()) :: {binary(), binary()}
  def derive(ua_public, auth, salt, as_public, as_private) do
    ecdh_secret = :crypto.compute_key(:ecdh, ua_public, as_private, :prime256v1)
    prk_key = hkdf_extract(auth, ecdh_secret)
    ikm = hkdf_expand(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    prk = hkdf_extract(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)
    {cek, nonce}
  end

  @doc false
  # Test helper: the browser side of RFC 8291 — decrypt a body with the UA's
  # private key and auth secret.
  @spec decrypt(binary(), binary(), binary()) :: {:ok, binary()} | {:error, term()}
  def decrypt(
        <<salt::binary-16, _rs::32, 65, as_public::binary-65, rest::binary>>,
        ua_private,
        auth
      ) do
    {ua_public, _} = :crypto.generate_key(:ecdh, :prime256v1, ua_private)
    ecdh_secret = :crypto.compute_key(:ecdh, as_public, ua_private, :prime256v1)
    prk_key = hkdf_extract(auth, ecdh_secret)
    ikm = hkdf_expand(prk_key, "WebPush: info" <> <<0>> <> ua_public <> as_public, 32)
    prk = hkdf_extract(salt, ikm)
    cek = hkdf_expand(prk, "Content-Encoding: aes128gcm" <> <<0>>, 16)
    nonce = hkdf_expand(prk, "Content-Encoding: nonce" <> <<0>>, 12)

    tag_size = 16
    ct_size = byte_size(rest) - tag_size
    <<ciphertext::binary-size(^ct_size), tag::binary-size(^tag_size)>> = rest

    case :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, ciphertext, <<>>, tag, false) do
      :error -> {:error, :decrypt_failed}
      padded -> {:ok, strip_padding(padded)}
    end
  end

  def decrypt(_body, _ua_private, _auth), do: {:error, :malformed_body}

  # Remove the trailing delimiter (0x02 last record / 0x01 otherwise) and any zero padding after it.
  defp strip_padding(padded) do
    padded
    |> :binary.bin_to_list()
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == 0))
    |> case do
      [delim | rest] when delim in [1, 2] -> rest |> Enum.reverse() |> :binary.list_to_bin()
      _ -> padded
    end
  end

  # HKDF (RFC 5869) with SHA-256; every Web Push output length is ≤ 32 so a
  # single expand block suffices.
  defp hkdf_extract(salt, ikm), do: :crypto.mac(:hmac, :sha256, salt, ikm)

  defp hkdf_expand(prk, info, length) when length <= 32 do
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end
end
