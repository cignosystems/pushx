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

      # Notification with custom data
      PushX.FCM.send(device_token, %{
        "notification" => %{"title" => "Alert", "body" => "Something happened"},
        "data" => %{"event_id" => "1"}
      })

      # Data-only (silent) message — no visible notification
      PushX.FCM.send_data(device_token, %{action: "sync", id: 123})

      # Data-only via structured payload
      PushX.FCM.send(device_token, %{"data" => %{"action" => "sync"}})

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

  alias PushX.{
    Config,
    HTTP,
    Message,
    Response,
    Retry,
    SendGate,
    Telemetry,
    URLs
  }

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
    case SendGate.check(:fcm, :fcm) do
      :ok ->
        result = do_send(device_token, payload, opts)
        SendGate.record(:fcm, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  defp do_send(device_token, payload, opts) do
    message = build_message(device_token, payload, opts)

    # Validate the payload (encode + size) before requesting an OAuth token.
    with {:ok, body} <- HTTP.safe_encode(message),
         :ok <- check_payload_size(body) do
      do_send_authenticated(device_token, body, opts)
    else
      {:error, reason} when is_binary(reason) ->
        {:error, Response.error(:fcm, :invalid_request, "Failed to encode payload: #{reason}")}

      {:error, %Response{} = response} ->
        {:error, response}
    end
  end

  defp do_send_authenticated(device_token, body, opts) do
    case get_access_token() do
      {:ok, access_token} ->
        project_id = Keyword.get(opts, :project_id, Config.fcm_project_id())
        url = URLs.fcm_send_url(project_id)

        headers = [
          {"authorization", "Bearer #{access_token}"},
          {"content-type", "application/json"}
        ]

        send_fcm_request(device_token, url, headers, body, opts)

      {:error, reason} ->
        Logger.error("[PushX.FCM] Failed to get OAuth token: #{inspect(reason)}")
        {:error, Response.error(:fcm, :connection_error, "OAuth token error: #{inspect(reason)}")}
    end
  end

  defp send_fcm_request(device_token, url, headers, body, opts) do
    Logger.debug(fn -> "[PushX.FCM] Sending to #{Telemetry.truncate_token(device_token)}" end)

    Telemetry.start(:fcm, device_token)
    start_time = System.monotonic_time()

    try do
      request_opts =
        Keyword.merge(
          Config.finch_request_opts(),
          Keyword.take(opts, [:receive_timeout, :pool_timeout])
        )

      # HTTP.finch_request carries the shared NimblePool CaseClauseError
      # rescue, so pool-death errors surface as retryable connection errors.
      case HTTP.finch_request(
             Finch.build(:post, url, headers, body),
             Config.finch_name(),
             request_opts,
             "PushX.FCM"
           ) do
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
    * `:validate_tokens` - Validate token format before sending (default: false).
      Invalid tokens get `{:error, %Response{status: :invalid_token}}` without
      hitting the network.

  Each task runs the full blocking retry cycle; make sure `:timeout`
  exceeds the worst-case retry backoff or disable retries — see
  `PushX.push_batch/4` for details.

  ## Returns

  A list of `{token, result}` tuples.
  """
  @spec send_batch([token()], payload(), [option()]) ::
          [{token(), {:ok, Response.t()} | {:error, Response.t()}}]
  def send_batch(device_tokens, payload, opts \\ []) do
    concurrency = Keyword.get(opts, :concurrency, 50)
    timeout = Keyword.get(opts, :timeout, 30_000)
    validate = Keyword.get(opts, :validate_tokens, false)
    send_opts = Keyword.drop(opts, [:concurrency, :timeout, :validate_tokens])

    # async_stream_nolink: a task that raises must report {:exit, reason}
    # below instead of taking down the caller through the task link.
    Task.Supervisor.async_stream_nolink(
      PushX.TaskSupervisor,
      device_tokens,
      fn token ->
        if validate and not PushX.Token.valid?(:fcm, token) do
          {token, {:error, Response.error(:fcm, :invalid_token, "Invalid token format")}}
        else
          {token, send(token, payload, send_opts)}
        end
      end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task
    )
    |> Enum.zip(device_tokens)
    |> Enum.map(fn
      {{:ok, result}, _token} ->
        result

      {{:exit, :timeout}, token} ->
        {token, {:error, Response.error(:fcm, :connection_error, "timeout")}}

      # A task that raises exits with {exception, stacktrace}; keep per-token
      # isolation instead of crashing the whole batch.
      {{:exit, reason}, token} ->
        {token,
         {:error, Response.error(:fcm, :unknown_error, "task exited: " <> inspect(reason))}}
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
    |> HTTP.maybe_put("image", Keyword.get(opts, :image))
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
      |> HTTP.maybe_put("icon", Keyword.get(opts, :icon))
      |> HTTP.maybe_put("image", Keyword.get(opts, :image))

    webpush_notification =
      %{}
      |> HTTP.maybe_put("badge", Keyword.get(opts, :badge))
      |> HTTP.maybe_put("tag", Keyword.get(opts, :tag))
      |> HTTP.maybe_put("renotify", Keyword.get(opts, :renotify))
      |> HTTP.maybe_put("requireInteraction", Keyword.get(opts, :require_interaction))

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
    case SendGate.check(:fcm, :fcm) do
      :ok ->
        result = do_send_data(device_token, data, opts)
        SendGate.record(:fcm, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  defp do_send_data(device_token, data, opts) do
    message = %{
      "message" => %{
        "token" => device_token,
        "data" => HTTP.stringify_map(data)
      }
    }

    with {:ok, body} <- HTTP.safe_encode(message),
         :ok <- check_payload_size(body) do
      do_send_data_authenticated(device_token, body, opts)
    else
      {:error, reason} when is_binary(reason) ->
        {:error, Response.error(:fcm, :invalid_request, "Failed to encode payload: #{reason}")}

      {:error, %Response{} = response} ->
        {:error, response}
    end
  end

  defp do_send_data_authenticated(device_token, body, opts) do
    case get_access_token() do
      {:ok, access_token} ->
        project_id = Keyword.get(opts, :project_id, Config.fcm_project_id())
        url = URLs.fcm_send_url(project_id)

        headers = [
          {"authorization", "Bearer #{access_token}"},
          {"content-type", "application/json"}
        ]

        send_fcm_data_request(device_token, url, headers, body, opts)

      {:error, reason} ->
        Logger.error("[PushX.FCM] Failed to get OAuth token: #{inspect(reason)}")
        {:error, Response.error(:fcm, :connection_error, "OAuth token error: #{inspect(reason)}")}
    end
  end

  defp send_fcm_data_request(device_token, url, headers, body, opts) do
    Logger.debug(fn ->
      "[PushX.FCM] Sending data to #{Telemetry.truncate_token(device_token)}"
    end)

    Telemetry.start(:fcm, device_token)
    start_time = System.monotonic_time()

    try do
      request_opts =
        Keyword.merge(
          Config.finch_request_opts(),
          Keyword.take(opts, [:receive_timeout, :pool_timeout])
        )

      # HTTP.finch_request carries the shared NimblePool CaseClauseError
      # rescue, so pool-death errors surface as retryable connection errors.
      case HTTP.finch_request(
             Finch.build(:post, url, headers, body),
             Config.finch_name(),
             request_opts,
             "PushX.FCM"
           ) do
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

  # Private functions

  # FCM payload size limit per Google docs.
  @fcm_max_bytes 4096

  defp check_payload_size(body) do
    if byte_size(body) > @fcm_max_bytes do
      {:error,
       Response.error(
         :fcm,
         :payload_too_large,
         "Payload #{byte_size(body)} bytes exceeds FCM limit of #{@fcm_max_bytes}"
       )}
    else
      :ok
    end
  end

  @doc false
  # Public for tests only — builds the FCM v1 message envelope.
  def build_message(token, %Message{} = message, opts) do
    base =
      %{"token" => token}
      |> HTTP.maybe_put("notification", Message.to_fcm_payload(message)["notification"])
      |> HTTP.maybe_put("data", HTTP.stringify_map(Keyword.get(opts, :data) || message.data))
      |> HTTP.maybe_put("android", merge_android(message, Keyword.get(opts, :android)))
      |> HTTP.maybe_put("apns", Keyword.get(opts, :apns))
      |> HTTP.maybe_put("webpush", Keyword.get(opts, :webpush))

    %{"message" => base}
  end

  def build_message(token, payload, opts) when is_map(payload) do
    base = %{"token" => token}

    # Structured payload: has "notification" and/or "data" keys
    # Simple payload: treat entire map as notification (backwards compatible)
    base =
      cond do
        Map.has_key?(payload, "notification") or Map.has_key?(payload, "data") ->
          base
          |> HTTP.maybe_put("notification", payload["notification"])
          |> HTTP.maybe_put(
            "data",
            HTTP.stringify_map(Keyword.get(opts, :data) || payload["data"])
          )

        true ->
          Map.put(base, "notification", payload)
          |> HTTP.maybe_put("data", HTTP.stringify_map(Keyword.get(opts, :data)))
      end

    base
    |> HTTP.maybe_put("android", Keyword.get(opts, :android) || payload["android"])
    |> HTTP.maybe_put("apns", Keyword.get(opts, :apns) || payload["apns"])
    |> HTTP.maybe_put("webpush", Keyword.get(opts, :webpush) || payload["webpush"])
    |> then(&%{"message" => &1})
  end

  # Message delivery fields (priority/ttl/collapse_key) feed the android
  # block; keys given via opts win over struct-derived ones.
  defp merge_android(%Message{} = message, opts_android) do
    case {Message.to_fcm_android(message), opts_android} do
      {nil, opts_map} -> opts_map
      {msg_map, nil} -> msg_map
      {msg_map, opts_map} -> Map.merge(msg_map, opts_map)
    end
  end

  defp handle_error_response(status, body, response_headers) do
    {error_code, error_message} =
      case JSON.decode(body) do
        {:ok, %{"error" => %{"status" => code, "message" => msg}} = decoded} ->
          # Prefer FCM-specific errorCode from details over generic gRPC status
          {Response.extract_fcm_error_code(decoded) || code, msg}

        {:ok, %{"error" => %{"code" => code, "message" => msg}} = decoded} ->
          {Response.extract_fcm_error_code(decoded) || to_string(code), msg}

        _ ->
          {"UNKNOWN", "HTTP #{status}"}
      end

    error_status = Response.fcm_error_to_status(error_code)
    retry_after = HTTP.parse_retry_after(response_headers)

    Logger.warning("[PushX.FCM] Failed #{status}: #{error_code} - #{error_message}")
    {:error, Response.error(:fcm, error_status, error_message, body, retry_after)}
  end

  defp get_access_token do
    case Goth.fetch(PushX.Goth) do
      {:ok, %{token: token}} ->
        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
