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
    |> bind_http2_once()
  end

  defp finch_child(:webpush, config, finch_name) do
    # Push service endpoints are per-subscription (Google, Mozilla, Apple,
    # Microsoft, ...), so there is no fixed origin to pool for: one HTTP/1.1
    # default pool sized by the instance config serves them all. For HTTP/1.1
    # `:pool_size` (default 2) × `:pool_count` is the per-origin concurrency cap.
    {Finch,
     name: finch_name,
     pools: %{
       default: [
         size: Keyword.get(config, :pool_size, 2),
         count: Keyword.get(config, :pool_count, 1),
         conn_opts: [transport_opts: transport_opts(config)]
       ]
     }}
  end

  defp finch_child(:fcm, config, finch_name) do
    {Finch,
     name: finch_name,
     pools: %{
       PushX.URLs.fcm_origin() => http2_pool_opts(config),
       # Instance ID API (topic subscription management) — same sizing and
       # transport options as the send pool, so instance settings apply.
       PushX.URLs.fcm_iid_origin() => http2_pool_opts(config)
     }}
    |> bind_http2_once()
  end

  defp maybe_add_goth(children, :fcm, config, goth_name) do
    # An instance with its own :token_fetcher owns token acquisition, so no
    # Goth (which would eagerly exchange the credentials with Google on start)
    # is started for it. The *global* :fcm_token_fetcher is deliberately not
    # consulted: it belongs to the static configuration, and an instance's
    # credentials are its own.
    # In test delivery mode (PushX.Test) nothing contacts the providers, so no
    # Goth either — it would try to exchange the (throwaway) credentials with
    # Google's OAuth endpoint on start.
    if Keyword.get(config, :token_fetcher) || PushX.Test.active?() do
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
      # Per-instance :ping_interval / :max_connection_age / ... override the
      # global :finch_http2_* config; resolved once per Finch spec in
      # bind_http2_once/1 (placeholder here).
      http2: config,
      conn_opts: [transport_opts: transport_opts(config)]
    ]
  end

  # Resolve the HTTP/2 options once for all of an instance's pools: on
  # finch < 0.22 the `:http2` key is dropped (older finch rejects it) and the
  # "ignored" warning is logged once, not once per pool.
  defp bind_http2_once({Finch, spec}) do
    [{_origin, first} | _] = Map.to_list(spec[:pools])
    entry = PushX.Config.finch_http2_pool_entry(Keyword.fetch!(first, :http2))

    pools =
      Map.new(spec[:pools], fn {origin, opts} ->
        {origin, Keyword.delete(opts, :http2) ++ entry}
      end)

    {Finch, Keyword.put(spec, :pools, pools)}
  end

  defp transport_opts(config) do
    [
      timeout: Keyword.get(config, :connect_timeout, 10_000),
      keepalive: true,
      # Explicit so a future refactor can't silently disable TLS peer
      # verification (this is already Mint's default on OTP 25+).
      verify: :verify_peer
    ]
  end
end
