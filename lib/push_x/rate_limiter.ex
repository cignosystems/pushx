defmodule PushX.RateLimiter do
  @moduledoc """
  Client-side rate limiting for push notifications.

  Prevents exceeding provider rate limits by tracking requests locally.
  Uses a **fixed-window** counter (windows aligned to the clock, counters
  bumped with a single atomic ETS operation), so concurrent senders can
  never race the check-then-increment or clobber each other's window
  resets. Client-side limiting is inherently best-effort: it bounds what
  *this node* sends, and the true arbiter is always the provider.

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

  1. Time is divided into fixed windows of `rate_limit_window_ms`
  2. Each key (provider or named instance) gets one atomic counter per window
  3. When the counter passes the limit, further requests are rejected
  4. A new window starts a fresh counter; old windows are swept periodically

  """

  use GenServer
  require Logger

  @table_name :pushx_rate_limiter
  @cleanup_interval_ms 5_000

  # Default configuration
  @default_window_ms 1_000
  @default_limit 5_000

  @type provider :: :apns | :fcm | :webpush
  @type key :: atom()

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

  The two-arity form counts under an arbitrary `key` (e.g. a named-instance
  atom) while taking the limit from `provider`'s config — each instance has
  its own credentials and therefore its own provider-side budget.
  """
  @spec check_and_increment(provider()) :: :ok | {:error, :rate_limited}
  def check_and_increment(provider), do: check_and_increment(provider, provider)

  @spec check_and_increment(key(), provider()) :: :ok | {:error, :rate_limited}
  def check_and_increment(key, provider) do
    if enabled?() do
      do_check_and_increment(key, provider)
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
      if current_count(provider) < limit(provider) do
        :ok
      else
        {:error, :rate_limited}
      end
    else
      :ok
    end
  end

  @doc """
  Returns the number of requests recorded in the current window for a key.

  Counts attempts, including ones that were rejected over the limit.
  """
  @spec current_count(key()) :: non_neg_integer()
  def current_count(key) do
    case :ets.lookup(@table_name, {key, current_window_id()}) do
      [{_window_key, count}] -> count
      [] -> 0
    end
  end

  @doc """
  Returns the configured limit for a provider.
  """
  @spec limit(provider()) :: pos_integer()
  def limit(:apns), do: PushX.Config.get(:rate_limit_apns, @default_limit)
  def limit(:fcm), do: PushX.Config.get(:rate_limit_fcm, @default_limit)
  def limit(:webpush), do: PushX.Config.get(:rate_limit_webpush, @default_limit)

  @doc """
  Returns remaining requests before rate limit is hit.
  """
  @spec remaining(provider()) :: non_neg_integer()
  def remaining(provider) do
    max(0, limit(provider) - current_count(provider))
  end

  @doc """
  Resets the rate limiter for a key. Useful for testing.
  """
  @spec reset(key()) :: :ok
  def reset(key) do
    :ets.match_delete(@table_name, {{key, :_}, :_})
    :ok
  end

  @doc """
  Resets all rate limiters.
  """
  @spec reset_all() :: :ok
  def reset_all do
    :ets.delete_all_objects(@table_name)
    :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Rows are {{key, window_id}, count}; counters are created and bumped
    # in one atomic :ets.update_counter/4 call on the send path.
    table = :ets.new(@table_name, [:named_table, :public, :set])

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

  defp current_window_id do
    # floor_div so negative monotonic time still maps to consistent windows
    Integer.floor_div(System.monotonic_time(:millisecond), window_ms())
  end

  defp do_check_and_increment(key, provider) do
    window_key = {key, current_window_id()}

    # Single atomic op: creates the row at 0 if absent, then increments.
    # There is no separate check step for concurrent callers to race.
    count = :ets.update_counter(@table_name, window_key, {2, 1}, {window_key, 0})

    if count <= limit(provider) do
      :ok
    else
      Logger.warning("[PushX.RateLimiter] Rate limit exceeded for #{inspect(key)}")
      {:error, :rate_limited}
    end
  end

  defp cleanup_old_entries do
    current = current_window_id()

    # Delete counters from windows that have already closed.
    :ets.select_delete(@table_name, [
      {{{:"$1", :"$2"}, :"$3"}, [{:<, :"$2", current}], [true]}
    ])
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
