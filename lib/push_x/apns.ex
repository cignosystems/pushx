defmodule PushX.APNS do
  @moduledoc """
  Apple Push Notification Service (APNS) client.

  Sends push notifications to iOS, macOS, watchOS, and tvOS devices
  using HTTP/2 and JWT-based authentication.

  ## Configuration

  Add to your config:

      config :pushx,
        apns_key_id: "ABC123DEFG",
        apns_team_id: "TEAM123456",
        apns_private_key: {:file, "priv/keys/AuthKey.p8"},
        apns_mode: :prod  # or :sandbox

  ## Usage

      # Simple notification
      PushX.APNS.send(device_token, %{
        "aps" => %{
          "alert" => %{"title" => "Hello", "body" => "World"},
          "sound" => "default"
        }
      }, topic: "com.example.app")

      # Using Message struct
      message = PushX.Message.new("Hello", "World")
      PushX.APNS.send(device_token, message, topic: "com.example.app")

  """

  require Logger

  alias PushX.{Config, Message, Response, Retry, Telemetry}

  @apns_prod_url "https://api.push.apple.com"
  @apns_sandbox_url "https://api.sandbox.push.apple.com"

  # JWT token cache (cached for 50 minutes, Apple allows 60 min)
  @jwt_cache_ttl_ms 50 * 60 * 1000

  @type token :: String.t()
  @type payload :: map() | Message.t()
  @type option ::
          {:topic, String.t()}
          | {:mode, :prod | :sandbox}
          | {:push_type, String.t()}
          | {:priority, 5 | 10}
          | {:expiration, non_neg_integer()}
          | {:collapse_id, String.t()}

  @doc """
  Sends a push notification to an iOS device with automatic retry.

  Uses exponential backoff for transient failures following Apple's best practices.
  Permanent failures (bad token, payload too large) are not retried.

  ## Options

    * `:topic` - Bundle ID (required)
    * `:mode` - `:prod` or `:sandbox` (default: from config)
    * `:push_type` - "alert", "background", "voip", etc. (default: "alert")
    * `:priority` - 5 or 10 (default: 10)
    * `:expiration` - Unix timestamp when notification expires
    * `:collapse_id` - Group notifications with the same ID
    * `:retry` - Enable/disable retry (default: true from config)

  ## Returns

    * `{:ok, %PushX.Response{}}` on success
    * `{:error, %PushX.Response{}}` on failure

  """
  @spec send(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send(device_token, payload, opts \\ []) do
    Retry.with_retry(fn -> send_once(device_token, payload, opts) end)
  end

  @doc """
  Sends a push notification without retry.

  Use this when you want to handle retries yourself or for testing.
  """
  @spec send_once(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_once(device_token, payload, opts \\ []) do
    topic = Keyword.get(opts, :topic) || raise ArgumentError, ":topic option is required"
    mode = Keyword.get(opts, :mode, Config.apns_mode())

    url = "#{base_url(mode)}/3/device/#{device_token}"
    headers = build_headers(topic, opts)
    body = encode_payload(payload)

    Logger.debug("[PushX.APNS] Sending to #{device_token}")

    Telemetry.start(:apns, device_token)
    start_time = System.monotonic_time()

    try do
      case Finch.build(:post, url, headers, body)
           |> Finch.request(Config.finch_name()) do
        {:ok, %{status: 200, headers: response_headers}} ->
          apns_id = get_header(response_headers, "apns-id")
          response = Response.success(:apns, apns_id)
          Telemetry.stop(:apns, device_token, start_time, response)
          {:ok, response}

        {:ok, %{status: status, headers: response_headers, body: body}} ->
          {:error, response} = handle_error_response(status, body, response_headers)
          Telemetry.error(:apns, device_token, start_time, response)
          {:error, response}

        {:error, reason} ->
          Logger.error("[PushX.APNS] Connection error: #{inspect(reason)}")
          response = Response.error(:apns, :connection_error, inspect(reason))
          Telemetry.error(:apns, device_token, start_time, response)
          {:error, response}
      end
    rescue
      e ->
        Telemetry.exception(:apns, device_token, start_time, :error, e, __STACKTRACE__)
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Creates a simple notification payload.

  ## Examples

      iex> PushX.APNS.notification("Hello", "World")
      %{"aps" => %{"alert" => %{"title" => "Hello", "body" => "World"}, "sound" => "default"}}

  """
  @spec notification(String.t(), String.t(), non_neg_integer() | nil) :: map()
  def notification(title, body, badge \\ nil) do
    aps = %{
      "alert" => %{"title" => title, "body" => body},
      "sound" => "default"
    }

    aps = if badge, do: Map.put(aps, "badge", badge), else: aps
    %{"aps" => aps}
  end

  @doc """
  Creates a notification with custom data.
  """
  @spec notification_with_data(String.t(), String.t(), map(), non_neg_integer() | nil) :: map()
  def notification_with_data(title, body, data, badge \\ nil) do
    notification(title, body, badge)
    |> Map.merge(data)
  end

  @doc """
  Creates a silent/background notification.
  """
  @spec silent_notification(map()) :: map()
  def silent_notification(data \\ %{}) do
    %{"aps" => %{"content-available" => 1}}
    |> Map.merge(data)
  end

  # Private functions

  defp base_url(:prod), do: @apns_prod_url
  defp base_url(:sandbox), do: @apns_sandbox_url

  defp build_headers(topic, opts) do
    [
      {"authorization", "bearer #{get_jwt()}"},
      {"apns-topic", topic},
      {"apns-push-type", Keyword.get(opts, :push_type, "alert")},
      {"apns-priority", to_string(Keyword.get(opts, :priority, 10))}
    ]
    |> maybe_add_header("apns-expiration", Keyword.get(opts, :expiration))
    |> maybe_add_header("apns-collapse-id", Keyword.get(opts, :collapse_id))
  end

  defp maybe_add_header(headers, _key, nil), do: headers
  defp maybe_add_header(headers, key, value), do: [{key, to_string(value)} | headers]

  defp encode_payload(%Message{} = message), do: JSON.encode!(Message.to_apns_payload(message))
  defp encode_payload(payload) when is_map(payload), do: JSON.encode!(payload)

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  defp handle_error_response(status, body, response_headers) do
    reason =
      case JSON.decode(body) do
        {:ok, %{"reason" => reason}} -> reason
        _ -> "HTTP #{status}"
      end

    error_status = Response.apns_reason_to_status(reason)
    retry_after = parse_retry_after(response_headers)

    Logger.warning("[PushX.APNS] Failed #{status}: #{reason}")
    {:error, Response.error(:apns, error_status, reason, body, retry_after)}
  end

  defp parse_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after_value(value)
    end
  end

  defp parse_retry_after_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} -> seconds
      _ -> nil
    end
  end

  defp parse_retry_after_value(_), do: nil

  # JWT Token Management with caching

  defp get_jwt do
    cache_key = :apns_jwt_cache
    now = System.system_time(:millisecond)

    case :persistent_term.get(cache_key, nil) do
      {token, expires_at} when is_integer(expires_at) ->
        if expires_at > now do
          token
        else
          refresh_jwt(cache_key)
        end

      _ ->
        refresh_jwt(cache_key)
    end
  end

  defp refresh_jwt(cache_key) do
    token = generate_jwt()
    expires_at = System.system_time(:millisecond) + @jwt_cache_ttl_ms
    :persistent_term.put(cache_key, {token, expires_at})
    token
  end

  defp generate_jwt do
    key_id = Config.apns_key_id()
    team_id = Config.apns_team_id()
    private_key = Config.apns_private_key()

    signer = Joken.Signer.create("ES256", %{"pem" => private_key}, %{"kid" => key_id})

    claims = %{
      "iss" => team_id,
      "iat" => System.system_time(:second)
    }

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _claims} ->
        token

      {:error, reason} ->
        Logger.error("[PushX.APNS] JWT generation failed: #{inspect(reason)}")
        raise "Failed to generate APNS JWT: #{inspect(reason)}"
    end
  end
end
