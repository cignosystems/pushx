defmodule PushX.FCM do
  @moduledoc """
  Firebase Cloud Messaging (FCM) client.

  Sends push notifications to Android devices and web browsers using the FCM v1 API
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

  ## Web Push (Chrome, Firefox, Edge)

  FCM supports web push using the same API. Web tokens come from the browser's
  Firebase Messaging SDK (`firebase.messaging().getToken()`).

      # Web push with click action
      PushX.FCM.send(web_token, payload,
        webpush: %{
          "fcm_options" => %{"link" => "https://example.com/page"}
        }
      )

      # Using web notification helper
      payload = PushX.FCM.web_notification("Title", "Body", "https://example.com")
      PushX.FCM.send(web_token, payload)

  """

  require Logger

  alias PushX.{Config, Message, RateLimiter, Response, Retry, Telemetry}

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
  Sends a push notification to an Android device with automatic retry.

  Uses exponential backoff for transient failures following Google's best practices.
  Permanent failures (bad token, invalid argument) are not retried.

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
    Retry.with_retry(fn -> send_once(device_token, payload, opts) end)
  end

  @doc """
  Sends a push notification without retry.

  Use this when you want to handle retries yourself or for testing.
  """
  @spec send_once(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_once(device_token, payload, opts \\ []) do
    # Check rate limit first
    case RateLimiter.check_and_increment(:fcm) do
      {:error, :rate_limited} ->
        {:error, Response.error(:fcm, :rate_limited, "Client-side rate limit exceeded")}

      :ok ->
        do_send(device_token, payload, opts)
    end
  end

  defp do_send(device_token, payload, opts) do
    project_id = Keyword.get(opts, :project_id, Config.fcm_project_id())
    url = "#{@fcm_base_url}/#{project_id}/messages:send"

    message = build_message(device_token, payload, opts)

    headers = [
      {"authorization", "Bearer #{get_access_token()}"},
      {"content-type", "application/json"}
    ]

    body = JSON.encode!(message)

    Logger.debug("[PushX.FCM] Sending to #{device_token}")

    Telemetry.start(:fcm, device_token)
    start_time = System.monotonic_time()

    try do
      case Finch.build(:post, url, headers, body)
           |> Finch.request(Config.finch_name(), Config.finch_request_opts()) do
        {:ok, %{status: 200, body: response_body}} ->
          response =
            case JSON.decode(response_body) do
              {:ok, %{"name" => message_id}} ->
                Response.success(:fcm, message_id)

              _ ->
                Response.success(:fcm)
            end

          Telemetry.stop(:fcm, device_token, start_time, response)
          {:ok, response}

        {:ok, %{status: status, headers: response_headers, body: body}} ->
          {:error, response} = handle_error_response(status, body, response_headers)
          Telemetry.error(:fcm, device_token, start_time, response)
          {:error, response}

        {:error, reason} ->
          Logger.error("[PushX.FCM] Connection error: #{inspect(reason)}")
          response = Response.error(:fcm, :connection_error, inspect(reason))
          Telemetry.error(:fcm, device_token, start_time, response)
          {:error, response}
      end
    rescue
      e ->
        Telemetry.exception(:fcm, device_token, start_time, :error, e, __STACKTRACE__)
        reraise e, __STACKTRACE__
    end
  end

  @doc """
  Sends notifications to multiple devices concurrently.

  ## Options

  All standard options plus:
    * `:concurrency` - Max concurrent requests (default: 50)
    * `:timeout` - Timeout per request in ms (default: 30_000)

  ## Returns

  A list of `{token, result}` tuples.
  """
  @spec send_batch([token()], payload(), [option()]) ::
          [{token(), {:ok, Response.t()} | {:error, Response.t()}}]
  def send_batch(device_tokens, payload, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 50)
    timeout = Keyword.get(opts, :timeout, 30_000)
    send_opts = Keyword.drop(opts, [:concurrency, :timeout])

    device_tokens
    |> Task.async_stream(
      fn token -> {token, send(token, payload, send_opts)} end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, :timeout} -> {nil, {:error, Response.error(:fcm, :connection_error, "timeout")}}
    end)
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

  # Web Push helpers

  @doc """
  Creates a web push notification payload with click action.

  This helper creates a notification optimized for web browsers (Chrome, Firefox, Edge).
  The `link` option specifies the URL to open when the notification is clicked.

  ## Arguments

    * `title` - Notification title
    * `body` - Notification body
    * `link` - URL to open when clicked
    * `opts` - Optional keyword list:
      * `:icon` - Icon URL for the notification
      * `:image` - Large image URL
      * `:badge` - Badge icon URL (small monochrome icon)
      * `:tag` - Tag for notification grouping
      * `:renotify` - Whether to alert again for same tag (default: false)
      * `:require_interaction` - Keep notification until user interacts (default: false)

  ## Examples

      # Simple web notification
      PushX.FCM.web_notification("New Message", "You have a new message", "https://example.com/messages")

      # With icon and badge
      PushX.FCM.web_notification("Sale!", "50% off today",
        "https://shop.com",
        icon: "https://shop.com/icon.png",
        badge: "https://shop.com/badge.png"
      )

  """
  @spec web_notification(String.t(), String.t(), String.t(), keyword()) :: map()
  def web_notification(title, body, link, opts \\ []) do
    notification_payload =
      %{"title" => title, "body" => body}
      |> maybe_put("icon", Keyword.get(opts, :icon))
      |> maybe_put("image", Keyword.get(opts, :image))

    webpush_notification =
      %{}
      |> maybe_put("badge", Keyword.get(opts, :badge))
      |> maybe_put("tag", Keyword.get(opts, :tag))
      |> maybe_put("renotify", Keyword.get(opts, :renotify))
      |> maybe_put("requireInteraction", Keyword.get(opts, :require_interaction))

    %{
      "notification" => notification_payload,
      "webpush" =>
        %{
          "fcm_options" => %{"link" => link},
          "notification" => if(webpush_notification == %{}, do: nil, else: webpush_notification)
        }
        |> Map.reject(fn {_k, v} -> is_nil(v) end)
    }
  end

  @doc """
  Sends a web push notification with automatic retry.

  Convenience function that combines `web_notification/4` with `send/3`.

  ## Examples

      PushX.FCM.send_web(web_token, "Hello", "World", "https://example.com")

      # With options
      PushX.FCM.send_web(web_token, "Alert", "Check this out",
        "https://example.com/page",
        icon: "https://example.com/icon.png"
      )

  """
  @spec send_web(token(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def send_web(device_token, title, body, link, opts \\ []) do
    {web_opts, send_opts} =
      Keyword.split(opts, [:icon, :image, :badge, :tag, :renotify, :require_interaction])

    payload = web_notification(title, body, link, web_opts)
    send(device_token, payload, send_opts)
  end

  @doc """
  Sends a data-only message (no visible notification) with automatic retry.
  """
  @spec send_data(token(), map(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_data(device_token, data, opts \\ []) do
    Retry.with_retry(fn -> send_data_once(device_token, data, opts) end)
  end

  @doc """
  Sends a data-only message without retry.
  """
  @spec send_data_once(token(), map(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_data_once(device_token, data, opts \\ []) do
    # Check rate limit first
    case RateLimiter.check_and_increment(:fcm) do
      {:error, :rate_limited} ->
        {:error, Response.error(:fcm, :rate_limited, "Client-side rate limit exceeded")}

      :ok ->
        do_send_data(device_token, data, opts)
    end
  end

  defp do_send_data(device_token, data, opts) do
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

      {:ok, %{status: status, headers: response_headers, body: body}} ->
        handle_error_response(status, body, response_headers)

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

  defp handle_error_response(status, body, response_headers) do
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
    retry_after = parse_retry_after(response_headers)

    Logger.warning("[PushX.FCM] Failed #{status}: #{error_code} - #{error_message}")
    {:error, Response.error(:fcm, error_status, error_message, body, retry_after)}
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

  defp get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
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
