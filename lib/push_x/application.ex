defmodule PushX.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # Rate limiter (always started, but only tracks when enabled)
        PushX.RateLimiter,
        # Finch HTTP client pool with HTTP/2 for APNS and FCM
        {Finch,
         name: PushX.Config.finch_name(),
         pools: %{
           # APNS Production
           "https://api.push.apple.com" => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [transport_opts: [timeout: PushX.Config.connect_timeout()]]
           ],
           # APNS Sandbox
           "https://api.sandbox.push.apple.com" => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [transport_opts: [timeout: PushX.Config.connect_timeout()]]
           ],
           # FCM (Firebase Cloud Messaging)
           "https://fcm.googleapis.com" => [
             size: PushX.Config.finch_pool_size(),
             count: PushX.Config.finch_pool_count(),
             protocols: [:http2],
             conn_opts: [transport_opts: [timeout: PushX.Config.connect_timeout()]]
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
