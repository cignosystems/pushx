defmodule PushX.Instance.Server do
  @moduledoc false

  use GenServer
  require Logger

  @table :pushx_instances

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: server_name(name))
  end

  def server_name(name), do: :"PushX.Instance.Server.#{name}"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    name = Keyword.fetch!(opts, :name)
    provider = Keyword.fetch!(opts, :provider)
    config = Keyword.fetch!(opts, :config)
    finch_name = Keyword.fetch!(opts, :finch_name)
    goth_name = Keyword.get(opts, :goth_name)

    # Insert instance info into ETS for fast reads on push path
    :ets.insert(
      @table,
      {name,
       %{
         provider: provider,
         config: config,
         enabled: true,
         finch_name: finch_name,
         goth_name: goth_name
       }}
    )

    {:ok, %{name: name, provider: provider}}
  end

  @impl true
  def terminate(_reason, %{name: name, provider: provider}) do
    :ets.delete(@table, name)

    if provider == :apns do
      PushX.JWTCache.invalidate({:apns_jwt, name})
    end

    :ok
  end
end
