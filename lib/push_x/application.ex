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
        # Finch HTTP client pool with HTTP/2 for APNS and FCM
        {Finch,
         name: PushX.Config.finch_name(),
         pools: %{
           # APNS Production
           PushX.URLs.apns_prod() => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [
               transport_opts: [timeout: PushX.Config.connect_timeout(), keepalive: true]
             ]
           ],
           # APNS Sandbox
           PushX.URLs.apns_sandbox() => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [
               transport_opts: [timeout: PushX.Config.connect_timeout(), keepalive: true]
             ]
           ],
           # FCM (Firebase Cloud Messaging)
           PushX.URLs.fcm_origin() => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [
               transport_opts: [timeout: PushX.Config.connect_timeout(), keepalive: true]
             ]
           ],
           :default => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count()
           ]
         }}
      ]
      |> maybe_add_goth()

    opts = [strategy: :one_for_one, name: PushX.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_goth(children) do
    if PushX.Config.fcm_configured?() do
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
end
