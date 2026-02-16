defmodule PushX.Instance.Supervisor do
  @moduledoc false

  use Supervisor

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    Supervisor.start_link(__MODULE__, opts, name: sup_name(name))
  end

  def sup_name(name), do: :"PushX.Instance.Supervisor.#{name}"

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    provider = Keyword.fetch!(opts, :provider)
    config = Keyword.fetch!(opts, :config)

    finch_name = :"PushX.Finch.#{name}"
    goth_name = if provider == :fcm, do: :"PushX.Goth.#{name}"

    children =
      [finch_child(provider, config, finch_name)]
      |> maybe_add_goth(provider, config, goth_name)
      |> Kernel.++([
        {PushX.Instance.Server,
         name: name,
         provider: provider,
         config: config,
         finch_name: finch_name,
         goth_name: goth_name}
      ])

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp finch_child(:apns, config, finch_name) do
    {Finch,
     name: finch_name,
     pools: %{
       "https://api.push.apple.com" => http2_pool_opts(config),
       "https://api.sandbox.push.apple.com" => http2_pool_opts(config)
     }}
  end

  defp finch_child(:fcm, config, finch_name) do
    {Finch,
     name: finch_name,
     pools: %{
       "https://fcm.googleapis.com" => http2_pool_opts(config)
     }}
  end

  defp maybe_add_goth(children, :fcm, config, goth_name) do
    credentials = Keyword.fetch!(config, :credentials)

    source =
      case credentials do
        %{} = map -> {:service_account, map}
        json when is_binary(json) -> {:service_account, JSON.decode!(json)}
      end

    children ++ [{Goth, name: goth_name, source: source}]
  end

  defp maybe_add_goth(children, _provider, _config, _goth_name), do: children

  defp http2_pool_opts(config) do
    [
      size: Keyword.get(config, :pool_size, 2),
      count: Keyword.get(config, :pool_count, 1),
      protocols: [:http2],
      conn_opts: [
        transport_opts: [
          timeout: Keyword.get(config, :connect_timeout, 10_000),
          keepalive: true
        ]
      ]
    ]
  end
end
