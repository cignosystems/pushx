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
  @typedoc """
  Where an FCM message goes: a device registration token, a topic
  (`{:topic, "news"}` — the name only, without the `/topics/` prefix), or a
  condition (`{:condition, "'news' in topics && 'sports' in topics"}`).
  Topics and conditions fan out server-side, so `PushX.Response` carries no
  per-device information for them and `should_remove_token?/1` is never true.
  """
  @type target :: token() | {:topic, String.t()} | {:condition, String.t()}
  @type payload :: map() | Message.t()
  @type option ::
          {:project_id, String.t()}
          | {:data, map()}
          | {:android, map()}
          | {:apns, map()}
          | {:webpush, map()}
          | {:retry, :blocking | :none}

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
    * `:retry` - `:blocking` (default) or `:none` (single attempt); see `PushX.push/4`

  ## Returns

    * `{:ok, %PushX.Response{}}` on success
    * `{:error, %PushX.Response{}}` on failure

  """
  @spec send(target(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send(device_token, payload, opts \\ []) do
    Retry.maybe_with_retry(:fcm, opts, fn -> send_once(device_token, payload, opts) end)
  end

  @doc """
  Sends a push notification without retry.

  Use this when you want to handle retries yourself or for testing.
  """
  @spec send_once(target(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
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
    # Validate the target and payload (encode + size) before requesting an
    # OAuth token.
    with :ok <- validate_target(device_token),
         message = build_message(device_token, payload, opts),
         {:ok, body} <- HTTP.safe_encode(message),
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
    with {:ok, project_id} <- resolve_project_id(opts),
         {:ok, access_token} <- get_access_token() do
      url = URLs.fcm_send_url(project_id)

      headers = [
        {"authorization", "Bearer #{access_token}"},
        {"content-type", "application/json"}
      ]

      send_fcm_request(device_token, url, headers, body, opts)
    else
      {:error, %Response{} = response} -> {:error, response}
      {:error, reason} -> oauth_error_response(reason)
    end
  end

  # The static path needs a project id from the call or the config; without
  # one there is nothing to send to, and Config.fcm_project_id/0 would raise.
  defp resolve_project_id(opts) do
    case Keyword.get(opts, :project_id) || Config.get(:fcm_project_id) do
      nil ->
        {:error,
         Response.error(
           :fcm,
           :not_configured,
           "FCM is not configured: set :fcm_project_id (and :fcm_credentials or :fcm_token_fetcher)"
         )}

      project_id ->
        {:ok, project_id}
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
    * `:timeout` - Timeout per request in ms (default:
      `PushX.Config.batch_timeout_ms/0`, sized to the worst-case retry backoff)
    * `:validate_tokens` - Validate token format before sending (default: false).
      Invalid tokens get `{:error, %Response{status: :invalid_token}}` without
      hitting the network.

  Each task runs the full blocking retry cycle; if you pass an explicit
  `:timeout`, make sure it exceeds the worst-case retry backoff or disable
  retries — see `PushX.push_batch/4` for details.

  ## Returns

  A list of `{token, result}` tuples.
  """
  @spec send_batch(Enumerable.t(), payload(), [option()]) ::
          [{target(), {:ok, Response.t()} | {:error, Response.t()}}]
  def send_batch(device_tokens, payload, opts \\ []) do
    send_opts = Keyword.drop(opts, PushX.Batch.batch_option_keys())

    device_tokens
    |> PushX.Batch.stream(&send(&1, payload, send_opts), :fcm, :fcm, opts)
    |> Enum.to_list()
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
  @spec send_data(target(), map(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_data(device_token, data, opts \\ []) do
    Retry.maybe_with_retry(:fcm, opts, fn -> send_data_once(device_token, data, opts) end)
  end

  @doc """
  Sends a data-only message without retry.
  """
  @spec send_data_once(target(), map(), [option()]) ::
          {:ok, Response.t()} | {:error, Response.t()}
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
    with :ok <- validate_target(device_token),
         message = %{
           "message" => Map.put(target_field(device_token), "data", HTTP.stringify_map(data))
         },
         {:ok, body} <- HTTP.safe_encode(message),
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
    with {:ok, project_id} <- resolve_project_id(opts),
         {:ok, access_token} <- get_access_token() do
      url = URLs.fcm_send_url(project_id)

      headers = [
        {"authorization", "Bearer #{access_token}"},
        {"content-type", "application/json"}
      ]

      send_fcm_data_request(device_token, url, headers, body, opts)
    else
      {:error, %Response{} = response} -> {:error, response}
      {:error, reason} -> oauth_error_response(reason)
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
      target_field(token)
      |> HTTP.maybe_put("notification", Message.to_fcm_payload(message)["notification"])
      |> HTTP.maybe_put("data", HTTP.stringify_map(Keyword.get(opts, :data) || message.data))
      |> HTTP.maybe_put("android", merge_android(message, Keyword.get(opts, :android)))
      |> HTTP.maybe_put("apns", Keyword.get(opts, :apns))
      |> HTTP.maybe_put("webpush", Keyword.get(opts, :webpush))

    %{"message" => base}
  end

  def build_message(token, payload, opts) when is_map(payload) do
    base = target_field(token)

    # Structured payload: has "notification" and/or "data" keys
    # Simple payload: treat entire map as notification (backwards compatible)
    base =
      if Map.has_key?(payload, "notification") or Map.has_key?(payload, "data") do
        base
        |> HTTP.maybe_put("notification", payload["notification"])
        |> HTTP.maybe_put(
          "data",
          HTTP.stringify_map(Keyword.get(opts, :data) || payload["data"])
        )
      else
        base
        |> Map.put("notification", payload)
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
  # FCM v1 target selector: exactly one of token / topic / condition.
  defp target_field({:topic, name}), do: %{"topic" => name}
  defp target_field({:condition, expr}), do: %{"condition" => expr}
  defp target_field(token), do: %{"token" => token}

  # https://firebase.google.com/docs/cloud-messaging/send-message#send_messages_to_topics
  @topic_regex ~r/\A[a-zA-Z0-9\-_.~%]+\z/

  @doc false
  # Shared with PushX.Instance so target rules cannot drift between paths.
  @spec validate_target(term()) :: :ok | {:error, Response.t()}
  def validate_target(token) when is_binary(token) and token != "", do: :ok

  def validate_target({:topic, name}) when is_binary(name) do
    if Regex.match?(@topic_regex, name) do
      :ok
    else
      {:error,
       Response.error(
         :fcm,
         :invalid_request,
         "Invalid FCM topic #{inspect(name)}: use the bare name (no /topics/ prefix), " <>
           "characters [a-zA-Z0-9-_.~%] only"
       )}
    end
  end

  def validate_target({:condition, expr}) when is_binary(expr) and expr != "", do: :ok

  def validate_target(other) do
    {:error,
     Response.error(
       :fcm,
       :invalid_request,
       "Invalid FCM target #{inspect(other)}: expected a device token, {:topic, name} or {:condition, expr}"
     )}
  end

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

  defp get_access_token, do: fetch_access_token(PushX.Goth, Config.fcm_token_fetcher())

  @doc false
  # Shared by the static path and PushX.Instance so the OAuth token source
  # (a caller-supplied fetcher, or Goth) cannot drift between them.
  #
  # `fetcher` is nil (use the Goth process registered as `goth_name`) or an
  # `{module, function, args}` tuple invoked as `apply(m, f, [goth_name | args])`.
  # The static path passes `Config.fcm_token_fetcher/0`; a named instance
  # passes its own `:token_fetcher` config — a global fetcher never applies to
  # instances, whose credentials are their own.
  @spec fetch_access_token(atom(), {module(), atom(), list()} | nil) ::
          {:ok, String.t()} | {:error, term()}
  def fetch_access_token(goth_name, fetcher)

  def fetch_access_token(goth_name, nil) do
    case goth_fetch(goth_name) do
      {:ok, %{token: token}} -> {:ok, token}
      {:error, reason} -> {:error, reason}
    end
  end

  def fetch_access_token(goth_name, {mod, fun, args})
      when is_atom(mod) and is_atom(fun) and is_list(args) do
    # A caller-supplied fetcher is untrusted code on the send path: never let
    # a raise/exit or an unexpected return shape escape the {:error, %Response{}}
    # contract.
    case apply(mod, fun, [goth_name | args]) do
      {:ok, %{token: token}} when is_binary(token) and token != "" -> {:ok, token}
      {:error, reason} -> {:error, {:fetcher_error, reason}}
      other -> {:error, {:bad_fetcher_return, other}}
    end
  rescue
    e -> {:error, {:fetcher_raised, Exception.message(e)}}
  catch
    kind, reason -> {:error, {:fetcher_exit, {kind, reason}}}
  end

  # Goth.fetch/1 is a GenServer.call: when no Goth process exists it *exits*
  # the caller with :noproc. Convert that into an error tuple so the
  # documented {:error, %Response{}} contract holds instead of crashing.
  defp goth_fetch(goth_name) do
    Goth.fetch(goth_name)
  catch
    :exit, {:noproc, _} -> {:error, {:oauth_not_running, goth_name}}
  end

  @doc false
  # Shared by the static and instance paths: maps an OAuth fetch failure to
  # the right response.
  #
  #   * no Goth process *and* no credentials configured — the static PushX.Goth
  #     was never started: a deployment problem → :not_configured, never retried
  #   * no Goth process but credentials are configured (Goth crashed/restarting,
  #     or an instance's Goth child is mid-restart) → :connection_error, retryable
  #   * a caller-supplied fetcher raised/exited/returned {:error, _} → its OAuth
  #     infrastructure is down → :connection_error, retryable
  #   * a caller-supplied fetcher returned the wrong shape → programming
  #     error → :auth_error, not retried
  #   * anything else (Goth returned {:error, exception}: token endpoint 5xx,
  #     bad credentials rejected by Google...) → :connection_error, retryable
  @spec oauth_error_response(term()) :: {:error, Response.t()}
  def oauth_error_response({:oauth_not_running, PushX.Goth = goth_name}) do
    if Config.fcm_credentials_configured?() do
      transient_oauth_outage(goth_name)
    else
      Logger.error(
        "[PushX.FCM] OAuth process #{inspect(goth_name)} is not running — is FCM configured (:fcm_project_id and :fcm_credentials, or :fcm_token_fetcher)?"
      )

      {:error,
       Response.error(
         :fcm,
         :not_configured,
         "FCM is not configured: OAuth process #{inspect(goth_name)} is not running"
       )}
    end
  end

  def oauth_error_response({:oauth_not_running, goth_name}), do: transient_oauth_outage(goth_name)

  def oauth_error_response({:bad_fetcher_return, other}) do
    Logger.error(
      "[PushX.FCM] :fcm_token_fetcher returned #{inspect(other)}; expected {:ok, %{token: binary}} or {:error, reason}"
    )

    {:error,
     Response.error(
       :fcm,
       :auth_error,
       "OAuth token fetcher returned an unexpected value: #{inspect(other)}"
     )}
  end

  def oauth_error_response(reason) do
    Logger.error("[PushX.FCM] Failed to get OAuth token: #{inspect(reason)}")
    {:error, Response.error(:fcm, :connection_error, "OAuth token error: #{inspect(reason)}")}
  end

  defp transient_oauth_outage(goth_name) do
    Logger.error(
      "[PushX.FCM] OAuth process #{inspect(goth_name)} is not running (crashed or restarting); treating as a transient connection error"
    )

    {:error,
     Response.error(
       :fcm,
       :connection_error,
       "OAuth process #{inspect(goth_name)} is not running (restarting?)"
     )}
  end
end
