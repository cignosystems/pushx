defmodule PushX.Token do
  @moduledoc since: "0.4.0"
  @moduledoc """
  Token validation for push notification device tokens.

  Validates token format before sending to avoid unnecessary API calls.
  Validation is fast (microseconds) and catches obvious errors early.

  ## APNS Tokens (iOS/macOS/Safari)

  APNS device tokens are currently 64 hexadecimal characters (32 bytes);
  Safari web push tokens use the same format. Apple explicitly warns not to
  hard-code the token length, so validation accepts any even-length hex
  string of at least 64 characters.
  Example: `"a1b2c3d4e5f6...64 hex chars total"`

  ## FCM Tokens (Android/Web)

  FCM registration tokens are variable length:
  - Mobile tokens: typically 140-250 characters
  - Web tokens: typically 50-200 characters
  They contain alphanumeric characters, hyphens, underscores, and colons.
  Example: `"dGVzdC10b2tlbi1mb3ItZmNt..."`

  ## Usage

      iex> PushX.Token.valid?(:apns, "a1b2c3d4" <> String.duplicate("0", 56))
      true

      iex> PushX.Token.valid?(:apns, "too-short")
      false

      iex> PushX.Token.validate(:apns, "invalid")
      {:error, :invalid_length}

  """

  @type provider :: :apns | :fcm | :webpush
  @type token :: String.t() | map()
  @type validation_error :: :empty | :invalid_format | :invalid_length

  # APNS tokens are currently 64 hex characters (32 bytes), but Apple warns
  # not to hard-code the length — future tokens may be longer. Accept any
  # even-length (whole bytes) hex string of >= 64 chars, with a generous
  # upper bound as a sanity check.
  @apns_token_min_length 64
  @apns_token_max_length 512
  @apns_token_regex ~r/^[a-fA-F0-9]+$/

  # FCM tokens vary in length:
  # - Mobile: typically 140-250 chars
  # - Web: typically 50-200 chars
  # We use a wider range to accommodate both
  @fcm_min_length 20
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
  @doc since: "0.4.0"
  @spec validate(provider(), token()) :: :ok | {:error, validation_error()}
  def validate(_provider, nil), do: {:error, :empty}
  def validate(_provider, ""), do: {:error, :empty}

  def validate(:apns, token) when is_binary(token) do
    length = byte_size(token)

    cond do
      length < @apns_token_min_length or length > @apns_token_max_length or
          rem(length, 2) != 0 ->
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

  # Web Push "tokens" are subscription maps (endpoint + keys); the shape check
  # is PushX.WebPush.validate_subscription/1 (https endpoint, 65-byte P-256
  # point, 16-byte auth secret).
  def validate(:webpush, subscription) when is_map(subscription) do
    case PushX.WebPush.validate_subscription(subscription) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :invalid_format}
    end
  end

  # Total over any term so callers (and property tests) can rely on it never
  # raising: anything else is not a token of any provider.
  def validate(_provider, _other), do: {:error, :invalid_format}

  @doc """
  Returns `true` if the token is valid for the given provider.

  ## Examples

      iex> PushX.Token.valid?(:apns, String.duplicate("a", 64))
      true

      iex> PushX.Token.valid?(:apns, "invalid")
      false

  """
  @doc since: "0.4.0"
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
  @doc since: "0.4.0"
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
  @doc since: "0.4.0"
  @spec error_message(provider(), validation_error()) :: String.t()
  def error_message(:apns, :empty), do: "APNS token cannot be empty"

  def error_message(:apns, :invalid_length),
    do: "APNS token must be at least 64 hexadecimal characters (an even count)"

  def error_message(:apns, :invalid_format),
    do: "APNS token must contain only hexadecimal characters (0-9, a-f)"

  def error_message(:fcm, :empty), do: "FCM token cannot be empty"

  def error_message(:fcm, :invalid_length),
    do: "FCM token length must be between 20 and 500 characters"

  def error_message(:fcm, :invalid_format), do: "FCM token contains invalid characters"
end
