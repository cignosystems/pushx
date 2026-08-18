defmodule PushX.APNS do
  @moduledoc """
  Apple Push Notification Service (APNS) client.

  Sends push notifications to iOS, macOS, watchOS, tvOS devices, and Safari
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

  ## Safari Web Push

  Safari uses APNS for web push notifications. The token format is the same
  as iOS (64 hex characters), but the topic uses a `web.` prefix:

      # Safari web push
      PushX.APNS.send(safari_token, payload, topic: "web.com.example.website")

      # Using web notification helper
      payload = PushX.APNS.web_notification("Title", "Body", "https://example.com/page")
      PushX.APNS.send(safari_token, payload, topic: "web.com.example.website")

  """

  require Logger

  alias PushX.{
    Config,
    HTTP,
    JWTCache,
    Message,
    Response,
    Retry,
    SendGate,
    Telemetry,
    URLs
  }

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
          | {:retry, :blocking | :none}

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
    * `:retry` - `:blocking` (default; retry with backoff in the calling process,
      subject to the `:retry_enabled` config) or `:none` (single attempt; a
      connection error still triggers the automatic pool reconnect). `true`/`false`
      are accepted as aliases. See `PushX.push/4`.

  ## Returns

    * `{:ok, %PushX.Response{}}` on success
    * `{:error, %PushX.Response{}}` on failure

  """
  @spec send(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send(device_token, payload, opts \\ []) do
    Retry.maybe_with_retry(:apns, opts, fn -> send_once(device_token, payload, opts) end)
  end

  @doc """
  Sends a push notification without retry.

  Use this when you want to handle retries yourself or for testing.
  """
  @spec send_once(token(), payload(), [option()]) :: {:ok, Response.t()} | {:error, Response.t()}
  def send_once(device_token, payload, opts \\ []) do
    case SendGate.check(:apns, :apns) do
      :ok ->
        result = do_send(device_token, payload, opts)
        SendGate.record(:apns, result)
        result

      {:error, %Response{}} = error ->
        error
    end
  end

  defp do_send(device_token, payload, opts) do
    opts = merge_message_options(payload, opts)
    mode = Keyword.get(opts, :mode, Config.apns_mode())

    cond do
      # Test delivery mode needs no credentials (see PushX.Test).
      not Config.apns_configured?() and not PushX.Test.active?() ->
        {:error,
         Response.error(
           :apns,
           :not_configured,
           "APNS is not configured: set :apns_key_id, :apns_team_id and :apns_private_key"
         )}

      mode not in [:prod, :sandbox] ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "Invalid :mode #{inspect(mode)} (expected :prod or :sandbox)"
         )}

      Keyword.get(opts, :topic) in [nil, ""] ->
        {:error, Response.error(:apns, :invalid_request, ":topic option is required")}

      not is_binary(device_token) ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "APNS delivers to device tokens only (topics/conditions are FCM features)"
         )}

      not safe_token?(device_token) ->
        {:error,
         Response.error(:apns, :invalid_token, "Device token contains invalid characters")}

      true ->
        # Validate the payload (encode + size) before acquiring a JWT, so an
        # oversized or un-encodable payload doesn't waste an ES256 signing.
        with {:ok, body} <- encode_payload_safe(payload),
             :ok <- check_payload_size(body, opts) do
          if PushX.Test.active?(),
            do: PushX.Test.deliver(:apns, device_token, body, opts, nil),
            else: do_send_authenticated(device_token, body, opts, mode)
        else
          {:error, reason} when is_binary(reason) ->
            {:error,
             Response.error(:apns, :invalid_request, "Failed to encode payload: #{reason}")}

          {:error, %Response{} = response} ->
            {:error, response}
        end
    end
  end

  # Apple reasons that mean the cached provider JWT itself is bad and a fresh
  # one may succeed. TooManyProviderTokenUpdates is deliberately excluded:
  # it means we're regenerating too often, so minting yet another JWT would
  # make it worse.
  @stale_jwt_reasons ["ExpiredProviderToken", "InvalidProviderToken", "MissingProviderToken"]

  defp do_send_authenticated(device_token, body, opts, mode, jwt_refreshed? \\ false) do
    topic = Keyword.fetch!(opts, :topic)

    case get_jwt() do
      {:ok, jwt} ->
        url = "#{base_url(mode)}/3/device/#{device_token}"
        headers = build_headers(jwt, topic, opts)

        case send_apns_request(device_token, url, headers, body, opts) do
          {:error, %Response{status: :auth_error, reason: reason}} = error
          when reason in @stale_jwt_reasons ->
            if jwt_refreshed? do
              error
            else
              Logger.warning(
                "[PushX.APNS] Apple rejected provider token (#{reason}); regenerating JWT and retrying once"
              )

              JWTCache.invalidate(:apns_jwt)
              do_send_authenticated(device_token, body, opts, mode, true)
            end

          result ->
            result
        end

      {:error, reason} ->
        {:error, Response.error(:apns, :auth_error, reason)}
    end
  end

  # Allows alphanumerics, underscore, and hyphen — covers Apple's hex tokens and
  # safe identifiers used in tests, while rejecting URL-special characters
  # (`/`, `?`, `#`, whitespace, etc.) that would alter request routing.
  @safe_token_regex ~r/\A[A-Za-z0-9_\-]+\z/

  defp safe_token?(token) when is_binary(token), do: Regex.match?(@safe_token_regex, token)

  defp send_apns_request(device_token, url, headers, body, opts) do
    Logger.debug(fn -> "[PushX.APNS] Sending to #{Telemetry.truncate_token(device_token)}" end)

    Telemetry.start(:apns, device_token)
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
             "PushX.APNS"
           ) do
        {:ok, %{status: 200, headers: response_headers}} ->
          apns_id = HTTP.get_header(response_headers, "apns-id")
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
          [{token(), {:ok, Response.t()} | {:error, Response.t()}}]
  def send_batch(device_tokens, payload, opts \\ []) do
    send_opts = Keyword.drop(opts, PushX.Batch.batch_option_keys())

    device_tokens
    |> PushX.Batch.stream(&send(&1, payload, send_opts), :apns, :apns, opts)
    |> Enum.to_list()
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
    |> Map.merge(Map.drop(data, ["aps", :aps]))
  end

  @doc """
  Creates a silent/background notification.
  """
  @spec silent_notification(map()) :: map()
  def silent_notification(data \\ %{}) do
    %{"aps" => %{"content-available" => 1}}
    |> Map.merge(Map.drop(data, ["aps", :aps]))
  end

  # Safari Web Push helpers

  @doc """
  Creates a Safari web push notification payload.

  Safari web push uses APNS with a slightly different payload format.
  The `url-args` field is used to pass URL arguments to the notification action.

  ## Arguments

    * `title` - Notification title
    * `body` - Notification body
    * `url` - URL to open when clicked (or URL arguments for Safari)
    * `opts` - Optional keyword list:
      * `:action` - Action button label (default: "View")
      * `:url_args` - List of URL arguments (overrides url parsing)

  ## Examples

      # Simple web notification
      PushX.APNS.web_notification("New Article", "Check out our latest post", "https://example.com/article/123")

      # With custom action
      PushX.APNS.web_notification("Sale!", "50% off today", "https://shop.com", action: "Shop Now")

      # With explicit URL args
      PushX.APNS.web_notification("Update", "New feature available", nil, url_args: ["features", "v2"])

  """
  @spec web_notification(String.t(), String.t(), String.t() | nil, keyword()) :: map()
  def web_notification(title, body, url \\ nil, opts \\ []) do
    action = Keyword.get(opts, :action, "View")

    url_args =
      case Keyword.get(opts, :url_args) do
        nil when is_binary(url) -> parse_url_args(url)
        nil -> []
        args when is_list(args) -> args
      end

    %{
      "aps" => %{
        "alert" => %{
          "title" => title,
          "body" => body,
          "action" => action
        },
        "url-args" => url_args
      }
    }
  end

  @doc """
  Creates a Safari web push notification with custom data.

  ## Examples

      PushX.APNS.web_notification_with_data(
        "Order Shipped",
        "Your order #123 is on its way",
        "https://example.com/orders/123",
        %{"order_id" => "123"}
      )

  """
  @spec web_notification_with_data(String.t(), String.t(), String.t() | nil, map(), keyword()) ::
          map()
  def web_notification_with_data(title, body, url, data, opts \\ []) do
    web_notification(title, body, url, opts)
    |> Map.merge(Map.drop(data, ["aps", :aps]))
  end

  defp parse_url_args(url) when is_binary(url) do
    uri = URI.parse(url)

    # Extract path segments (excluding empty ones)
    path_args =
      (uri.path || "")
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))

    # Extract query params as key=value strings
    query_args =
      case uri.query do
        nil -> []
        query -> URI.decode_query(query) |> Enum.map(fn {k, v} -> "#{k}=#{v}" end)
      end

    path_args ++ query_args
  end

  # Private functions

  defp base_url(mode), do: URLs.apns(mode)

  @doc false
  # Shared with PushX.Instance so header rules can't drift between paths.
  def build_headers(jwt, topic, opts) do
    push_type = Keyword.get(opts, :push_type, "alert")

    [
      {"authorization", "bearer #{jwt}"},
      {"apns-topic", topic},
      {"apns-push-type", push_type},
      {"apns-priority", to_string(Keyword.get(opts, :priority, default_priority(push_type)))}
    ]
    |> HTTP.maybe_add_header("apns-expiration", Keyword.get(opts, :expiration))
    |> HTTP.maybe_add_header("apns-collapse-id", Keyword.get(opts, :collapse_id))
  end

  # Apple requires apns-priority 5 for background pushes — 10 is rejected
  # (or the push is throttled/ignored). Explicit :priority always wins.
  defp default_priority("background"), do: 5
  defp default_priority(_push_type), do: 10

  # Message delivery fields (priority/ttl/collapse_key) become send options;
  # explicit call-site opts win over struct-derived ones.
  defp merge_message_options(%Message{} = message, opts),
    do: Keyword.merge(Message.to_apns_options(message), opts)

  defp merge_message_options(_payload, opts), do: opts

  defp encode_payload_safe(%Message{} = message),
    do: HTTP.safe_encode(Message.to_apns_payload(message))

  defp encode_payload_safe(payload) when is_map(payload), do: HTTP.safe_encode(payload)

  # APNS payload size limits per Apple docs.
  @apns_alert_max_bytes 4096
  @apns_voip_max_bytes 5120

  defp check_payload_size(body, opts) do
    push_type = Keyword.get(opts, :push_type, "alert")
    max_bytes = if push_type == "voip", do: @apns_voip_max_bytes, else: @apns_alert_max_bytes

    if byte_size(body) > max_bytes do
      {:error,
       Response.error(
         :apns,
         :payload_too_large,
         "Payload #{byte_size(body)} bytes exceeds APNS limit of #{max_bytes}"
       )}
    else
      :ok
    end
  end

  defp handle_error_response(status, body, response_headers) do
    reason =
      case JSON.decode(body) do
        {:ok, %{"reason" => reason}} -> reason
        _ -> "HTTP #{status}"
      end

    error_status = Response.apns_reason_to_status(reason)
    retry_after = HTTP.parse_retry_after(response_headers)

    Logger.warning("[PushX.APNS] Failed #{status}: #{reason}")
    {:error, Response.error(:apns, error_status, reason, body, retry_after)}
  end

  # JWT Token Management — cached via PushX.JWTCache (GenServer-backed,
  # cannot deadlock if a refresher is killed mid-generation).

  defp get_jwt do
    JWTCache.get_or_generate(:apns_jwt, &generate_jwt/0, @jwt_cache_ttl_ms)
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
        {:ok, token}

      {:error, reason} ->
        Logger.error("[PushX.APNS] JWT generation failed: #{inspect(reason)}")
        {:error, "JWT generation failed: #{inspect(reason)}"}
    end
  rescue
    # A malformed PEM makes JOSE raise (badarg) instead of returning an error
    # tuple; surface it as the documented error so the caller and the shared
    # JWTCache never crash on a misconfigured credential.
    e ->
      Logger.error("[PushX.APNS] JWT generation raised: #{Exception.message(e)}")
      {:error, "JWT generation failed: #{Exception.message(e)}"}
  end
end
