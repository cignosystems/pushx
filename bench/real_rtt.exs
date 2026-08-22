# Real-RTT load test against the APNS sandbox and/or FCM (and optionally a
# Web Push subscription). Complements bench/send_bench.exs (local stub): this
# one measures what users actually see — provider latency, throughput at a
# given concurrency, retry/connection-error counts, and whether the first
# send after an idle period hits a dead socket (HTTP/2 PING keepalive).
#
# Nothing is delivered unless you give real device tokens: FCM runs with
# validate_only: true (full round trip, no delivery); APNS with a placeholder
# token gets BadDeviceToken back (full TLS + auth + RTT, no delivery).
#
# Credentials come from env vars pointing at files you keep OUT of git
# (priv/keys/ is gitignored). Run from the project root:
#
#     set -a; source priv/keys/load.env; set +a
#     mix run --no-start bench/real_rtt.exs
#
# priv/keys/load.env (all optional per provider — a provider without its
# required vars is skipped):
#
#     PUSHX_APNS_KEY_FILE=priv/keys/AuthKey_XXXX.p8   # APNS auth key (.p8)
#     PUSHX_APNS_KEY_ID=XXXXXXXXXX
#     PUSHX_APNS_TEAM_ID=YYYYYYYYYY
#     PUSHX_APNS_TOPIC=com.example.app                # bundle id of a dev build
#     PUSHX_APNS_TOKENS=hex,hex                       # optional sandbox device tokens
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
#     PUSHX_LOAD_DELIVER=0        1 = real APNS delivery to PUSHX_APNS_TOKENS / FCM
#                                 without validate_only (your devices WILL get pushes)

Logger.configure(level: :warning)

env = fn name, default -> System.get_env(name, default) end
int = fn name, default -> env.(name, default) |> String.to_integer() end
n = int.("PUSHX_LOAD_N", "200")
concurrency = int.("PUSHX_LOAD_CONCURRENCY", "20")
pool_count = int.("PUSHX_LOAD_POOL_COUNT", "2")
idle_s = int.("PUSHX_LOAD_IDLE_S", "0")
deliver? = env.("PUSHX_LOAD_DELIVER", "0") == "1"

split = fn
  nil -> []
  "" -> []
  s -> s |> String.split(",") |> Enum.map(&String.trim/1)
end

# --- Configure PushX from the env (no config/ in this repo) ------------------
Application.put_env(:pushx, :finch_pool_count, pool_count)
Application.put_env(:pushx, :retry_enabled, true)

apns? =
  if env.("PUSHX_APNS_KEY_FILE", nil) do
    Application.put_env(:pushx, :apns_key_id, env.("PUSHX_APNS_KEY_ID", nil))
    Application.put_env(:pushx, :apns_team_id, env.("PUSHX_APNS_TEAM_ID", nil))
    Application.put_env(:pushx, :apns_private_key, {:file, env.("PUSHX_APNS_KEY_FILE", nil)})
    Application.put_env(:pushx, :apns_mode, :sandbox)
    true
  end

fcm? =
  if env.("PUSHX_FCM_CREDENTIALS_FILE", nil) do
    Application.put_env(:pushx, :fcm_project_id, env.("PUSHX_FCM_PROJECT_ID", nil))

    Application.put_env(
      :pushx,
      :fcm_credentials,
      {:file, env.("PUSHX_FCM_CREDENTIALS_FILE", nil)}
    )

    true
  end

webpush? =
  if env.("PUSHX_WEBPUSH_SUBSCRIPTION_FILE", nil) do
    Application.put_env(:pushx, :webpush_vapid_subject, env.("PUSHX_WEBPUSH_VAPID_SUBJECT", nil))

    Application.put_env(
      :pushx,
      :webpush_vapid_private_key,
      env.("PUSHX_WEBPUSH_VAPID_PRIVATE_KEY_FILE", nil) |> File.read!() |> String.trim()
    )

    true
  end

if !(apns? || fcm? || webpush?) do
  IO.puts("Nothing configured — set PUSHX_APNS_* / PUSHX_FCM_* / PUSHX_WEBPUSH_* (see header).")
  System.halt(1)
end

{:ok, _} = Application.ensure_all_started(:pushx)

# --- Targets ------------------------------------------------------------------
apns_tokens =
  case split.(env.("PUSHX_APNS_TOKENS", nil)) do
    [] -> [String.duplicate("ab", 32)]
    toks -> toks
  end

fcm_tokens =
  case split.(env.("PUSHX_FCM_TOKENS", nil)) do
    [] -> ["load-test-placeholder-token-" <> String.duplicate("x", 100)]
    toks -> toks
  end

webpush_sub =
  if webpush?, do: File.read!(env.("PUSHX_WEBPUSH_SUBSCRIPTION_FILE", nil)) |> JSON.decode!()

apns_opts = [topic: env.("PUSHX_APNS_TOPIC", nil), push_type: "background", priority: 5]
fcm_opts = if deliver?, do: [], else: [validate_only: true]
msg = %{"aps" => %{"content-available" => 1}, "load" => "pushx real_rtt"}
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
  def time(fun) do
    t0 = System.monotonic_time(:microsecond)
    result = fun.()
    {System.monotonic_time(:microsecond) - t0, result}
  end

  def pct(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, round(p / 100 * length(sorted))))

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
    "APNS sandbox (#{if hd(apns_tokens) == String.duplicate("ab", 32), do: "placeholder token → expect :invalid_token", else: "#{length(apns_tokens)} device token(s)"})",
    apns_tokens,
    fn t -> {t, PushX.push(:apns, t, msg, apns_opts)} end,
    fn list ->
      PushX.push_batch(:apns, list, msg, Keyword.put(apns_opts, :concurrency, concurrency))
    end
  )
end

if fcm? do
  run.(
    "FCM (#{if fcm_opts[:validate_only], do: "validate_only", else: "DELIVERING"}; #{if String.starts_with?(hd(fcm_tokens), "load-test-placeholder"), do: "placeholder token → expect :invalid_token", else: "#{length(fcm_tokens)} token(s)"})",
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
