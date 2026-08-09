defmodule PushX.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias PushX.CircuitBreaker

  setup do
    CircuitBreaker.reset(:apns)
    CircuitBreaker.reset(:fcm)

    Application.put_env(:pushx, :circuit_breaker_enabled, true)
    Application.put_env(:pushx, :circuit_breaker_threshold, 3)
    Application.put_env(:pushx, :circuit_breaker_cooldown_ms, 100)

    on_exit(fn ->
      Application.delete_env(:pushx, :circuit_breaker_enabled)
      Application.delete_env(:pushx, :circuit_breaker_threshold)
      Application.delete_env(:pushx, :circuit_breaker_cooldown_ms)
      CircuitBreaker.reset(:apns)
      CircuitBreaker.reset(:fcm)
    end)

    :ok
  end

  describe "allow?/1" do
    test "allows requests when circuit is closed" do
      assert CircuitBreaker.allow?(:apns) == :ok
    end

    test "rejects requests when circuit is open" do
      # Open the circuit by recording threshold failures
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      assert CircuitBreaker.allow?(:apns) == {:error, :circuit_open}
    end

    test "allows probe request after cooldown" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      assert CircuitBreaker.allow?(:apns) == {:error, :circuit_open}

      # Wait for cooldown
      Process.sleep(110)

      assert CircuitBreaker.allow?(:apns) == :ok
    end

    test "admits exactly one probe when the cooldown expires" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)

      results =
        1..20
        |> Enum.map(fn _ -> Task.async(fn -> CircuitBreaker.allow?(:apns) end) end)
        |> Task.await_many(5_000)

      assert Enum.count(results, &(&1 == :ok)) == 1
      assert Enum.count(results, &(&1 == {:error, :circuit_open})) == 19
    end

    test "rejects requests while a probe is in flight" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)

      # First caller becomes the probe...
      assert CircuitBreaker.allow?(:apns) == :ok
      # ...everyone else is rejected until the probe reports back.
      assert CircuitBreaker.allow?(:apns) == {:error, :circuit_open}

      CircuitBreaker.record_success(:apns)
      assert CircuitBreaker.allow?(:apns) == :ok
    end

    test "admits a replacement probe if the previous probe never reports" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)
      assert CircuitBreaker.allow?(:apns) == :ok

      # The probe dies without recording success/failure. After another full
      # cooldown, a replacement probe is admitted instead of wedging forever.
      Process.sleep(110)
      assert CircuitBreaker.allow?(:apns) == :ok
    end

    test "always allows when disabled" do
      Application.put_env(:pushx, :circuit_breaker_enabled, false)

      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      # Even though failures were recorded, allow? returns :ok when disabled
      assert CircuitBreaker.allow?(:apns) == :ok
    end
  end

  describe "record_success/1" do
    test "resets circuit to closed" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      assert CircuitBreaker.state(:apns) == :open

      CircuitBreaker.record_success(:apns)

      assert CircuitBreaker.state(:apns) == :closed
      assert CircuitBreaker.allow?(:apns) == :ok
    end

    test "resets half_open circuit to closed after successful probe" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)

      # Probe request
      assert CircuitBreaker.allow?(:apns) == :ok
      assert CircuitBreaker.state(:apns) == :half_open

      CircuitBreaker.record_success(:apns)
      assert CircuitBreaker.state(:apns) == :closed
    end
  end

  describe "record_failure/1" do
    test "increments failure count" do
      CircuitBreaker.record_failure(:apns)
      assert CircuitBreaker.state(:apns) == :closed

      CircuitBreaker.record_failure(:apns)
      assert CircuitBreaker.state(:apns) == :closed

      CircuitBreaker.record_failure(:apns)
      assert CircuitBreaker.state(:apns) == :open
    end

    test "re-opens circuit on half_open probe failure" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)

      # Probe
      assert CircuitBreaker.allow?(:apns) == :ok

      # Probe fails
      CircuitBreaker.record_failure(:apns)
      assert CircuitBreaker.state(:apns) == :open
    end

    test "providers are independent" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      assert CircuitBreaker.state(:apns) == :open
      assert CircuitBreaker.state(:fcm) == :closed
      assert CircuitBreaker.allow?(:fcm) == :ok
    end
  end

  describe "state/1" do
    test "returns :closed for fresh state" do
      assert CircuitBreaker.state(:apns) == :closed
      assert CircuitBreaker.state(:fcm) == :closed
    end

    test "returns :open after threshold failures" do
      CircuitBreaker.record_failure(:fcm)
      CircuitBreaker.record_failure(:fcm)
      CircuitBreaker.record_failure(:fcm)

      assert CircuitBreaker.state(:fcm) == :open
    end

    test "returns :half_open after cooldown" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      Process.sleep(110)

      assert CircuitBreaker.state(:apns) == :half_open
    end
  end

  describe "reset/1" do
    test "resets circuit to closed" do
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)
      CircuitBreaker.record_failure(:apns)

      assert CircuitBreaker.state(:apns) == :open

      CircuitBreaker.reset(:apns)

      assert CircuitBreaker.state(:apns) == :closed
      assert CircuitBreaker.allow?(:apns) == :ok
    end
  end
end
