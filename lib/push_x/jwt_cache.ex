defmodule PushX.JWTCache do
  @moduledoc since: "0.11.0"
  @moduledoc """
  Cache for short-lived, expensively-derived values: APNS JWTs, per-origin
  VAPID JWTs and resolved VAPID key pairs.

  Reads are lock-free via a public ETS table. On a cache miss, refresh is
  serialized through this GenServer to prevent a thundering-herd of JWT
  generations. If the GenServer crashes, its supervisor restarts it and the
  next call regenerates the token — there is no shared mutex that can be
  left held, so a killed refresher cannot deadlock the cache.
  """

  use GenServer
  require Logger

  @table :pushx_jwt_cache
  @refresh_timeout 10_000

  @type cache_key :: term()

  ## Client API

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Returns a cached token if still fresh, otherwise asks the cache process
  to generate a new one via `generate_fn` and caches it for `ttl_ms`.

  `generate_fn` must return `{:ok, value}` or `{:error, reason}`; only
  `{:ok, _}` results are cached.
  """
  @doc since: "0.11.0"
  @spec get_or_generate(cache_key(), (-> {:ok, term()} | {:error, term()}), pos_integer()) ::
          {:ok, term()} | {:error, term()}
  def get_or_generate(cache_key, generate_fn, ttl_ms)
      when is_function(generate_fn, 0) and is_integer(ttl_ms) and ttl_ms > 0 do
    now = System.system_time(:millisecond)

    case fast_read(cache_key, now) do
      {:ok, _token} = ok ->
        ok

      :miss ->
        GenServer.call(__MODULE__, {:refresh, cache_key, generate_fn, ttl_ms}, @refresh_timeout)
    end
  end

  @doc "Removes a cached entry. Used when an instance is stopped."
  @doc since: "0.11.0"
  @spec invalidate(cache_key()) :: :ok
  def invalidate(cache_key) do
    safe_delete(cache_key)
    :ok
  end

  @doc """
  Removes every entry whose key matches an ETS match pattern, e.g.
  `{:vapid_jwt, :tenant_web, :_}` for all of an instance's per-origin VAPID
  JWTs. Used when an instance is stopped or reconfigured.
  """
  @doc since: "0.15.0"
  @spec invalidate_match(tuple()) :: :ok
  def invalidate_match(pattern) do
    :ets.match_delete(@table, {pattern, :_, :_})
    :ok
  rescue
    ArgumentError -> :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:refresh, cache_key, generate_fn, ttl_ms}, _from, state) do
    now = System.system_time(:millisecond)

    case fast_read(cache_key, now) do
      {:ok, _token} = ok ->
        {:reply, ok, state}

      :miss ->
        case safe_generate(generate_fn) do
          {:ok, token} = ok ->
            :ets.insert(@table, {cache_key, token, now + ttl_ms})
            {:reply, ok, state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end
    end
  end

  ## Private

  # The generator runs caller-supplied code (JWT signing over caller-supplied
  # credentials). This process is shared by every instance, so an exception
  # here must become an error tuple — a crash would destroy the ETS table and
  # every tenant's cached token.
  defp safe_generate(generate_fn) do
    case generate_fn.() do
      {:ok, _token} = ok ->
        ok

      {:error, _reason} = error ->
        error

      other ->
        Logger.error("[PushX.JWTCache] Generator returned an unexpected shape: #{inspect(other)}")
        {:error, {:invalid_generator_result, other}}
    end
  rescue
    e ->
      Logger.error("[PushX.JWTCache] Token generation raised: #{Exception.message(e)}")
      {:error, Exception.message(e)}
  catch
    kind, reason ->
      Logger.error("[PushX.JWTCache] Token generation #{kind}: #{inspect(reason)}")
      {:error, {kind, reason}}
  end

  defp fast_read(cache_key, now) do
    case :ets.lookup(@table, cache_key) do
      [{^cache_key, token, expires_at}] when is_integer(expires_at) and expires_at > now ->
        {:ok, token}

      _ ->
        :miss
    end
  rescue
    ArgumentError -> :miss
  end

  defp safe_delete(cache_key) do
    :ets.delete(@table, cache_key)
  rescue
    ArgumentError -> :ok
  end
end
