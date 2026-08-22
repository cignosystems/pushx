defmodule PushX.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Initialize ETS table for named instances (fast reads on push path)
    :ets.new(:pushx_instances, [:named_table, :public, :set])

    children =
      [
        # JWT cache (must start before any APNS sends)
        PushX.JWTCache,
        # Tables for `delivery: :test` (PushX.Test); always present so test
        # mode can also be enabled at runtime, bounded by owner monitoring.
        PushX.Test.Store,
        # Dynamic supervisor for named instances
        {DynamicSupervisor, name: PushX.Instance.DynamicSupervisor, strategy: :one_for_one},
        # Rate limiter (always started, but only tracks when enabled)
        PushX.RateLimiter,
        # Batch-send tasks run here via async_stream_nolink, so a raising
        # task reports {:exit, reason} instead of killing the caller
        {Task.Supervisor, name: PushX.TaskSupervisor},
        # Coalesces automatic Finch pool restarts (one per pool per cooldown)
        PushX.ReconnectGuard,
        # Circuit breaker (always started, but only tracks when enabled)
        PushX.CircuitBreaker,
        # Finch HTTP client pool: HTTP/2 for APNS and FCM, HTTP/1.1 for Web Push
        finch_child()
      ]
      |> maybe_add_goth()

    opts = [strategy: :one_for_one, name: PushX.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_goth(children) do
    # A custom :fcm_token_fetcher owns token acquisition — no Goth process.
    if PushX.Config.fcm_credentials_configured?() and is_nil(PushX.Config.fcm_token_fetcher()) do
      goth_config = build_goth_config()

      children ++
        [
          {Goth, name: PushX.Goth, source: goth_config}
        ]
    else
      children
    end
  end

  defp build_goth_config do
    case PushX.Config.fcm_credentials() do
      {:file, path} ->
        {:service_account, File.read!(path) |> JSON.decode!()}

      credentials when is_map(credentials) ->
        {:service_account, credentials}
    end
  end

  defp finch_child do
    # Bound once: finch_http2_pool_entry/0 reads config and, on finch < 0.22,
    # logs its "ignored" warning — four pools must not mean four warnings.
    http2 = PushX.Config.finch_http2_pool_entry()

    transport_opts = [
      timeout: PushX.Config.connect_timeout(),
      keepalive: true,
      # Explicit so a future refactor can't silently disable TLS peer
      # verification (this is already Mint's default on OTP 25+).
      verify: :verify_peer
    ]

    http2_pool =
      [
        size: PushX.Config.finch_pool_size(),
        count: PushX.Config.finch_pool_count(),
        protocols: [:http2],
        conn_opts: [transport_opts: transport_opts]
      ] ++ http2

    {Finch,
     name: PushX.Config.finch_name(),
     pools: %{
       PushX.URLs.apns_prod() => http2_pool,
       PushX.URLs.apns_sandbox() => http2_pool,
       PushX.URLs.fcm_origin() => http2_pool,
       # FCM Instance ID API (topic subscription management)
       PushX.URLs.fcm_iid_origin() => http2_pool,
       # HTTP/1.1 pool for Web Push: push-service origins are per subscription,
       # so one default pool serves them all. `finch_pool_size` is the
       # per-origin connection cap here; `count` stays 1 because
       # `finch_pool_count` is documented as the HTTP/2 connection knob.
       :default => [
         size: PushX.Config.finch_pool_size(),
         count: 1,
         conn_opts: [transport_opts: transport_opts]
       ]
     }}
  end
end
