defmodule Mix.Tasks.Pushx.Doctor do
  @shortdoc "Checks the PushX configuration and credentials without sending anything"

  @moduledoc """
  Validates the PushX configuration offline — the same checks the library
  runs at start/send time, reported all at once:

      $ mix pushx.doctor
      PushX 0.14.0 — configuration check (MIX_ENV=dev)

        APNS  ✔ configured (key ABC123DEFG, team TEAM123456, mode :prod)
              ✔ private key resolves and signs ES256
        FCM   ✔ project my-project
              ✔ service-account credentials resolve and sign RS256
        WEB   ✔ Web Push configured (subject mailto:ops@example.com)
              ✔ VAPID key resolves; public key BJ1kQ2m3n4o5… (applicationServerKey)
        Delivery: live
        Retries:  enabled, 3 attempts, 10000ms base delay — a batch task may block up to 180s
        Pools:    finch_pool_size 25 (consider 2-5 for low traffic on cloud LBs)
        Breaker:  off   Rate limit: off

      All checks passed.

  Exits with a non-zero status (raises `Mix.Error`) when a credential check
  fails, so it can gate a deploy:

      mix pushx.doctor && mix release

  Nothing is sent and no provider is contacted. Use the same `MIX_ENV` /
  environment variables as the deployment you are checking (`MIX_ENV=prod
  mix pushx.doctor`), since `{:system, VAR}` credentials are resolved at
  check time.
  """

  use Mix.Task

  alias PushX.Config
  alias PushX.WebPush.VAPID

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    IO.puts("PushX #{version()} — configuration check (MIX_ENV=#{Mix.env()})\n")

    failures =
      []
      |> check_apns()
      |> check_fcm()
      |> check_webpush()

    print_settings()

    case failures do
      [] ->
        IO.puts("\nAll checks passed.")

      _ ->
        Mix.raise(
          "pushx.doctor found #{length(failures)} problem(s):\n  - " <>
            Enum.join(Enum.reverse(failures), "\n  - ")
        )
    end
  end

  # -- APNS ---------------------------------------------------------------

  defp check_apns(failures) do
    if Config.apns_configured?() do
      ok(
        "APNS ",
        "configured (key #{Config.apns_key_id()}, team #{Config.apns_team_id()}, mode #{inspect(Config.apns_mode())})"
      )

      case PushX.Instance.validate_private_key(
             key_id: Config.apns_key_id(),
             private_key: Application.get_env(:pushx, :apns_private_key)
           ) do
        :ok ->
          ok("     ", "private key resolves and signs ES256 (P-256)")
          failures

        {:error, {:invalid_private_key, reason}} ->
          fail("     ", "private key: #{inspect(reason)}")
          ["APNS private key: #{inspect(reason)}" | failures]
      end
    else
      missing =
        Enum.reject(
          [:apns_key_id, :apns_team_id, :apns_private_key],
          &Application.get_env(:pushx, &1)
        )

      skip(
        "APNS ",
        "not configured (missing #{inspect(missing)}) — APNS sends will return :not_configured"
      )

      failures
    end
  end

  # -- FCM ----------------------------------------------------------------

  defp check_fcm(failures) do
    project = Application.get_env(:pushx, :fcm_project_id)
    fetcher = Config.fcm_token_fetcher()
    creds = Application.get_env(:pushx, :fcm_credentials)

    cond do
      is_nil(project) and is_nil(creds) and is_nil(fetcher) ->
        skip("FCM  ", "not configured — FCM sends will return :not_configured")
        failures

      is_nil(project) ->
        fail("FCM  ", ":fcm_project_id is not set")
        ["FCM: :fcm_project_id is not set" | failures]

      true ->
        ok("FCM  ", "project #{project}")
        failures |> check_fcm_fetcher(fetcher) |> check_fcm_credentials(creds, fetcher)
    end
  end

  defp check_fcm_fetcher(failures, nil), do: failures

  defp check_fcm_fetcher(failures, {m, f, a}) when is_atom(m) and is_atom(f) and is_list(a) do
    if Code.ensure_loaded?(m) and function_exported?(m, f, length(a) + 1) do
      ok(
        "     ",
        "token fetcher #{inspect(m)}.#{f}/#{length(a) + 1} (Goth not started; credentials optional)"
      )

      failures
    else
      fail("     ", "token fetcher #{inspect(m)}.#{f}/#{length(a) + 1} is not exported")
      ["FCM token fetcher #{inspect({m, f, a})} is not exported" | failures]
    end
  end

  defp check_fcm_fetcher(failures, other) do
    fail("     ", ":fcm_token_fetcher must be {module, function, args}, got #{inspect(other)}")
    ["FCM :fcm_token_fetcher malformed: #{inspect(other)}" | failures]
  end

  defp check_fcm_credentials(failures, nil, nil) do
    fail("     ", "neither :fcm_credentials nor :fcm_token_fetcher is set")
    ["FCM: no OAuth source (:fcm_credentials or :fcm_token_fetcher)" | failures]
  end

  defp check_fcm_credentials(failures, nil, _fetcher), do: failures

  defp check_fcm_credentials(failures, _creds, _fetcher) do
    resolved =
      try do
        {:ok, resolve_fcm_credentials(Config.fcm_credentials())}
      rescue
        e -> {:error, Exception.message(e)}
      end

    with {:ok, creds} <- resolved,
         :ok <- PushX.Instance.validate_fcm_credentials(creds) do
      ok("     ", "service-account credentials resolve and sign RS256")
      failures
    else
      {:error, {:invalid_credentials, reason}} ->
        fail("     ", "service-account credentials: #{inspect(reason)}")
        ["FCM credentials: #{inspect(reason)}" | failures]

      {:error, reason} ->
        fail("     ", "service-account credentials: #{inspect(reason)}")
        ["FCM credentials: #{inspect(reason)}" | failures]
    end
  end

  defp resolve_fcm_credentials({:file, path}), do: path |> File.read!() |> JSON.decode!()
  defp resolve_fcm_credentials(map) when is_map(map), do: map

  # -- Web Push -------------------------------------------------------------

  defp check_webpush(failures) do
    subject = Application.get_env(:pushx, :webpush_vapid_subject)
    private = Application.get_env(:pushx, :webpush_vapid_private_key)
    public = Application.get_env(:pushx, :webpush_vapid_public_key)

    cond do
      is_nil(subject) and is_nil(private) ->
        skip("WEB  ", "Web Push not configured — :webpush sends will return :not_configured")
        failures

      is_nil(subject) or is_nil(private) ->
        fail("WEB  ", "Web Push needs both :webpush_vapid_subject and :webpush_vapid_private_key")
        ["Web Push: missing VAPID subject or private key" | failures]

      true ->
        case VAPID.resolve_keys(public, private) do
          {:ok, keys} ->
            ok("WEB  ", "Web Push configured (subject #{subject})")

            ok(
              "     ",
              "VAPID key resolves; public key #{Base.url_encode64(keys.public, padding: false) |> String.slice(0, 12)}… (applicationServerKey)"
            )

            failures

          {:error, reason} ->
            fail("WEB  ", "VAPID key: #{reason}")
            ["Web Push VAPID key: #{reason}" | failures]
        end
    end
  end

  # -- Settings -------------------------------------------------------------

  defp print_settings do
    IO.puts("")

    IO.puts(
      "  Delivery: #{Config.delivery()}" <>
        if(Config.delivery() == :test, do: "  ⚠ sends are recorded, not delivered", else: "")
    )

    if Config.retry_enabled?() do
      IO.puts(
        "  Retries:  enabled, #{Config.retry_max_attempts()} attempts, #{Config.retry_base_delay_ms()}ms base delay — " <>
          "a batch task may block up to #{div(Config.batch_timeout_ms(), 1000)}s"
      )
    else
      IO.puts("  Retries:  disabled")
    end

    size = Config.finch_pool_size()

    IO.puts(
      "  Pools:    finch_pool_size #{size}, finch_pool_count #{Config.finch_pool_count()}" <>
        if(size > 5, do: " (consider 2-5 for low traffic on cloud load balancers)", else: "")
    )

    IO.puts(
      "  Breaker:  #{if Config.circuit_breaker_enabled?(), do: "on (threshold #{Config.circuit_breaker_threshold()})", else: "off"}" <>
        "   Rate limit: #{if Config.get(:rate_limit_enabled, false), do: "on", else: "off"}"
    )

    case Config.on_invalid_token() do
      {m, f, a} ->
        IO.puts("  Cleanup:  on_invalid_token → #{inspect(m)}.#{f}/#{length(a) + 2}")

      nil ->
        IO.puts(
          "  Cleanup:  no :on_invalid_token callback (check Response.should_remove_token?/1 yourself)"
        )
    end
  end

  defp ok(label, msg), do: IO.puts("  #{label} ✔ #{msg}")
  defp fail(label, msg), do: IO.puts("  #{label} ✘ #{msg}")
  defp skip(label, msg), do: IO.puts("  #{label} – #{msg}")

  defp version, do: Application.spec(:pushx, :vsn) |> to_string()
end
