defmodule PushX.JWTCacheTest do
  use ExUnit.Case, async: false

  alias PushX.JWTCache

  describe "get_or_generate/3" do
    test "caches the result of generate_fn" do
      key = make_unique_key()
      counter = :counters.new(1, [])

      generate = fn ->
        :counters.add(counter, 1, 1)
        {:ok, "token-#{:counters.get(counter, 1)}"}
      end

      assert {:ok, "token-1"} = JWTCache.get_or_generate(key, generate, 60_000)
      assert {:ok, "token-1"} = JWTCache.get_or_generate(key, generate, 60_000)
      assert :counters.get(counter, 1) == 1
    end

    test "regenerates when the cached entry has expired" do
      key = make_unique_key()
      counter = :counters.new(1, [])

      generate = fn ->
        :counters.add(counter, 1, 1)
        {:ok, "token-#{:counters.get(counter, 1)}"}
      end

      # ttl_ms = 1 means the entry is expired by the next monotonic millisecond
      assert {:ok, "token-1"} = JWTCache.get_or_generate(key, generate, 1)
      Process.sleep(5)
      assert {:ok, "token-2"} = JWTCache.get_or_generate(key, generate, 60_000)
      assert :counters.get(counter, 1) == 2
    end

    test "propagates error from generate_fn" do
      key = make_unique_key()
      generate = fn -> {:error, :boom} end

      assert {:error, :boom} = JWTCache.get_or_generate(key, generate, 60_000)
    end

    test "concurrent callers do not generate more than once on cold cache" do
      key = make_unique_key()
      counter = :counters.new(1, [])

      generate = fn ->
        :counters.add(counter, 1, 1)
        # Simulate slow generation so callers actually queue.
        Process.sleep(20)
        {:ok, "shared-token"}
      end

      tasks =
        for _ <- 1..20 do
          Task.async(fn -> JWTCache.get_or_generate(key, generate, 60_000) end)
        end

      results = Task.await_many(tasks, 5_000)

      assert Enum.all?(results, &match?({:ok, "shared-token"}, &1))
      assert :counters.get(counter, 1) == 1
    end

    test "converts a raising generate_fn into an error tuple without crashing" do
      key = make_unique_key()
      pid = Process.whereis(PushX.JWTCache)

      assert {:error, "kaboom"} =
               JWTCache.get_or_generate(key, fn -> raise "kaboom" end, 60_000)

      # The cache process survived (same pid, no supervisor restart) and the
      # ETS table with every other entry is intact.
      assert Process.whereis(PushX.JWTCache) == pid
      assert {:ok, "ok"} = JWTCache.get_or_generate(key, fn -> {:ok, "ok"} end, 60_000)
    end

    test "converts a throwing generate_fn into an error tuple without crashing" do
      key = make_unique_key()
      pid = Process.whereis(PushX.JWTCache)

      assert {:error, {:throw, :kaboom}} =
               JWTCache.get_or_generate(key, fn -> throw(:kaboom) end, 60_000)

      assert Process.whereis(PushX.JWTCache) == pid
    end

    test "converts a generate_fn returning a bad shape into an error tuple" do
      key = make_unique_key()

      assert {:error, {:invalid_generator_result, :oops}} =
               JWTCache.get_or_generate(key, fn -> :oops end, 60_000)
    end
  end

  describe "invalidate/1" do
    test "drops the cached entry so the next call regenerates" do
      key = make_unique_key()
      counter = :counters.new(1, [])

      generate = fn ->
        :counters.add(counter, 1, 1)
        {:ok, "v#{:counters.get(counter, 1)}"}
      end

      assert {:ok, "v1"} = JWTCache.get_or_generate(key, generate, 60_000)
      assert :ok = JWTCache.invalidate(key)
      assert {:ok, "v2"} = JWTCache.get_or_generate(key, generate, 60_000)
    end
  end

  defp make_unique_key, do: {:test, :erlang.unique_integer([:positive])}
end
