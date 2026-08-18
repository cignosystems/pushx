defmodule PushX.URLs do
  @moduledoc false

  # Centralized provider URLs. Kept in one place so that base URLs cannot
  # drift between PushX.APNS / PushX.FCM (static config path) and
  # PushX.Instance (dynamic instances path).

  @apns_prod "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"
  @fcm_base "https://fcm.googleapis.com/v1/projects"

  @spec apns(:prod | :sandbox) :: String.t()
  def apns(mode) do
    # :apns_url_override is test-only — it lets the suite point the real send
    # path at a local Bypass server. Never set it in production config.
    case Application.get_env(:pushx, :apns_url_override) do
      nil ->
        case mode do
          :prod -> @apns_prod
          :sandbox -> @apns_sandbox
        end

      override when is_binary(override) ->
        override
    end
  end

  @spec apns_prod() :: String.t()
  def apns_prod, do: @apns_prod

  @spec apns_sandbox() :: String.t()
  def apns_sandbox, do: @apns_sandbox

  @spec fcm_send_url(String.t()) :: String.t()
  def fcm_send_url(project_id) do
    # :fcm_url_override is test-only (see :apns_url_override above) — it lets
    # the suite point the real FCM send path at a local Bypass server.
    case Application.get_env(:pushx, :fcm_url_override) do
      nil -> "#{@fcm_base}/#{project_id}/messages:send"
      override when is_binary(override) -> "#{override}/v1/projects/#{project_id}/messages:send"
    end
  end

  # Instance ID API (topic subscription management). Shares :fcm_url_override.
  @iid_base "https://iid.googleapis.com"

  @spec fcm_topic_url(:subscribe | :unsubscribe) :: String.t()
  def fcm_topic_url(action) do
    method = if action == :subscribe, do: "batchAdd", else: "batchRemove"

    case Application.get_env(:pushx, :fcm_url_override) do
      nil -> "#{@iid_base}/iid/v1:#{method}"
      override when is_binary(override) -> "#{override}/iid/v1:#{method}"
    end
  end

  @spec fcm_origin() :: String.t()
  def fcm_origin, do: "https://fcm.googleapis.com"
end
