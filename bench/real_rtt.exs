# Real-RTT load test against the APNS sandbox and/or FCM (and optionally a
# Web Push subscription). Complements bench/send_bench.exs (local stub): this
# one measures what users actually see — provider latency, throughput at a
# given concurrency, retry/connection-error counts, and whether the first
# send after an idle period hits a dead socket (HTTP/2 PING keepalive).
#
# What gets delivered:
#   - FCM runs with validate_only: true by default (full round trip, no
#     delivery); PUSHX_LOAD_DELIVER=1 turns that off. This knob is FCM-only.
#   - APNS has no dry-run mode. A placeholder token gets BadDeviceToken back
#     (full TLS + auth + RTT, nothing delivered), but real tokens in
#     PUSHX_APNS_TOKENS receive real (silent background) pushes on EVERY run
#     — regardless of PUSHX_LOAD_DELIVER — and a run burns a few hundred of
#     Apple's per-device background-push budget.
#   - Web Push always delivers to the subscription's browser.
#
# Credentials come from env vars pointing at files you keep OUT of git
# (priv/keys/ is gitignored). Run from the project root — the --no-start is
# required (the script checks) so the config below is applied before PushX
# boots:
#
#     set -a; source priv/keys/load.env; set +a
#     mix run --no-start bench/real_rtt.exs
#
# priv/keys/load.env — each provider is optional, but all-or-nothing: a
# provider with none of its vars set is skipped; one with some-but-not-all
# aborts the run (a half-configured provider would fail locally and print
# meaningless 0ms "RTTs"). Empty values count as unset.
#
#     PUSHX_APNS_KEY_FILE=priv/keys/AuthKey_XXXX.p8   # APNS auth key (.p8)
#     PUSHX_APNS_KEY_ID=XXXXXXXXXX
#     PUSHX_APNS_TEAM_ID=YYYYYYYYYY
#     PUSHX_APNS_TOPIC=com.example.app                # bundle id of a dev build
#     PUSHX_APNS_TOKENS=hex,hex                       # optional sandbox device tokens (real delivery!)
#     PUSHX_FCM_CREDENTIALS_FILE=priv/keys/firebase.json   # service account
#     PUSHX_FCM_PROJECT_ID=my-project
#     PUSHX_FCM_TOKENS=tok,tok                        # optional registration tokens
#     PUSHX_WEBPUSH_SUBSCRIPTION_FILE=priv/keys/sub.json   # optional: browser subscription JSON
#     PUSHX_WEBPUSH_VAPID_SUBJECT=mailto:ops@example.com   # with a VAPID key the sub was made for:
#     PUSHX_WEBPUSH_VAPID_PRIVATE_KEY_FILE=priv/keys/vapid.key
#
# Knobs:
#     PUSHX_LOAD_N=200            sends per provider in the batch phase
#     PUSHX_LOAD_CONCURRENCY=20   batch concurrency
#     PUSHX_LOAD_POOL_COUNT=2     finch_pool_count (HTTP/2 connections per origin)
#     PUSHX_LOAD_IDLE_S=0         seconds to sleep before the final "after idle" send
#                                 (try 120–600 on Fly/AWS/GCP to test the PING keepalive)
#     PUSHX_LOAD_DELIVER=0        1 = FCM sends without validate_only (FCM-only;
#                                 your devices WILL get pushes). Has no effect on
#                                 APNS — see "What gets delivered" above.

Logger.configure(level: :warning)

# The config below must land before PushX boots; under plain `mix run` the
# app is already up, finch_pool_count would be silently ignored, and FCM
# would have no Goth process (retry storms that look like provider trouble).
if List.keymember?(Application.started_applications(), :pushx, 0) do
  IO.puts("PushX is already running — use:  mix run --no-start bench/real_rtt.exs")
  System.halt(1)
end

# Unset and empty/whitespace env values both count as "not set".
env = fn name ->
  case System.get_env(name) do
    nil -> nil
    s -> if String.trim(s) == "", do: nil, else: String.trim(s)
  end
end

int = fn name, default -> String.to_integer(env.(name) || default) end
n = int.("PUSHX_LOAD_N", "200")
concurrency = int.("PUSHX_LOAD_CONCURRENCY", "20")
pool_count = int.("PUSHX_LOAD_POOL_COUNT", "2")
idle_s = int.("PUSHX_LOAD_IDLE_S", "0")
deliver? = env.("PUSHX_LOAD_DELIVER") == "1"

split = fn
  nil -> []
  s -> s |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
end

# A provider is enabled only with its full var set: none → skipped, a strict
# subset → abort (every send would fail in-process with no network I/O, and
# the percentiles would measure local rejections in microseconds).
check_vars = fn provider, vars ->
  set = Enum.filter(vars, &env.(&1))

  cond do
    set == [] ->
      false

    length(set) == length(vars) ->
      true

    true ->
      IO.puts("#{provider}: missing #{Enum.join(vars -- set, ", ")} (set all of them or none).")
      System.halt(1)
  end
end

# --- Configure PushX from the env (no config/ in this repo) ------------------
Application.put_env(:pushx, :finch_pool_count, pool_count)
Application.put_env(:pushx, :retry_enabled, true)

apns? =
  check_vars.(
    "APNS",
    ~w(PUSHX_APNS_KEY_FILE PUSHX_APNS_KEY_ID PUSHX_APNS_TEAM_ID PUSHX_APNS_TOPIC)
  ) &&
    (
      Application.put_env(:pushx, :apns_key_id, env.("PUSHX_APNS_KEY_ID"))
      Application.put_env(:pushx, :apns_team_id, env.("PUSHX_APNS_TEAM_ID"))
      Application.put_env(:pushx, :apns_private_key, {:file, env.("PUSHX_APNS_KEY_FILE")})
      Application.put_env(:pushx, :apns_mode, :sandbox)
      true
    )

fcm? =
  check_vars.("FCM", ~w(PUSHX_FCM_CREDENTIALS_FILE PUSHX_FCM_PROJECT_ID)) &&
    (
      Application.put_env(:pushx, :fcm_project_id, env.("PUSHX_FCM_PROJECT_ID"))
      Application.put_env(:pushx, :fcm_credentials, {:file, env.("PUSHX_FCM_CREDENTIALS_FILE")})
      true
    )

webpush? =
  check_vars.(
    "Web Push",
    ~w(PUSHX_WEBPUSH_SUBSCRIPTION_FILE PUSHX_WEBPUSH_VAPID_SUBJECT PUSHX_WEBPUSH_VAPID_PRIVATE_KEY_FILE)
  ) &&
    (
      Application.put_env(:pushx, :webpush_vapid_subject, env.("PUSHX_WEBPUSH_VAPID_SUBJECT"))

      Application.put_env(
        :pushx,
        :webpush_vapid_private_key,
        env.("PUSHX_WEBPUSH_VAPID_PRIVATE_KEY_FILE") |> File.read!() |> String.trim()
      )

      true
    )

if !(apns? || fcm? || webpush?) do
  IO.puts("Nothing configured — set PUSHX_APNS_* / PUSHX_FCM_* / PUSHX_WEBPUSH_* (see header).")
  System.halt(1)
end

{:ok, _} = Application.ensure_all_started(:pushx)

# --- Targets ------------------------------------------------------------------
apns_placeholder = String.duplicate("ab", 32)

apns_tokens =
  case split.(env.("PUSHX_APNS_TOKENS")) do
    [] -> [apns_placeholder]
    toks -> toks
  end

fcm_placeholder = "load-test-placeholder-token-" <> String.duplicate("x", 100)

fcm_tokens =
  case split.(env.("PUSHX_FCM_TOKENS")) do
    [] -> [fcm_placeholder]
    toks -> toks
  end

webpush_sub =
  if webpush?, do: File.read!(env.("PUSHX_WEBPUSH_SUBSCRIPTION_FILE")) |> JSON.decode!()

apns_opts = [topic: env.("PUSHX_APNS_TOPIC"), push_type: "background", priority: 5]
fcm_opts = if deliver?, do: [], else: [validate_only: true]
msg = PushX.APNS.silent_notification(%{"load" => "pushx real_rtt"})
fcm_msg = PushX.Message.new("PushX load test", "validate_only unless PUSHX_LOAD_DELIVER=1")

# --- Telemetry counters -------------------------------------------------------
{:ok, counters} = Agent.start_link(fn -> %{retries: 0, errors: %{}} end)

:telemetry.attach_many(
  "real-rtt",
  [[:pushx, :retry, :attempt], [:pushx, :push, :error]],
  fn
    [:pushx, :retry, :attempt], m, meta, _ ->
      Agent.update(counters, &update_in(&1.retries, fn r -> r + 1 end))

      IO.puts("  retry: #{meta.provider} #{meta.status} attempt #{m.attempt} (#{m.delay_ms}ms)")

    [:pushx, :push, :error], _m, meta, _ ->
      Agent.update(
        counters,
        &update_in(&1.errors, fn e ->
          Map.update(e, {meta.provider, meta.status}, 1, fn c -> c + 1 end)
        end)
      )
  end,
  nil
)

# --- Helpers ------------------------------------------------------------------
defmodule RTT do
  def time(fun), do: :timer.tc(fun)

  # Nearest-rank percentile: the smallest sample with at least p% of the
  # data at or below it (index ceil(p/100 * n) - 1 into the sorted list).
  def pct(sorted, p),
    do: Enum.at(sorted, max(ceil(p / 100 * length(sorted)) - 1, 0))

  def summarize(label, micros) do
    s = Enum.sort(micros)
    ms = fn v -> :erlang.float_to_binary(v / 1000, decimals: 1) end

    IO.puts(
      "  #{label}: n=#{length(s)} p50=#{ms.(pct(s, 50))}ms p90=#{ms.(pct(s, 90))}ms " <>
        "p99=#{ms.(pct(s, 99))}ms max=#{ms.(Enum.max(s))}ms"
    )
  end

  def status_of({_target, {_, %PushX.Response{status: s}}}), do: s
  def status_of({_, %PushX.Response{status: s}}), do: s

  def tally(results) do
    results
    |> Enum.map(&status_of/1)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {_, c} -> -c end)
    |> Enum.map_join(", ", fn {s, c} -> "#{s}=#{c}" end)
  end
end

run = fn label, targets, send_one, batch ->
  IO.puts("\n== #{label} ==")

  # 1. cold start (new connection + JWT/OAuth), then serial latency
  {cold, r} = RTT.time(fn -> send_one.(hd(targets)) end)
  IO.puts("  cold send: #{div(cold, 1000)}ms → #{RTT.status_of(r)}")

  serial =
    for i <- 1..20,
        do: elem(RTT.time(fn -> send_one.(Enum.at(targets, rem(i, length(targets)))) end), 0)

  RTT.summarize("serial (warm)", serial)

  # 2. batch at concurrency
  list = Stream.cycle(targets) |> Enum.take(n)
  {elapsed, results} = RTT.time(fn -> batch.(list) end)

  IO.puts(
    "  batch: #{n} sends, concurrency #{concurrency}, pool_count #{pool_count}: " <>
      "#{Float.round(n / (elapsed / 1_000_000), 1)} sends/s over #{div(elapsed, 1000)}ms → #{RTT.tally(results)}"
  )

  # 3. after idle — does the first send pay for a dead socket?
  if idle_s > 0 do
    IO.puts("  sleeping #{idle_s}s idle …")
    Process.sleep(idle_s * 1000)
    {after_idle, r} = RTT.time(fn -> send_one.(hd(targets)) end)

    IO.puts(
      "  first send after #{idle_s}s idle: #{div(after_idle, 1000)}ms → #{RTT.status_of(r)} (serial p50 was #{div(RTT.pct(Enum.sort(serial), 50), 1000)}ms)"
    )
  end
end

if apns? do
  run.(
    "APNS sandbox (#{if hd(apns_tokens) == apns_placeholder, do: "placeholder token → expect :invalid_token", else: "#{length(apns_tokens)} device token(s) — REAL background pushes will be delivered"})",
    apns_tokens,
    fn t -> {t, PushX.push(:apns, t, msg, apns_opts)} end,
    fn list ->
      PushX.push_batch(:apns, list, msg, Keyword.put(apns_opts, :concurrency, concurrency))
    end
  )
end

if fcm? do
  run.(
    "FCM (#{if fcm_opts[:validate_only], do: "validate_only", else: "DELIVERING"}; #{if hd(fcm_tokens) == fcm_placeholder, do: "placeholder token → expect :invalid_request/:unregistered", else: "#{length(fcm_tokens)} token(s)"})",
    fcm_tokens,
    fn t -> {t, PushX.push(:fcm, t, fcm_msg, fcm_opts)} end,
    fn list ->
      PushX.push_batch(:fcm, list, fcm_msg, Keyword.put(fcm_opts, :concurrency, concurrency))
    end
  )
end

if webpush? do
  run.(
    "Web Push (1 subscription; the browser WILL receive these)",
    [webpush_sub],
    fn s -> {s, PushX.push(:webpush, s, %{"title" => "PushX load test"}, ttl: 60)} end,
    fn list ->
      PushX.push_batch(:webpush, list, %{"title" => "PushX load test"},
        ttl: 60,
        concurrency: concurrency
      )
    end
  )
end

%{retries: retries, errors: errors} = Agent.get(counters, & &1)
IO.puts("\nretries: #{retries}; error events: #{inspect(errors)}")
IO.puts("health: #{inspect(PushX.health_check() |> Map.take([:apns, :fcm, :webpush]))}")
