defmodule PushX.FCM do
  @moduledoc """
  Firebase Cloud Messaging (FCM) client.

  Sends push notifications to Android devices using the FCM v1 API
  with OAuth2 authentication via Goth.

  ## Configuration

  Add to your config:

      config :pushx,
        fcm_project_id: "my-project-id",
        fcm_credentials: {:file, "priv/keys/firebase-service-account.json"}

  ## Usage

      # Simple notification
      PushX.FCM.send(device_token, %{
        "notification" => %{
          "title" => "Hello",
          "body" => "World"
        }
      })

      # Using Message struct
      message = PushX.Message.new("Hello", "World")
      PushX.FCM.send(device_token, message)

      # With custom data
      PushX.FCM.send(device_token, notification, data: %{"key" => "value"})

  """

  require Logger

  alias PushX.{Config, Message, Response}

  @fcm_base_url "https://fcm.googleapis.com/v1/projects"

  @type token :: String.t()
  @type payload :: map() | Message.t()
  @type option ::
          {:project_id, String.t()}
          | {:data, map()}
          | {:android, map()}
          | {:apns, map()}
          | {:webpush, map()}

  @doc """
  Sends a push notification to an Android device.

  ## Options

    * `:project_id` - Firebase project ID (default: from config)
    * `:data` - Custom data payload map
    * `:android` - Android-specific configuration
    * `:apns` - APNS configuration (for iOS via FCM)
    * `:webpush` - Web push configuration

  ## Returns

    * `{:ok, %PushX.Response{}}` on success
    * `{:error, %PushX.Response{}}` on failure

  """
  @spec send(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send(device_token, payload, opts \\ []) do
    project_id = Keyword.get(opts, :project_id, Config.fcm_project_id())
    url = "#{@fcm_base_url}/#{project_id}/messages:send"

    message = build_message(device_token, payload, opts)

    headers = [
      {"authorization", "Bearer #{get_access_token()}"},
      {"content-type", "application/json"}
    ]

    body = JSON.encode!(message)

    Logger.debug("[PushX.FCM] Sending to #{device_token}")

    case Finch.build(:post, url, headers, body)
         |> Finch.request(Config.finch_name()) do
      {:ok, %{status: 200, body: response_body}} ->
        case JSON.decode(response_body) do
          {:ok, %{"name" => message_id}} ->
            {:ok, Response.success(:fcm, message_id)}

          _ ->
            {:ok, Response.success(:fcm)}
        end

      {:ok, %{status: status, body: body}} ->
        handle_error_response(status, body)

      {:error, reason} ->
        Logger.error("[PushX.FCM] Connection error: #{inspect(reason)}")
        {:error, Response.error(:fcm, :connection_error, inspect(reason))}
    end
  end

  @doc """
  Creates a simple notification payload.

  ## Examples

      iex> PushX.FCM.notification("Hello", "World")
      %{"title" => "Hello", "body" => "World"}

  """
  @spec notification(String.t(), String.t(), keyword()) :: map()
  def notification(title, body, opts \\ []) do
    %{"title" => title, "body" => body}
    |> maybe_put("image", Keyword.get(opts, :image))
  end

  @doc """
  Sends a data-only message (no visible notification).
  """
  @spec send_data(token(), map(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_data(device_token, data, opts \\ []) do
    project_id = Keyword.get(opts, :project_id, Config.fcm_project_id())
    url = "#{@fcm_base_url}/#{project_id}/messages:send"

    message = %{
      "message" => %{
        "token" => device_token,
        "data" => stringify_map(data)
      }
    }

    headers = [
      {"authorization", "Bearer #{get_access_token()}"},
      {"content-type", "application/json"}
    ]

    body = JSON.encode!(message)

    case Finch.build(:post, url, headers, body)
         |> Finch.request(Config.finch_name()) do
      {:ok, %{status: 200, body: response_body}} ->
        case JSON.decode(response_body) do
          {:ok, %{"name" => message_id}} ->
            {:ok, Response.success(:fcm, message_id)}

          _ ->
            {:ok, Response.success(:fcm)}
        end

      {:ok, %{status: status, body: body}} ->
        handle_error_response(status, body)

      {:error, reason} ->
        {:error, Response.error(:fcm, :connection_error, inspect(reason))}
    end
  end

  # Private functions

  defp build_message(token, %Message{} = message, opts) do
    base = %{
      "token" => token,
      "notification" => Message.to_fcm_payload(message)["notification"]
    }

    base
    |> maybe_put("data", stringify_map(Keyword.get(opts, :data) || message.data))
    |> maybe_put("android", Keyword.get(opts, :android))
    |> maybe_put("apns", Keyword.get(opts, :apns))
    |> maybe_put("webpush", Keyword.get(opts, :webpush))
    |> then(&%{"message" => &1})
  end

  defp build_message(token, payload, opts) when is_map(payload) do
    base = %{"token" => token}

    # If payload has "notification" key, use it directly
    # Otherwise treat the whole payload as notification
    base =
      if Map.has_key?(payload, "notification") do
        Map.put(base, "notification", payload["notification"])
      else
        Map.put(base, "notification", payload)
      end

    base
    |> maybe_put("data", stringify_map(Keyword.get(opts, :data)))
    |> maybe_put("android", Keyword.get(opts, :android))
    |> maybe_put("apns", Keyword.get(opts, :apns))
    |> maybe_put("webpush", Keyword.get(opts, :webpush))
    |> then(&%{"message" => &1})
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, data) when data == %{}, do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # FCM data values must be strings
  defp stringify_map(nil), do: nil
  defp stringify_map(map) when map == %{}, do: nil

  defp stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp handle_error_response(status, body) do
    {error_code, error_message} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{"status" => code, "message" => msg}}} ->
          {code, msg}

        {:ok, %{"error" => %{"code" => code, "message" => msg}}} ->
          {to_string(code), msg}

        _ ->
          {"UNKNOWN", "HTTP #{status}"}
      end

    error_status = Response.fcm_error_to_status(error_code)
    Logger.warning("[PushX.FCM] Failed #{status}: #{error_code} - #{error_message}")
    {:error, Response.error(:fcm, error_status, error_message, body)}
  end

  defp get_access_token do
    case Goth.fetch(PushX.Goth) do
      {:ok, %{token: token}} ->
        token

      {:error, reason} ->
        Logger.error("[PushX.FCM] Failed to get OAuth token: #{inspect(reason)}")
        raise "Failed to get FCM OAuth token: #{inspect(reason)}"
    end
  end
end
