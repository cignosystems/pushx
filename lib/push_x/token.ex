defmodule PushX.Token do
  @moduledoc """
  Token validation for push notification device tokens.

  Validates token format before sending to avoid unnecessary API calls.
  Validation is fast (microseconds) and catches obvious errors early.

  ## APNS Tokens

  APNS device tokens are 64 hexadecimal characters (32 bytes).
  Example: `"a1b2c3d4e5f6...64 hex chars total"`

  ## FCM Tokens

  FCM registration tokens are variable length (typically 140-250 characters).
  They contain alphanumeric characters, hyphens, and underscores.
  Example: `"dGVzdC10b2tlbi1mb3ItZmNt..."`

  ## Usage

      iex> PushX.Token.valid?(:apns, "a1b2c3d4" <> String.duplicate("0", 56))
      true

      iex> PushX.Token.valid?(:apns, "too-short")
      false

      iex> PushX.Token.validate(:apns, "invalid")
      {:error, :invalid_format}

  """

  @type provider :: :apns | :fcm
  @type token :: String.t()
  @type validation_error :: :empty | :invalid_format | :invalid_length

  # APNS tokens are 64 hex characters (32 bytes)
  @apns_token_length 64
  @apns_token_regex ~r/^[a-fA-F0-9]{64}$/

  # FCM tokens are typically 140-250 chars, but can vary
  # They use base64-like encoding with some special chars
  @fcm_min_length 100
  @fcm_max_length 500
  @fcm_token_regex ~r/^[a-zA-Z0-9_:\-]+$/

  @doc """
  Validates a device token and returns `:ok` or `{:error, reason}`.

  ## Examples

      iex> PushX.Token.validate(:apns, String.duplicate("a", 64))
      :ok

      iex> PushX.Token.validate(:apns, "")
      {:error, :empty}

      iex> PushX.Token.validate(:apns, "too-short")
      {:error, :invalid_length}

      iex> PushX.Token.validate(:apns, String.duplicate("g", 64))
      {:error, :invalid_format}

  """
  @spec validate(provider(), token()) :: :ok | {:error, validation_error()}
  def validate(_provider, nil), do: {:error, :empty}
  def validate(_provider, ""), do: {:error, :empty}

  def validate(:apns, token) when is_binary(token) do
    cond do
      byte_size(token) != @apns_token_length ->
        {:error, :invalid_length}

      not Regex.match?(@apns_token_regex, token) ->
        {:error, :invalid_format}

      true ->
        :ok
    end
  end

  def validate(:fcm, token) when is_binary(token) do
    length = byte_size(token)

    cond do
      length < @fcm_min_length ->
        {:error, :invalid_length}

      length > @fcm_max_length ->
        {:error, :invalid_length}

      not Regex.match?(@fcm_token_regex, token) ->
        {:error, :invalid_format}

      true ->
        :ok
    end
  end

  @doc """
  Returns `true` if the token is valid for the given provider.

  ## Examples

      iex> PushX.Token.valid?(:apns, String.duplicate("a", 64))
      true

      iex> PushX.Token.valid?(:apns, "invalid")
      false

  """
  @spec valid?(provider(), token()) :: boolean()
  def valid?(provider, token) do
    validate(provider, token) == :ok
  end

  @doc """
  Validates a token and raises `ArgumentError` if invalid.

  ## Examples

      iex> PushX.Token.validate!(:apns, String.duplicate("a", 64))
      :ok

      iex> PushX.Token.validate!(:apns, "invalid")
      ** (ArgumentError) Invalid APNS token: invalid_length

  """
  @spec validate!(provider(), token()) :: :ok
  def validate!(provider, token) do
    case validate(provider, token) do
      :ok ->
        :ok

      {:error, reason} ->
        provider_name = provider |> to_string() |> String.upcase()
        raise ArgumentError, "Invalid #{provider_name} token: #{reason}"
    end
  end

  @doc """
  Returns a human-readable error message for validation errors.
  """
  @spec error_message(provider(), validation_error()) :: String.t()
  def error_message(:apns, :empty), do: "APNS token cannot be empty"

  def error_message(:apns, :invalid_length),
    do: "APNS token must be exactly 64 hexadecimal characters"

  def error_message(:apns, :invalid_format),
    do: "APNS token must contain only hexadecimal characters (0-9, a-f)"

  def error_message(:fcm, :empty), do: "FCM token cannot be empty"

  def error_message(:fcm, :invalid_length),
    do: "FCM token length must be between 100 and 500 characters"

  def error_message(:fcm, :invalid_format), do: "FCM token contains invalid characters"
end
