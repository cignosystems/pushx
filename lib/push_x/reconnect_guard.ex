defmodule PushX.ReconnectGuard do
  @moduledoc """
  Coalesces HTTP pool reconnects so concurrent failures cause one restart.

  Restarting a Finch pool kills every in-flight connection it holds. When many
  concurrent sends observe a connection error at the same time (e.g. a network
  blip during a large `push_batch`), each of them requesting a pool restart
  turns a brief blip into a self-amplifying outage: every restart fails other
  in-flight requests, which then request more restarts.

  This process grants at most one reconnect per pool per cooldown window.
  The default window is 5000 ms; configure with:

      config :pushx, reconnect_cooldown_ms: 5_000

  Manual calls to `PushX.reconnect/0` are not gated — only the automatic
  reconnects issued by `PushX.Retry` go through this guard.
  """

  use GenServer

  @default_cooldown_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns `true` if the caller should perform the reconnect for `key`.

  At most one caller per `key` is granted `true` within each cooldown window;
  the rest get `false` and should skip (a restart just happened or is
  underway). `key` is `:default` for the shared static pool, or the instance
  name for `PushX.Instance` pools.
  """
  @spec acquire(term()) :: boolean()
  def acquire(key) do
    GenServer.call(__MODULE__, {:acquire, key, cooldown_ms()})
  catch
    # If the guard is unavailable (e.g. the app is shutting down), allow the
    # reconnect rather than never healing.
    :exit, _ -> true
  end

  @doc false
  # Test helper: forget all grants.
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  defp cooldown_ms do
    PushX.Config.get(:reconnect_cooldown_ms, @default_cooldown_ms)
  end

  @impl true
  def init(_opts) do
    {:ok, %{}}
  end

  @impl true
  def handle_call({:acquire, key, cooldown}, _from, last_grants) do
    now = System.monotonic_time(:millisecond)

    case last_grants do
      %{^key => last} when now - last < cooldown ->
        {:reply, false, last_grants}

      _ ->
        {:reply, true, Map.put(last_grants, key, now)}
    end
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, %{}}
  end
end
