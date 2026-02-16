defmodule PushX.Response do
  @moduledoc """
  A struct representing the response from a push notification request.

  ## Fields

    * `:provider` - The provider used (`:apns` or `:fcm`)
    * `:status` - The result status (see below)
    * `:id` - Provider-specific message ID (if available)
    * `:reason` - Error reason string (if failed)
    * `:raw` - Raw response body (for debugging)

  ## Status Values

    * `:sent` - Message was successfully sent
    * `:invalid_token` - Device token is invalid or expired
    * `:expired_token` - Device token has expired
    * `:unregistered` - Device is no longer registered
    * `:payload_too_large` - Payload exceeds size limit
    * `:rate_limited` - Too many requests, try again later
    * `:server_error` - Provider server error
    * `:connection_error` - Network/connection failure
    * `:circuit_open` - Circuit breaker is open, provider temporarily blocked
    * `:invalid_request` - Missing or invalid request parameters (e.g., no `:topic` for APNS)
    * `:auth_error` - Authentication failure (e.g., invalid private key, JWT generation failed)
    * `:unknown_error` - Unrecognized error

  """

  @type status ::
          :sent
          | :invalid_token
          | :expired_token
          | :unregistered
          | :payload_too_large
          | :rate_limited
          | :server_error
          | :connection_error
          | :circuit_open
          | :provider_disabled
          | :invalid_request
          | :auth_error
          | :unknown_error

  @type t :: %__MODULE__{
          provider: :apns | :fcm | :unknown,
          status: status(),
          id: String.t() | nil,
          reason: String.t() | nil,
          raw: any(),
          retry_after: non_neg_integer() | nil
        }

  defstruct [
    :provider,
    :status,
    :id,
    :reason,
    :raw,
    :retry_after
  ]

  @doc """
  Creates a successful response.
  """
  @spec success(provider :: :apns | :fcm | :unknown, id :: String.t() | nil) :: t()
  def success(provider, id \\ nil) do
    %__MODULE__{
      provider: provider,
      status: :sent,
      id: id
    }
  end

  @doc """
  Creates an error response.
  """
  @spec error(provider :: :apns | :fcm | :unknown, status :: status(), reason :: String.t() | nil) ::
          t()
  def error(provider, status, reason \\ nil) do
    %__MODULE__{
      provider: provider,
      status: status,
      reason: reason
    }
  end

  @doc """
  Creates an error response with raw data.
  """
  @spec error(
          provider :: :apns | :fcm | :unknown,
          status :: status(),
          reason :: String.t() | nil,
          raw :: any()
        ) :: t()
  def error(provider, status, reason, raw) do
    %__MODULE__{
      provider: provider,
      status: status,
      reason: reason,
      raw: raw
    }
  end

  @doc """
  Creates an error response with raw data and retry_after value.
  """
  @spec error(
          provider :: :apns | :fcm | :unknown,
          status :: status(),
          reason :: String.t() | nil,
          raw :: any(),
          retry_after :: non_neg_integer() | nil
        ) :: t()
  def error(provider, status, reason, raw, retry_after) do
    %__MODULE__{
      provider: provider,
      status: status,
      reason: reason,
      raw: raw,
      retry_after: retry_after
    }
  end

  @doc """
  Maps an APNS error reason to a status atom.

  See: https://developer.apple.com/documentation/usernotifications/setting_up_a_remote_notification_server/handling_notification_responses_from_apns
  """
  @spec apns_reason_to_status(String.t()) :: status()
  def apns_reason_to_status(reason) do
    case reason do
      "BadDeviceToken" -> :invalid_token
      "Unregistered" -> :unregistered
      "ExpiredToken" -> :expired_token
      "PayloadTooLarge" -> :payload_too_large
      "TooManyRequests" -> :rate_limited
      "InternalServerError" -> :server_error
      "ServiceUnavailable" -> :server_error
      "Shutdown" -> :server_error
      _ -> :unknown_error
    end
  end

  @doc """
  Maps an FCM error code to a status atom.

  See: https://firebase.google.com/docs/reference/fcm/rest/v1/ErrorCode
  """
  @spec fcm_error_to_status(String.t()) :: status()
  def fcm_error_to_status(error_code) do
    case error_code do
      "INVALID_ARGUMENT" -> :invalid_token
      "UNREGISTERED" -> :unregistered
      "SENDER_ID_MISMATCH" -> :invalid_token
      "QUOTA_EXCEEDED" -> :rate_limited
      "UNAVAILABLE" -> :server_error
      "INTERNAL" -> :server_error
      _ -> :unknown_error
    end
  end

  @doc """
  Returns true if the response indicates success.

  ## Examples

      iex> PushX.Response.success(:apns, "id-123") |> PushX.Response.success?()
      true

      iex> PushX.Response.error(:fcm, :invalid_token, "bad") |> PushX.Response.success?()
      false

  """
  @spec success?(t()) :: boolean()
  def success?(%__MODULE__{status: :sent}), do: true
  def success?(%__MODULE__{}), do: false

  @doc """
  Returns true if the token should be removed from the database.

  ## Examples

      iex> PushX.Response.error(:apns, :invalid_token, "BadDeviceToken") |> PushX.Response.should_remove_token?()
      true

      iex> PushX.Response.error(:fcm, :server_error, "Internal") |> PushX.Response.should_remove_token?()
      false

  """
  @spec should_remove_token?(t()) :: boolean()
  def should_remove_token?(%__MODULE__{status: status}) do
    status in [:invalid_token, :expired_token, :unregistered]
  end

  @doc """
  Returns true if the error is retryable.

  Retryable errors:
  - `:connection_error` - Network/connection failure
  - `:rate_limited` - Too many requests (with backoff)
  - `:server_error` - Provider server error (5xx)

  ## Examples

      iex> PushX.Response.error(:fcm, :server_error, "Internal") |> PushX.Response.retryable?()
      true

      iex> PushX.Response.error(:apns, :invalid_token, "bad") |> PushX.Response.retryable?()
      false

  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{status: status}) do
    status in [:connection_error, :rate_limited, :server_error]
  end
end
