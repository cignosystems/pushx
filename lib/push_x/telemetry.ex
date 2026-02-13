defmodule PushX.Telemetry do
  @moduledoc """
  Telemetry integration for PushX.

  PushX emits the following telemetry events:

  ## Events

  ### `[:pushx, :push, :start]`

  Emitted when a push notification request starts.

  **Measurements:** `%{system_time: integer}`
  **Metadata:**
    * `:provider` - `:apns` or `:fcm`
    * `:token` - Device token (truncated for privacy)

  ### `[:pushx, :push, :stop]`

  Emitted when a push notification request completes successfully.

  **Measurements:** `%{duration: integer}` (in native time units)
  **Metadata:**
    * `:provider` - `:apns` or `:fcm`
    * `:token` - Device token (truncated)
    * `:status` - `:sent`
    * `:id` - Provider message ID (if available)

  ### `[:pushx, :push, :exception]`

  Emitted when a push notification request raises an exception.

  **Measurements:** `%{duration: integer}`
  **Metadata:**
    * `:provider` - `:apns` or `:fcm`
    * `:token` - Device token (truncated)
    * `:kind` - Exception kind (`:error`, `:exit`, `:throw`)
    * `:reason` - Exception reason
    * `:stacktrace` - Exception stacktrace

  ### `[:pushx, :push, :error]`

  Emitted when a push notification request returns an error response.

  **Measurements:** `%{duration: integer}`
  **Metadata:**
    * `:provider` - `:apns` or `:fcm`
    * `:token` - Device token (truncated)
    * `:status` - Error status (e.g., `:invalid_token`, `:rate_limited`)
    * `:reason` - Error reason string

  ### `[:pushx, :retry, :attempt]`

  Emitted when a retry attempt is made.

  **Measurements:** `%{delay_ms: integer, attempt: integer}`
  **Metadata:**
    * `:provider` - `:apns` or `:fcm`
    * `:status` - The error status that triggered the retry

  ## Example Usage

  Attach a handler in your application startup:

      :telemetry.attach_many(
        "pushx-logger",
        [
          [:pushx, :push, :start],
          [:pushx, :push, :stop],
          [:pushx, :push, :error],
          [:pushx, :push, :exception]
        ],
        &MyApp.PushXTelemetry.handle_event/4,
        nil
      )

  Example handler:

      defmodule MyApp.PushXTelemetry do
        require Logger

        def handle_event([:pushx, :push, :stop], %{duration: duration}, metadata, _config) do
          duration_ms = System.convert_time_unit(duration, :native, :millisecond)
          Logger.info("Push sent to \#{metadata.provider} in \#{duration_ms}ms")
        end

        def handle_event([:pushx, :push, :error], _measurements, metadata, _config) do
          Logger.warning("Push failed: \#{metadata.status} - \#{metadata.reason}")
        end

        def handle_event(_event, _measurements, _metadata, _config), do: :ok
      end

  ## Metrics with Telemetry.Metrics

      defmodule MyApp.Telemetry do
        import Telemetry.Metrics

        def metrics do
          [
            counter("pushx.push.stop.count", tags: [:provider]),
            counter("pushx.push.error.count", tags: [:provider, :status]),
            distribution("pushx.push.stop.duration",
              unit: {:native, :millisecond},
              tags: [:provider]
            )
          ]
        end
      end

  """

  @doc false
  def start(provider, token) do
    :telemetry.execute(
      [:pushx, :push, :start],
      %{system_time: System.system_time()},
      %{provider: provider, token: truncate_token(token)}
    )
  end

  @doc false
  def stop(provider, token, start_time, response) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:pushx, :push, :stop],
      %{duration: duration},
      %{
        provider: provider,
        token: truncate_token(token),
        status: response.status,
        id: response.id
      }
    )
  end

  @doc false
  def error(provider, token, start_time, response) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:pushx, :push, :error],
      %{duration: duration},
      %{
        provider: provider,
        token: truncate_token(token),
        status: response.status,
        reason: response.reason
      }
    )
  end

  @doc false
  def exception(provider, token, start_time, kind, reason, stacktrace) do
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:pushx, :push, :exception],
      %{duration: duration},
      %{
        provider: provider,
        token: truncate_token(token),
        kind: kind,
        reason: reason,
        stacktrace: stacktrace
      }
    )
  end

  @doc false
  def retry_attempt(provider, status, attempt, delay_ms) do
    :telemetry.execute(
      [:pushx, :retry, :attempt],
      %{delay_ms: delay_ms, attempt: attempt},
      %{provider: provider, status: status}
    )
  end

  @doc """
  Truncates a device token for privacy-safe logging.

  Shows first 8 and last 4 characters, replacing the middle with `...`.
  Returns the token unchanged if it is 16 characters or shorter.

  ## Examples

      iex> PushX.Telemetry.truncate_token("abcdefgh12345678ijklmnop")
      "abcdefgh...mnop"

      iex> PushX.Telemetry.truncate_token("short")
      "short"

  """
  @spec truncate_token(String.t()) :: String.t()
  def truncate_token(token) when is_binary(token) and byte_size(token) > 16 do
    first = binary_part(token, 0, 8)
    last = binary_part(token, byte_size(token) - 4, 4)
    "#{first}...#{last}"
  end

  def truncate_token(token), do: token
end
