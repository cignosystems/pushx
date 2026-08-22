defmodule PushX.Instance.Server do
  @moduledoc false

  use GenServer

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

    case provider do
      :apns ->
        PushX.JWTCache.invalidate({:apns_jwt, name})

      :webpush ->
        # Per-origin VAPID JWTs and the resolved key pair are scoped by name;
        # a reconfigure (stop + start with new keys) must not keep serving them.
        PushX.JWTCache.invalidate_match({:vapid_jwt, name, :_})
        PushX.JWTCache.invalidate_match({:vapid_keys, name, :_})

      _ ->
        :ok
    end

    :ok
  end
end
