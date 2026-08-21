defmodule PushX.WebPush.VAPID do
  @moduledoc false

  # RFC 8292 VAPID: an ES256 JWT (aud = push service origin, exp ≤ 24 h,
  # sub = contact) signed with the application server's P-256 key, sent as
  # `Authorization: vapid t=<jwt>, k=<public key>`.
  #
  # Keys are the raw base64url forms every web-push tool produces
  # (public: 65-byte uncompressed point, private: 32-byte scalar); a PEM
  # private key (`-----BEGIN EC PRIVATE KEY-----`) is accepted too and the
  # public key is derived from it when not configured.

  @type keys :: %{public: binary(), private: binary()}

  @doc """
  Resolves `{public_b64url_or_nil, private_b64url_or_pem}` into raw key
  binaries, deriving the public key from the private one when missing.
  """
  @spec resolve_keys(String.t() | nil, String.t()) :: {:ok, keys()} | {:error, String.t()}
  def resolve_keys(public, private) do
    with {:ok, private_raw} <- decode_private(private),
         {:ok, public_raw} <- decode_public(public, private_raw) do
      # Sanity: the private scalar must derive the given public point.
      {derived, _} = :crypto.generate_key(:ecdh, :prime256v1, private_raw)

      cond do
        # A scalar of 0 (or a multiple of the curve order) derives the point at
        # infinity, which OTP returns as <<0>> — not a usable key.
        not match?(<<4, _::binary-64>>, derived) ->
          {:error, "VAPID private key is not a valid P-256 scalar"}

        derived != public_raw ->
          {:error, "VAPID public key does not match the private key"}

        true ->
          {:ok, %{public: public_raw, private: private_raw}}
      end
    end
  rescue
    e -> {:error, "invalid VAPID key: #{Exception.message(e)}"}
  end

  defp decode_private("-----BEGIN" <> _ = pem) do
    case :public_key.pem_decode(pem) do
      [entry | _] ->
        case :public_key.pem_entry_decode(entry) do
          {:ECPrivateKey, _, priv, _, _, _} when is_binary(priv) -> {:ok, priv}
          other -> {:error, "VAPID PEM is not an EC private key: #{inspect(elem(other, 0))}"}
        end

      [] ->
        {:error, "VAPID private key PEM could not be decoded"}
    end
  end

  defp decode_private(b64) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, <<_::binary-32>> = priv} -> {:ok, priv}
      {:ok, _} -> {:error, "VAPID private key must be 32 bytes (base64url)"}
      :error -> {:error, "VAPID private key is not base64url"}
    end
  end

  defp decode_private(_), do: {:error, "VAPID private key must be a base64url string or PEM"}

  defp decode_public(nil, private_raw) do
    {pub, _} = :crypto.generate_key(:ecdh, :prime256v1, private_raw)
    {:ok, pub}
  end

  defp decode_public(b64, _private_raw) when is_binary(b64) do
    case Base.url_decode64(b64, padding: false) do
      {:ok, <<4, _::binary-64>> = pub} ->
        {:ok, pub}

      {:ok, _} ->
        {:error, "VAPID public key must be a 65-byte uncompressed P-256 point (base64url)"}

      :error ->
        {:error, "VAPID public key is not base64url"}
    end
  end

  defp decode_public(_, _), do: {:error, "VAPID public key must be a base64url string"}

  @doc """
  RFC 8292 §2.1: the `sub` claim MUST be a contact URI — `mailto:` or `https:`.
  """
  @spec validate_subject(term()) :: :ok | {:error, String.t()}
  def validate_subject("mailto:" <> rest) when rest != "", do: :ok
  def validate_subject("https://" <> rest) when rest != "", do: :ok

  def validate_subject(other),
    do: {:error, "VAPID subject must be a mailto: or https: contact URI, got: #{inspect(other)}"}

  @doc "Generates a fresh VAPID key pair, base64url-encoded (the `web-push` CLI format)."
  @spec generate() :: %{public_key: String.t(), private_key: String.t()}
  def generate do
    {pub, priv} = :crypto.generate_key(:ecdh, :prime256v1)
    %{public_key: b64(pub), private_key: b64(priv)}
  end

  @doc """
  The `Authorization` header value for `endpoint`'s origin: a fresh or cached
  ES256 JWT (12 h lifetime, cached per origin for 11 h) plus the public key.
  """
  @spec authorization(String.t(), keys(), String.t(), atom()) ::
          {:ok, String.t()} | {:error, String.t()}
  def authorization(endpoint, %{public: pub, private: priv}, subject, cache_scope) do
    origin = origin(endpoint)

    case PushX.JWTCache.get_or_generate(
           {:vapid_jwt, cache_scope, origin},
           fn -> sign(origin, subject, pub, priv) end,
           :timer.hours(11)
         ) do
      {:ok, jwt} -> {:ok, "vapid t=#{jwt}, k=#{b64(pub)}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  def origin(endpoint) do
    uri = URI.parse(endpoint)
    port = if uri.port in [nil, URI.default_port(uri.scheme)], do: "", else: ":#{uri.port}"
    "#{uri.scheme}://#{uri.host}#{port}"
  end

  @doc false
  def sign(audience, subject, pub, priv) do
    <<4, x::binary-32, y::binary-32>> = pub

    jwk =
      JOSE.JWK.from_map(%{
        "kty" => "EC",
        "crv" => "P-256",
        "x" => b64(x),
        "y" => b64(y),
        "d" => b64(priv)
      })

    claims = %{
      "aud" => audience,
      "exp" => System.system_time(:second) + 12 * 3600,
      "sub" => subject
    }

    {_, jwt} = JOSE.JWT.sign(jwk, %{"alg" => "ES256"}, claims) |> JOSE.JWS.compact()
    {:ok, jwt}
  rescue
    e -> {:error, "VAPID JWT signing failed: #{Exception.message(e)}"}
  end

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
end
