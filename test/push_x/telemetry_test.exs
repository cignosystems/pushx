defmodule PushX.TelemetryTest do
  use ExUnit.Case

  alias Elixir.Telemetry.Metrics.ConsoleReporter
  alias PushX.{Response, Telemetry}

  doctest PushX.Telemetry

  setup do
    # Attach telemetry handlers for testing
    test_pid = self()

    :telemetry.attach_many(
      "test-handler-#{inspect(self())}",
      [
        [:pushx, :push, :start],
        [:pushx, :push, :stop],
        [:pushx, :push, :error],
        [:pushx, :push, :exception],
        [:pushx, :retry, :attempt]
      ],
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn ->
      :telemetry.detach("test-handler-#{inspect(self())}")
    end)

    :ok
  end

  describe "start/2" do
    test "emits start event with truncated token" do
      token = "abc123456789012345678901234567890xyz"
      Telemetry.start(:apns, token)

      assert_receive {:telemetry_event, [:pushx, :push, :start], measurements, metadata}
      assert is_integer(measurements.system_time)
      assert metadata.provider == :apns
      # First 8 chars + "..." + last 4 chars
      assert metadata.token == "abc12345...0xyz"
    end

    test "preserves short tokens" do
      token = "short"
      Telemetry.start(:fcm, token)

      assert_receive {:telemetry_event, [:pushx, :push, :start], _measurements, metadata}
      assert metadata.token == "short"
    end
  end

  describe "stop/4" do
    test "emits stop event with duration and response data" do
      token = "test-token-12345678901234567890"
      start_time = System.monotonic_time()
      response = Response.success(:apns, "apns-id-123")

      # Small delay to ensure measurable duration
      Process.sleep(1)

      Telemetry.stop(:apns, token, start_time, response)

      assert_receive {:telemetry_event, [:pushx, :push, :stop], measurements, metadata}
      assert is_integer(measurements.duration)
      assert measurements.duration > 0
      assert metadata.provider == :apns
      assert metadata.status == :sent
      assert metadata.id == "apns-id-123"
    end
  end

  describe "error/4" do
    test "emits error event with status and reason" do
      token = "test-token-12345678901234567890"
      start_time = System.monotonic_time()
      response = Response.error(:fcm, :invalid_token, "Bad token")

      Telemetry.error(:fcm, token, start_time, response)

      assert_receive {:telemetry_event, [:pushx, :push, :error], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.provider == :fcm
      assert metadata.status == :invalid_token
      assert metadata.reason == "Bad token"
    end
  end

  describe "exception/6" do
    test "emits exception event with error details" do
      token = "test-token-12345678901234567890"
      start_time = System.monotonic_time()
      error = %RuntimeError{message: "test error"}
      stacktrace = [{__MODULE__, :test, 0, []}]

      Telemetry.exception(:apns, token, start_time, :error, error, stacktrace)

      assert_receive {:telemetry_event, [:pushx, :push, :exception], measurements, metadata}
      assert is_integer(measurements.duration)
      assert metadata.provider == :apns
      assert metadata.kind == :error
      assert metadata.reason == error
      assert metadata.stacktrace == stacktrace
    end
  end

  describe "truncate_token/1" do
    test "truncates long tokens" do
      token = String.duplicate("a", 64)
      assert Telemetry.truncate_token(token) == "aaaaaaaa...aaaa"
    end

    test "returns short tokens unchanged" do
      assert Telemetry.truncate_token("short") == "short"
    end

    test "returns 16-char tokens unchanged" do
      token = String.duplicate("a", 16)
      assert Telemetry.truncate_token(token) == token
    end

    test "truncates 17-char tokens" do
      token = "abcdefghijklmnopq"
      assert Telemetry.truncate_token(token) == "abcdefgh...nopq"
    end
  end

  describe "retry_attempt/4" do
    test "emits retry attempt event" do
      Telemetry.retry_attempt(:apns, :rate_limited, 2, 20_000)

      assert_receive {:telemetry_event, [:pushx, :retry, :attempt], measurements, metadata}
      assert measurements.delay_ms == 20_000
      assert measurements.attempt == 2
      assert metadata.provider == :apns
      assert metadata.status == :rate_limited
    end
  end

  describe "truncate_token/1 with FCM targets" do
    test "labels topics and conditions instead of treating them as tokens" do
      assert PushX.Telemetry.truncate_token({:topic, "news"}) == "topic:news"

      assert PushX.Telemetry.truncate_token({:condition, "'a' in topics && 'b' in topics"}) ==
               "condition:'a' in t...pics"
    end
  end

  describe "metrics/0" do
    test "returns Telemetry.Metrics definitions bound to the documented events, never tagged by token" do
      metrics = PushX.Telemetry.metrics()
      assert length(metrics) == 7

      for m <- metrics do
        assert m.event_name in [
                 [:pushx, :push, :stop],
                 [:pushx, :push, :error],
                 [:pushx, :push, :exception],
                 [:pushx, :retry, :attempt]
               ]

        refute :token in m.tags
        assert m.description != nil
      end

      names = Enum.map(metrics, &Enum.join(&1.name, "."))
      assert "pushx.push.sent.count" in names
      assert "pushx.push.error.count" in names
      assert "pushx.push.duration" in names
      assert "pushx.retry.attempt.count" in names

      duration = Enum.find(metrics, &(Enum.join(&1.name, ".") == "pushx.push.duration"))
      assert %Elixir.Telemetry.Metrics.Distribution{unit: :millisecond} = duration
      assert duration.reporter_options[:buckets] != nil
    end

    test "the metrics actually fire from real events (ConsoleReporter smoke test)" do
      # A stopped push and an error must each be picked up by a reporter built
      # from metrics/0 — proves the event/measurement/tag wiring is right.
      {:ok, io} = StringIO.open("")

      {:ok, pid} =
        ConsoleReporter.start_link(
          metrics: PushX.Telemetry.metrics(),
          device: io
        )

      response = PushX.Response.success(:apns, "id")
      PushX.Telemetry.start(:apns, "tok")
      PushX.Telemetry.stop(:apns, "tok", System.monotonic_time() - 1_000_000, response)

      PushX.Telemetry.error(
        :fcm,
        "tok",
        System.monotonic_time(),
        PushX.Response.error(:fcm, :rate_limited, "x")
      )

      PushX.Telemetry.retry_attempt(:fcm, :rate_limited, 1, 10_000)

      # ConsoleReporter writes synchronously in the handler; give the device a moment.
      Process.sleep(20)
      {_in, out} = StringIO.contents(io)
      GenServer.stop(pid)

      # ConsoleReporter prints per event; the counters must now have a value
      # (no "metric skipped") and the distributions must carry provider tags.
      assert out =~ "Event name: pushx.push.stop"
      assert out =~ "Event name: pushx.push.error"
      assert out =~ "Event name: pushx.retry.attempt"
      refute out =~ "metric skipped"
      assert out =~ "Tag values: %{provider: :apns}"
      assert out =~ "status: :rate_limited"
    end
  end
end
