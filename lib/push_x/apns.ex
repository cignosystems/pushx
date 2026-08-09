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
    CircuitBreaker,
    Config,
    HTTP,
    JWTCache,
    Message,
    RateLimiter,
    Response,
    Retry,
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
    with :ok <- CircuitBreaker.allow?(:apns),
         :ok <- RateLimiter.check_and_increment(:apns) do
      result = do_send(device_token, payload, opts)
      record_circuit_breaker_result(result)
      result
    else
      {:error, :circuit_open} ->
        {:error, Response.error(:apns, :circuit_open, "Circuit breaker is open")}

      {:error, :rate_limited} ->
        {:error, Response.error(:apns, :rate_limited, "Client-side rate limit exceeded")}
    end
  end

  defp do_send(device_token, payload, opts) do
    mode = Keyword.get(opts, :mode, Config.apns_mode())

    cond do
      mode not in [:prod, :sandbox] ->
        {:error,
         Response.error(
           :apns,
           :invalid_request,
           "Invalid :mode #{inspect(mode)} (expected :prod or :sandbox)"
         )}

      Keyword.get(opts, :topic) in [nil, ""] ->
        {:error, Response.error(:apns, :invalid_request, ":topic option is required")}

      not safe_token?(device_token) ->
        {:error,
         Response.error(:apns, :invalid_token, "Device token contains invalid characters")}

      true ->
        # Validate the payload (encode + size) before acquiring a JWT, so an
        # oversized or un-encodable payload doesn't waste an ES256 signing.
        with {:ok, body} <- encode_payload_safe(payload),
             :ok <- check_payload_size(body, opts) do
          do_send_authenticated(device_token, body, opts, mode)
        else
          {:error, reason} when is_binary(reason) ->
            {:error,
             Response.error(:apns, :invalid_request, "Failed to encode payload: #{reason}")}

          {:error, %Response{} = response} ->
            {:error, response}
        end
    end
  end

  defp do_send_authenticated(device_token, body, opts, mode) do
    topic = Keyword.fetch!(opts, :topic)

    case get_jwt() do
      {:ok, jwt} ->
        url = "#{base_url(mode)}/3/device/#{device_token}"
        headers = build_headers(jwt, topic, opts)
        send_apns_request(device_token, url, headers, body, opts)

      {:error, reason} ->
        {:error, Response.error(:apns, :auth_error, reason)}
    end
  end

  # Allows alphanumerics, underscore, and hyphen — covers Apple's hex tokens and
  # safe identifiers used in tests, while rejecting URL-special characters
  # (`/`, `?`, `#`, whitespace, etc.) that would alter request routing.
  @safe_token_regex ~r/\A[A-Za-z0-9_\-]+\z/

  defp safe_token?(token) when is_binary(token), do: Regex.match?(@safe_token_regex, token)
  defp safe_token?(_), do: false

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

      case Finch.build(:post, url, headers, body)
           |> Finch.request(Config.finch_name(), request_opts) do
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
      e in CaseClauseError ->
        # Finch's outer case (lib/finch.ex:516) only matches `{:ok, …}` or
        # the 3-tuple `{:error, err, _acc}` shape. When NimblePool returns
        # the 2-tuple shape — `{:error, :connection_process_went_down}` is
        # the one we've seen in the wild, but the same machinery could
        # return other atom reasons — Finch raises CaseClauseError on
        # itself. Treat any 2-tuple error term as a retryable connection
        # error so PushX.Retry can recover; reraise everything else so
        # actual programming bugs still surface.
        case e do
          %CaseClauseError{term: {:error, reason}} when is_atom(reason) ->
            Logger.error(
              "[PushX.APNS] Finch connection error (#{inspect(reason)}) — likely concurrent request limit / pool process death"
            )

            response = Response.error(:apns, :connection_error, Atom.to_string(reason))
            Telemetry.error(:apns, device_token, start_time, response)
            {:error, response}

          _other ->
            Telemetry.exception(:apns, device_token, start_time, :error, e, __STACKTRACE__)
            reraise e, __STACKTRACE__
        end

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
    * `:timeout` - Timeout per request in ms (default: 30_000)
    * `:validate_tokens` - Validate token format before sending (default: false).
      Invalid tokens get `{:error, %Response{status: :invalid_token}}` without
      hitting the network.

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

    device_tokens
    |> Task.async_stream(
      fn token ->
        if validate and not PushX.Token.valid?(:apns, token) do
          {token, {:error, Response.error(:apns, :invalid_token, "Invalid token format")}}
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
        {token, {:error, Response.error(:apns, :connection_error, "timeout")}}
    end)
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

  defp record_circuit_breaker_result({:error, %Response{status: status}})
       when status in [:connection_error, :server_error] do
    CircuitBreaker.record_failure(:apns)
  end

  defp record_circuit_breaker_result({:ok, _response}) do
    CircuitBreaker.record_success(:apns)
  end

  defp record_circuit_breaker_result(_), do: :ok

  defp base_url(mode), do: URLs.apns(mode)

  defp build_headers(jwt, topic, opts) do
    [
      {"authorization", "bearer #{jwt}"},
      {"apns-topic", topic},
      {"apns-push-type", Keyword.get(opts, :push_type, "alert")},
      {"apns-priority", to_string(Keyword.get(opts, :priority, 10))}
    ]
    |> HTTP.maybe_add_header("apns-expiration", Keyword.get(opts, :expiration))
    |> HTTP.maybe_add_header("apns-collapse-id", Keyword.get(opts, :collapse_id))
  end

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
