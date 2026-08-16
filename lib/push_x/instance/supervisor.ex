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
       PushX.URLs.apns_prod() => http2_pool_opts(config),
       PushX.URLs.apns_sandbox() => http2_pool_opts(config)
     }}
  end

  defp finch_child(:fcm, config, finch_name) do
    {Finch,
     name: finch_name,
     pools: %{
       PushX.URLs.fcm_origin() => http2_pool_opts(config)
     }}
  end

  defp maybe_add_goth(children, :fcm, config, goth_name) do
    # With a custom token fetcher configured (test seam), the fetcher owns
    # token acquisition and Goth — which would eagerly try to exchange the
    # credentials with Google on start — is not started.
    if PushX.Config.fcm_token_fetcher() do
      children
    else
      children ++ [{Goth, name: goth_name, source: goth_source(config)}]
    end
  end

  defp maybe_add_goth(children, _provider, _config, _goth_name), do: children

  @doc false
  @spec goth_source(keyword()) :: {:service_account, map()}
  def goth_source(config) do
    case Keyword.fetch!(config, :credentials) do
      %{} = map -> {:service_account, map}
      json when is_binary(json) -> {:service_account, JSON.decode!(json)}
    end
  end

  defp http2_pool_opts(config) do
    [
      size: Keyword.get(config, :pool_size, 2),
      count: Keyword.get(config, :pool_count, 1),
      protocols: [:http2],
      conn_opts: [
        transport_opts: [
          timeout: Keyword.get(config, :connect_timeout, 10_000),
          keepalive: true,
          # Explicit so a future refactor can't silently disable TLS peer
          # verification (this is already Mint's default on OTP 25+).
          verify: :verify_peer
        ]
      ]
    ]
  end
end
