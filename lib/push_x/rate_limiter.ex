defmodule PushX.RateLimiter do
  @moduledoc """
  Client-side rate limiting for push notifications.

  Prevents exceeding provider rate limits by tracking requests locally.
  Uses a sliding window algorithm with ETS for fast, concurrent access.

  ## Configuration

      config :pushx,
        rate_limit_enabled: true,
        rate_limit_apns: 5000,      # requests per window
        rate_limit_fcm: 5000,       # requests per window
        rate_limit_window_ms: 1000  # 1 second window

  ## Usage

  Rate limiting is automatically applied when enabled. You can also
  check manually:

      case PushX.RateLimiter.check(:apns) do
        :ok -> # Proceed with sending
        {:error, :rate_limited} -> # Back off
      end

  ## How It Works

  1. Each provider has a separate counter
  2. Requests are counted within a sliding time window
  3. When the limit is reached, new requests are rejected
  4. The window slides forward, allowing new requests

  """

  use GenServer
  require Logger

  @table_name :pushx_rate_limiter
  @cleanup_interval_ms 5_000

  # Default configuration
  @default_window_ms 1_000
  @default_limit 5_000

  @type provider :: :apns | :fcm

  ## Client API

  @doc """
  Starts the rate limiter process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request can be made and increments the counter.

  Returns `:ok` if under the limit, `{:error, :rate_limited}` if over.
  """
  @spec check_and_increment(provider()) :: :ok | {:error, :rate_limited}
  def check_and_increment(provider) do
    if enabled?() do
      do_check_and_increment(provider)
    else
      :ok
    end
  end

  @doc """
  Checks if a request would be allowed without incrementing.
  """
  @spec check(provider()) :: :ok | {:error, :rate_limited}
  def check(provider) do
    if enabled?() do
      do_check(provider)
    else
      :ok
    end
  end

  @doc """
  Returns the current request count for a provider.
  """
  @spec current_count(provider()) :: non_neg_integer()
  def current_count(provider) do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    window_start = now - window

    case :ets.lookup(@table_name, provider) do
      [{^provider, requests}] ->
        requests
        |> Enum.filter(fn ts -> ts > window_start end)
        |> length()

      [] ->
        0
    end
  end

  @doc """
  Returns the configured limit for a provider.
  """
  @spec limit(provider()) :: pos_integer()
  def limit(:apns), do: PushX.Config.get(:rate_limit_apns, @default_limit)
  def limit(:fcm), do: PushX.Config.get(:rate_limit_fcm, @default_limit)

  @doc """
  Returns remaining requests before rate limit is hit.
  """
  @spec remaining(provider()) :: non_neg_integer()
  def remaining(provider) do
    max(0, limit(provider) - current_count(provider))
  end

  @doc """
  Resets the rate limiter for a provider. Useful for testing.
  """
  @spec reset(provider()) :: :ok
  def reset(provider) do
    :ets.insert(@table_name, {provider, []})
    :ok
  end

  @doc """
  Resets all rate limiters.
  """
  @spec reset_all() :: :ok
  def reset_all do
    reset(:apns)
    reset(:fcm)
    :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, :set])
    :ets.insert(table, {:apns, []})
    :ets.insert(table, {:fcm, []})

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, %{table: table}}
  end

  @impl true
  def handle_info(:cleanup, state) do
    cleanup_old_entries()
    schedule_cleanup()
    {:noreply, state}
  end

  ## Private Functions

  defp enabled? do
    PushX.Config.get(:rate_limit_enabled, false)
  end

  defp window_ms do
    PushX.Config.get(:rate_limit_window_ms, @default_window_ms)
  end

  defp do_check_and_increment(provider) do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    window_start = now - window
    max_requests = limit(provider)

    case :ets.lookup(@table_name, provider) do
      [{^provider, requests}] ->
        # Filter to only requests in current window
        current_requests = Enum.filter(requests, fn ts -> ts > window_start end)

        if length(current_requests) < max_requests do
          # Add new request timestamp
          :ets.insert(@table_name, {provider, [now | current_requests]})
          :ok
        else
          Logger.warning("[PushX.RateLimiter] Rate limit exceeded for #{provider}")
          {:error, :rate_limited}
        end

      [] ->
        :ets.insert(@table_name, {provider, [now]})
        :ok
    end
  end

  defp do_check(provider) do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    window_start = now - window
    max_requests = limit(provider)

    case :ets.lookup(@table_name, provider) do
      [{^provider, requests}] ->
        current_requests = Enum.filter(requests, fn ts -> ts > window_start end)

        if length(current_requests) < max_requests do
          :ok
        else
          {:error, :rate_limited}
        end

      [] ->
        :ok
    end
  end

  defp cleanup_old_entries do
    now = System.monotonic_time(:millisecond)
    window = window_ms()
    window_start = now - window

    for provider <- [:apns, :fcm] do
      case :ets.lookup(@table_name, provider) do
        [{^provider, requests}] ->
          cleaned = Enum.filter(requests, fn ts -> ts > window_start end)
          :ets.insert(@table_name, {provider, cleaned})

        [] ->
          :ok
      end
    end
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
