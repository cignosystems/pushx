defmodule PushX.Test.Store do
  @moduledoc false

  # Owns the ETS tables behind PushX.Test and keeps them bounded: the first
  # time a test process (the "owner") records a push or installs a stub, the
  # store starts monitoring it and deletes its rows when it exits. Without
  # this, a large `delivery: :test` suite would accumulate every recorded
  # payload for the VM's lifetime (and a reused pid could see stale rows).
  #
  # Reads and writes stay direct ETS operations from the calling process; the
  # GenServer only handles monitoring and cleanup, so it is never on the send
  # path beyond one `insert_new` + cast per new owner.

  use GenServer

  @pushes_table :pushx_test_pushes
  @stubs_table :pushx_test_stubs
  @owners_table :pushx_test_owners

  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @doc "Ensure `owner` is monitored; idempotent and cheap after the first call."
  @spec track(pid()) :: :ok
  def track(owner) do
    if :ets.insert_new(@owners_table, {owner}), do: GenServer.cast(__MODULE__, {:monitor, owner})
    :ok
  end

  @doc "Delete everything recorded for `owner`."
  @spec purge(pid()) :: :ok
  def purge(owner) do
    :ets.match_delete(@pushes_table, {{owner, :_}, :_})
    :ets.delete(@stubs_table, owner)
    :ok
  end

  @impl true
  def init([]) do
    :ets.new(@pushes_table, [:named_table, :public, :ordered_set, read_concurrency: true])
    :ets.new(@stubs_table, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@owners_table, [:named_table, :public, :set])
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:monitor, owner}, state) do
    Process.monitor(owner)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, owner, _reason}, state) do
    purge(owner)
    :ets.delete(@owners_table, owner)
    {:noreply, state}
  end
end
