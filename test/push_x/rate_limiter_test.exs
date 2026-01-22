defmodule PushX.RateLimiterTest do
  use ExUnit.Case, async: false

  alias PushX.RateLimiter

  setup do
    # Reset rate limiter state before each test
    RateLimiter.reset_all()

    # Store original config
    original_enabled = Application.get_env(:pushx, :rate_limit_enabled)
    original_apns = Application.get_env(:pushx, :rate_limit_apns)
    original_fcm = Application.get_env(:pushx, :rate_limit_fcm)
    original_window = Application.get_env(:pushx, :rate_limit_window_ms)

    on_exit(fn ->
      # Restore original config
      if original_enabled, do: Application.put_env(:pushx, :rate_limit_enabled, original_enabled)
      if original_apns, do: Application.put_env(:pushx, :rate_limit_apns, original_apns)
      if original_fcm, do: Application.put_env(:pushx, :rate_limit_fcm, original_fcm)
      if original_window, do: Application.put_env(:pushx, :rate_limit_window_ms, original_window)
      RateLimiter.reset_all()
    end)

    :ok
  end

  describe "when rate limiting is disabled" do
    test "check_and_increment always returns :ok" do
      Application.put_env(:pushx, :rate_limit_enabled, false)

      # Should always succeed regardless of how many times we call it
      for _ <- 1..100 do
        assert RateLimiter.check_and_increment(:apns) == :ok
        assert RateLimiter.check_and_increment(:fcm) == :ok
      end
    end

    test "check always returns :ok" do
      Application.put_env(:pushx, :rate_limit_enabled, false)

      assert RateLimiter.check(:apns) == :ok
      assert RateLimiter.check(:fcm) == :ok
    end
  end

  describe "when rate limiting is enabled" do
    setup do
      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_apns, 5)
      Application.put_env(:pushx, :rate_limit_fcm, 5)
      Application.put_env(:pushx, :rate_limit_window_ms, 1000)
      :ok
    end

    test "allows requests under the limit" do
      for _ <- 1..5 do
        assert RateLimiter.check_and_increment(:apns) == :ok
      end
    end

    test "blocks requests over the limit" do
      # Use up the limit
      for _ <- 1..5 do
        assert RateLimiter.check_and_increment(:apns) == :ok
      end

      # Next request should be blocked
      assert RateLimiter.check_and_increment(:apns) == {:error, :rate_limited}
    end

    test "check does not increment counter" do
      # Check without incrementing
      assert RateLimiter.check(:apns) == :ok
      assert RateLimiter.current_count(:apns) == 0

      # Now increment
      assert RateLimiter.check_and_increment(:apns) == :ok
      assert RateLimiter.current_count(:apns) == 1
    end

    test "providers have separate limits" do
      # Use up APNS limit
      for _ <- 1..5 do
        assert RateLimiter.check_and_increment(:apns) == :ok
      end

      # APNS should be limited
      assert RateLimiter.check_and_increment(:apns) == {:error, :rate_limited}

      # FCM should still work
      assert RateLimiter.check_and_increment(:fcm) == :ok
    end

    test "current_count returns correct value" do
      assert RateLimiter.current_count(:apns) == 0

      RateLimiter.check_and_increment(:apns)
      assert RateLimiter.current_count(:apns) == 1

      RateLimiter.check_and_increment(:apns)
      assert RateLimiter.current_count(:apns) == 2
    end

    test "remaining returns correct value" do
      assert RateLimiter.remaining(:apns) == 5

      RateLimiter.check_and_increment(:apns)
      assert RateLimiter.remaining(:apns) == 4

      for _ <- 1..4 do
        RateLimiter.check_and_increment(:apns)
      end

      assert RateLimiter.remaining(:apns) == 0
    end

    test "limit returns configured value" do
      assert RateLimiter.limit(:apns) == 5
      assert RateLimiter.limit(:fcm) == 5

      Application.put_env(:pushx, :rate_limit_apns, 100)
      assert RateLimiter.limit(:apns) == 100
    end

    test "reset clears counter for a provider" do
      for _ <- 1..5 do
        RateLimiter.check_and_increment(:apns)
      end

      assert RateLimiter.current_count(:apns) == 5

      RateLimiter.reset(:apns)
      assert RateLimiter.current_count(:apns) == 0
    end

    test "reset_all clears all counters" do
      RateLimiter.check_and_increment(:apns)
      RateLimiter.check_and_increment(:fcm)

      assert RateLimiter.current_count(:apns) == 1
      assert RateLimiter.current_count(:fcm) == 1

      RateLimiter.reset_all()

      assert RateLimiter.current_count(:apns) == 0
      assert RateLimiter.current_count(:fcm) == 0
    end

    test "sliding window allows new requests after time passes" do
      # Set a very short window for testing
      Application.put_env(:pushx, :rate_limit_window_ms, 50)
      Application.put_env(:pushx, :rate_limit_apns, 2)
      RateLimiter.reset(:apns)

      # Use up the limit
      assert RateLimiter.check_and_increment(:apns) == :ok
      assert RateLimiter.check_and_increment(:apns) == :ok
      assert RateLimiter.check_and_increment(:apns) == {:error, :rate_limited}

      # Wait for window to slide
      Process.sleep(60)

      # Should be allowed again
      assert RateLimiter.check_and_increment(:apns) == :ok
    end
  end
end
