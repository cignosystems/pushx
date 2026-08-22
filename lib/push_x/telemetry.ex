defmodule PushX.Telemetry do
  @moduledoc since: "0.3.0"
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

  With the optional `telemetry_metrics` dependency, `metrics/0` returns a
  ready-made, low-cardinality metric list you can hand to any reporter
  (`Telemetry.Metrics.ConsoleReporter`, `TelemetryMetricsPrometheus`, PromEx,
  `Phoenix.LiveDashboard`):

      # mix.exs
      {:telemetry_metrics, "~> 1.0"}

      # your telemetry supervisor / LiveDashboard metrics module
      def metrics, do: MyApp.metrics() ++ PushX.Telemetry.metrics()

  See `metrics/0` for the list; roll your own from the events above if you
  need different tags or buckets.
  """

  if Code.ensure_loaded?(Telemetry.Metrics) do
    @doc """
    A ready-made `Telemetry.Metrics` list for PushX (requires the optional
    `telemetry_metrics` dependency).

    Deliberately low-cardinality — device tokens are never a tag:

      * `pushx.push.sent.count` — successful sends, by `provider`
      * `pushx.push.error.count` — failed sends, by `provider` and `status`
        (`:invalid_token`, `:rate_limited`, `:server_error`, ...)
      * `pushx.push.exception.count` — sends that raised, by `provider` and `kind`
      * `pushx.push.duration` — latency distribution of *successful* sends in
        milliseconds, by `provider`; buckets tuned for provider round-trips
        (5 ms .. 10 s)
      * `pushx.push.error.duration` — latency distribution of *failed* sends
        (timeouts and 5xx land here — alert on this one for provider
        slowdowns), by `provider` and `status`; same buckets
      * `pushx.retry.attempt.count` — retry attempts, by `provider` and the
        `status` that triggered them
      * `pushx.retry.delay` — backoff delay distribution in milliseconds, by `provider`

    Metric names are the events' names with the measurement appended, so they
    line up with `PushX.Telemetry`'s documented events.
    """
    @doc since: "0.14.0"
    @spec metrics() :: [Telemetry.Metrics.t()]
    def metrics do
      import Telemetry.Metrics

      latency_buckets = [5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

      [
        # Counters are bound to a measurement that exists in the event so every
        # reporter counts them (some skip metrics whose measurement is absent).
        counter("pushx.push.sent.count",
          event_name: [:pushx, :push, :stop],
          measurement: :duration,
          tags: [:provider],
          description: "Pushes accepted by the provider"
        ),
        counter("pushx.push.error.count",
          event_name: [:pushx, :push, :error],
          measurement: :duration,
          tags: [:provider, :status],
          description: "Pushes that failed, by response status"
        ),
        counter("pushx.push.exception.count",
          event_name: [:pushx, :push, :exception],
          measurement: :duration,
          tags: [:provider, :kind],
          description: "Sends that raised an exception"
        ),
        distribution("pushx.push.duration",
          event_name: [:pushx, :push, :stop],
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:provider],
          description: "Send latency (successful sends)",
          reporter_options: [buckets: latency_buckets]
        ),
        distribution("pushx.push.error.duration",
          event_name: [:pushx, :push, :error],
          measurement: :duration,
          unit: {:native, :millisecond},
          tags: [:provider, :status],
          description: "Send latency (failed sends)",
          reporter_options: [buckets: latency_buckets]
        ),
        counter("pushx.retry.attempt.count",
          event_name: [:pushx, :retry, :attempt],
          measurement: :attempt,
          tags: [:provider, :status],
          description: "Retry attempts, by the status that triggered them"
        ),
        distribution("pushx.retry.delay",
          event_name: [:pushx, :retry, :attempt],
          measurement: :delay_ms,
          unit: :millisecond,
          tags: [:provider],
          description: "Backoff delay before a retry",
          reporter_options: [buckets: [1_000, 5_000, 10_000, 20_000, 40_000, 60_000]]
        )
      ]
    end
  end

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
  @doc since: "0.14.0"
  @spec truncate_token(String.t()) :: String.t()
  def truncate_token(token) when is_binary(token) and byte_size(token) > 16 do
    first = binary_part(token, 0, 8)
    last = binary_part(token, byte_size(token) - 4, 4)
    "#{first}...#{last}"
  end

  def truncate_token(%{} = subscription) do
    endpoint = Map.get(subscription, :endpoint) || Map.get(subscription, "endpoint")
    "endpoint:" <> truncate_token(to_string(endpoint))
  end

  def truncate_token({:topic, name}), do: "topic:" <> truncate_token(name)
  def truncate_token({:condition, expr}), do: "condition:" <> truncate_token(expr)
  def truncate_token(token), do: token
end
