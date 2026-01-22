defmodule PushX.TelemetryTest do
  use ExUnit.Case

  alias PushX.{Response, Telemetry}

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
end
