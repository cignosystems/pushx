defmodule PushX.RetryTest do
  use ExUnit.Case

  alias PushX.{Response, Retry}

  describe "retryable?/1" do
    test "returns true for connection_error" do
      response = Response.error(:apns, :connection_error)
      assert Retry.retryable?(response) == true
    end

    test "returns true for rate_limited" do
      response = Response.error(:fcm, :rate_limited)
      assert Retry.retryable?(response) == true
    end

    test "returns true for server_error" do
      response = Response.error(:apns, :server_error)
      assert Retry.retryable?(response) == true
    end

    test "returns false for invalid_token" do
      response = Response.error(:apns, :invalid_token)
      assert Retry.retryable?(response) == false
    end

    test "returns false for expired_token" do
      response = Response.error(:apns, :expired_token)
      assert Retry.retryable?(response) == false
    end

    test "returns false for unregistered" do
      response = Response.error(:fcm, :unregistered)
      assert Retry.retryable?(response) == false
    end

    test "returns false for payload_too_large" do
      response = Response.error(:apns, :payload_too_large)
      assert Retry.retryable?(response) == false
    end

    test "returns false for unknown_error" do
      response = Response.error(:fcm, :unknown_error)
      assert Retry.retryable?(response) == false
    end
  end

  describe "calculate_delay/4" do
    test "uses retry_after for rate_limited when provided" do
      response = %Response{status: :rate_limited, retry_after: 30, provider: :apns}
      delay = Retry.calculate_delay(response, 1, 10_000, 60_000)
      # 30 seconds in ms
      assert delay == 30_000
    end

    test "uses default delay for rate_limited without retry_after" do
      response = %Response{status: :rate_limited, retry_after: nil, provider: :apns}
      delay = Retry.calculate_delay(response, 1, 10_000, 60_000)
      # Default 60s
      assert delay == 60_000
    end

    test "uses exponential backoff for other errors" do
      response = %Response{status: :server_error, provider: :apns}

      # First attempt: base_delay * 2^0 = 10_000 (±10% jitter)
      delay1 = Retry.calculate_delay(response, 1, 10_000, 60_000)
      assert delay1 >= 9_000 and delay1 <= 11_000

      # Second attempt: base_delay * 2^1 = 20_000 (±10% jitter)
      delay2 = Retry.calculate_delay(response, 2, 10_000, 60_000)
      assert delay2 >= 18_000 and delay2 <= 22_000

      # Third attempt: base_delay * 2^2 = 40_000 (±10% jitter)
      delay3 = Retry.calculate_delay(response, 3, 10_000, 60_000)
      assert delay3 >= 36_000 and delay3 <= 44_000
    end

    test "caps delay at max_delay" do
      response = %Response{status: :server_error, provider: :apns}

      # Fourth attempt would be 80_000 but capped at 60_000
      delay = Retry.calculate_delay(response, 4, 10_000, 60_000)
      assert delay == 60_000
    end
  end

  describe "with_retry/2" do
    setup do
      # Disable retry for most tests to avoid slowness
      original = Application.get_env(:pushx, :retry_enabled)
      Application.put_env(:pushx, :retry_enabled, true)
      Application.put_env(:pushx, :retry_max_attempts, 3)
      # Fast for tests
      Application.put_env(:pushx, :retry_base_delay_ms, 10)
      Application.put_env(:pushx, :retry_max_delay_ms, 50)

      on_exit(fn ->
        if original do
          Application.put_env(:pushx, :retry_enabled, original)
        else
          Application.delete_env(:pushx, :retry_enabled)
        end

        Application.delete_env(:pushx, :retry_max_attempts)
        Application.delete_env(:pushx, :retry_base_delay_ms)
        Application.delete_env(:pushx, :retry_max_delay_ms)
      end)

      :ok
    end

    test "returns success immediately on first attempt" do
      response = Response.success(:apns, "id")

      result = Retry.with_retry(fn -> {:ok, response} end)

      assert {:ok, ^response} = result
    end

    test "does not retry permanent errors" do
      call_count = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:error, Response.error(:apns, :invalid_token)}
        end)

      assert {:error, %Response{status: :invalid_token}} = result
      # Only called once
      assert :counters.get(call_count, 1) == 1
    end

    test "retries transient errors up to max_attempts" do
      call_count = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:error, Response.error(:apns, :server_error)}
        end)

      assert {:error, %Response{status: :server_error}} = result
      # Called 3 times (max_attempts)
      assert :counters.get(call_count, 1) == 3
    end

    test "succeeds if retry succeeds" do
      call_count = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(fn ->
          count = :counters.add(call_count, 1, 1)

          if :counters.get(call_count, 1) < 2 do
            {:error, Response.error(:apns, :server_error)}
          else
            {:ok, Response.success(:apns, "success")}
          end
        end)

      assert {:ok, %Response{status: :sent}} = result
      # Succeeded on second try
      assert :counters.get(call_count, 1) == 2
    end

    test "respects retry_enabled config" do
      Application.put_env(:pushx, :retry_enabled, false)
      call_count = :counters.new(1, [:atomics])

      result =
        Retry.with_retry(fn ->
          :counters.add(call_count, 1, 1)
          {:error, Response.error(:apns, :server_error)}
        end)

      assert {:error, %Response{status: :server_error}} = result
      # Only called once when disabled
      assert :counters.get(call_count, 1) == 1
    end
  end
end
