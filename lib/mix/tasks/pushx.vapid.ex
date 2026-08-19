defmodule Mix.Tasks.Pushx.Vapid do
  @shortdoc "Generates a VAPID key pair for Web Push"

  @moduledoc """
  Generates a VAPID (RFC 8292) application-server key pair for Web Push and
  prints it with the config and front-end snippets that use it:

      $ mix pushx.vapid

  Run it once per application (or per tenant for named instances) and keep
  the private key secret — rotating it invalidates every existing browser
  subscription. Keys are base64url, the format browsers and the `web-push`
  CLI use.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    %{public_key: pub, private_key: priv} = PushX.WebPush.generate_vapid_keys()

    Mix.shell().info("""
    VAPID key pair generated. Keep the private key secret.

    # config/runtime.exs
    config :pushx,
      webpush_vapid_subject: "mailto:ops@example.com",
      webpush_vapid_public_key: "#{pub}",
      webpush_vapid_private_key: System.fetch_env!("WEBPUSH_VAPID_PRIVATE_KEY")

    # environment
    export WEBPUSH_VAPID_PRIVATE_KEY="#{priv}"

    // front end — subscribe with the public key
    const sub = await registration.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: "#{pub}",
    });
    // POST JSON.stringify(sub) to your server and PushX.push(:webpush, sub, msg)
    """)
  end
end
