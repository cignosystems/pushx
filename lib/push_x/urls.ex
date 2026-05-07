defmodule PushX.URLs do
  @moduledoc false

  # Centralized provider URLs. Kept in one place so that base URLs cannot
  # drift between PushX.APNS / PushX.FCM (static config path) and
  # PushX.Instance (dynamic instances path).

  @apns_prod "https://api.push.apple.com"
  @apns_sandbox "https://api.sandbox.push.apple.com"
  @fcm_base "https://fcm.googleapis.com/v1/projects"

  @spec apns(:prod | :sandbox) :: String.t()
  def apns(:prod), do: @apns_prod
  def apns(:sandbox), do: @apns_sandbox

  @spec apns_prod() :: String.t()
  def apns_prod, do: @apns_prod

  @spec apns_sandbox() :: String.t()
  def apns_sandbox, do: @apns_sandbox

  @spec fcm_send_url(String.t()) :: String.t()
  def fcm_send_url(project_id), do: "#{@fcm_base}/#{project_id}/messages:send"

  @spec fcm_origin() :: String.t()
  def fcm_origin, do: "https://fcm.googleapis.com"
end
