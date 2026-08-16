# PushX micro-benchmark: per-send overhead and batch throughput against a
# local HTTP stub (so network RTT is ~0 and PushX's own cost is visible).
#
# Run from the project root:
#
#     MIX_ENV=test mix run bench/send_bench.exs
#
# (MIX_ENV=test so Plug.Cowboy — a test-only dependency — is available.)
# This is a regression baseline, not a load test: real throughput is bound by
# provider RTT (30–150 ms) × concurrency, not by anything measured here.
#
# Baseline on a 14-scheduler laptop (2026-08, v0.13.0):
#   PushX overhead over a raw Finch POST: ~6 µs per send
#   push_batch, 5 000 tokens, concurrency 10–200: ~35–37k sends/s (stub-bound)

Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:plug_cowboy)

# --- Stub provider -----------------------------------------------------------
defmodule PushX.Bench.Stub do
  import Plug.Conn
  def init(o), do: o

  def call(%{request_path: "/3/device/" <> _} = conn, _),
    do: conn |> put_resp_header("apns-id", "bench") |> send_resp(200, "")

  def call(conn, _), do: send_resp(conn, 200, ~s({"name":"bench"}))
end

defmodule PushX.Bench.OAuth do
  def fetch(_goth_name), do: {:ok, %{token: "bench-token"}}
end

{:ok, _} = Plug.Cowboy.http(PushX.Bench.Stub, [], port: 0)
port = :ranch.get_port(PushX.Bench.Stub.HTTP)
url = "http://localhost:#{port}"

# --- Config: throwaway APNS key, stub OAuth, no retries, stub URLs ----------
apns_pem =
  {:namedCurve, :secp256r1}
  |> :public_key.generate_key()
  |> then(&:public_key.pem_entry_encode(:ECPrivateKey, &1))
  |> List.wrap()
  |> :public_key.pem_encode()

for {k, v} <- [
      apns_key_id: "BENCH",
      apns_team_id: "BENCH",
      apns_private_key: apns_pem,
      fcm_project_id: "bench",
      fcm_token_fetcher: {PushX.Bench.OAuth, :fetch, []},
      retry_enabled: false,
      apns_url_override: url,
      fcm_url_override: url
    ],
    do: Application.put_env(:pushx, k, v)

# --- Warm-up (JWT cache, connections) ---------------------------------------
for _ <- 1..100, do: {:ok, _} = PushX.push(:apns, "tok", "hi", topic: "bench")
for _ <- 1..100, do: {:ok, _} = PushX.push(:fcm, "tok", "hi")

finch = PushX.Config.finch_name()

raw_apns = fn ->
  Finch.build(
    :post,
    url <> "/3/device/tok",
    [{"authorization", "bearer x"}, {"apns-topic", "bench"}],
    ~s({"aps":{"alert":{"title":"hi","body":""}}})
  )
  |> Finch.request(finch)
end

for _ <- 1..100, do: {:ok, _} = raw_apns.()

# --- Sequential per-send cost -----------------------------------------------
n = 2_000
per_call = fn f -> :timer.tc(fn -> for _ <- 1..n, do: f.() end) |> elem(0) |> Kernel./(n) end

raw = per_call.(raw_apns)
apns = per_call.(fn -> {:ok, _} = PushX.push(:apns, "tok", "hi", topic: "bench") end)
fcm = per_call.(fn -> {:ok, _} = PushX.push(:fcm, "tok", "hi") end)

IO.puts("Sequential, per send (n=#{n}):")
IO.puts("  raw Finch POST to stub : #{Float.round(raw, 1)} µs")

IO.puts(
  "  PushX.push(:apns)      : #{Float.round(apns, 1)} µs  (overhead #{Float.round(apns - raw, 1)} µs)"
)

IO.puts(
  "  PushX.push(:fcm)       : #{Float.round(fcm, 1)} µs  (overhead #{Float.round(fcm - raw, 1)} µs)"
)

# --- In-process building blocks --------------------------------------------
msg =
  PushX.Message.new("hi", "there") |> PushX.Message.badge(1) |> PushX.Message.data(%{"k" => "v"})

reps = 100_000

block = fn label, f ->
  us = :timer.tc(fn -> for _ <- 1..reps, do: f.() end) |> elem(0)
  IO.puts("  #{label}: #{Float.round(us / reps, 2)} µs")
end

IO.puts("In-process building blocks (per call):")

block.("Message.to_apns_payload + JSON.encode", fn ->
  JSON.encode!(PushX.Message.to_apns_payload(msg))
end)

block.("FCM.build_message + JSON.encode      ", fn ->
  JSON.encode!(PushX.FCM.build_message("tok", msg, []))
end)

block.("JWTCache hit                          ", fn ->
  PushX.JWTCache.get_or_generate(:apns_jwt, fn -> {:ok, "x"} end, 3_000_000)
end)

block.("SendGate.check (breaker+limiter off)  ", fn -> PushX.SendGate.check(:apns, :apns) end)

block.("Token.validate(:apns)                 ", fn ->
  PushX.Token.validate(:apns, String.duplicate("ab", 32))
end)

# --- Batch throughput --------------------------------------------------------
tokens = List.duplicate("tok", 5_000)

for c <- [10, 50, 200] do
  {us, results} =
    :timer.tc(fn -> PushX.push_batch(:apns, tokens, "hi", topic: "bench", concurrency: c) end)

  ok = Enum.count(results, &match?({_, {:ok, _}}, &1))

  IO.puts(
    "push_batch 5000 tokens, concurrency #{c}: #{round(us / 1000)} ms → #{round(5_000 / (us / 1_000_000))} sends/s (#{ok} ok)"
  )
end

{us, _} =
  :timer.tc(fn ->
    PushX.push_batch_stream(:apns, tokens, "hi", topic: "bench", concurrency: 50) |> Stream.run()
  end)

IO.puts(
  "push_batch_stream 5000 tokens, concurrency 50: #{round(us / 1000)} ms → #{round(5_000 / (us / 1_000_000))} sends/s"
)

IO.puts("schedulers: #{System.schedulers_online()}")
