defmodule PushX.CircuitBreaker do
  @moduledoc """
  Circuit breaker for push notification providers.

  Tracks consecutive failures per provider and temporarily blocks requests
  when a provider is consistently failing, preventing resource waste on
  dead connections.

  ## States

    * `:closed` — Normal operation, requests flow through
    * `:open` — Provider is failing, requests are rejected immediately
    * `:half_open` — Cooldown expired, exactly one probe request is allowed
      through (others are rejected until the probe reports back; if the
      probe never reports, another probe is admitted after a full cooldown)

  ## Configuration

      config :pushx,
        circuit_breaker_enabled: true,
        circuit_breaker_threshold: 5,       # consecutive failures to open
        circuit_breaker_cooldown_ms: 30_000  # ms before half_open

  ## Usage

  The circuit breaker is checked automatically in `APNS.send_once/3` and
  `FCM.send_once/3` when enabled. You can also check manually:

      case PushX.CircuitBreaker.allow?(:apns) do
        :ok -> # Proceed
        {:error, :circuit_open} -> # Provider is down
      end

  """

  use GenServer
  require Logger

  @table_name :pushx_circuit_breaker

  @type provider :: :apns | :fcm
  # Breakers are also keyed by named-instance atoms (per-tenant pools have
  # independent health), so every entry point accepts any atom key.
  @type key :: atom()
  @type state :: :closed | :open | :half_open

  ## Client API

  @doc """
  Starts the circuit breaker process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks if a request is allowed for the given provider.

  Returns `:ok` if the circuit is closed or half-open (probe),
  `{:error, :circuit_open}` if the circuit is open.
  """
  @spec allow?(key()) :: :ok | {:error, :circuit_open}
  def allow?(provider) do
    if enabled?() do
      do_allow?(provider)
    else
      :ok
    end
  end

  @doc """
  Records a successful request, resetting the circuit to `:closed`.

  The write is serialized through the GenServer so concurrent successes
  and failures cannot lose updates via ETS read-modify-write.
  """
  @spec record_success(key()) :: :ok
  def record_success(provider) do
    if enabled?() do
      GenServer.call(__MODULE__, {:record_success, provider})
    end

    :ok
  end

  @doc """
  Records a failed request. Opens the circuit if the failure threshold is reached.

  Serialized through the GenServer.
  """
  @spec record_failure(key()) :: :ok
  def record_failure(provider) do
    if enabled?() do
      GenServer.call(__MODULE__, {:record_failure, provider})
    end

    :ok
  end

  @doc """
  Returns the current circuit breaker state for a provider.
  """
  @spec state(key()) :: state()
  def state(provider) do
    case :ets.lookup(@table_name, provider) do
      [{^provider, current_state, _count, last_failure}] ->
        maybe_transition_to_half_open(current_state, last_failure)

      _ ->
        :closed
    end
  end

  @doc """
  Resets the circuit breaker for a provider. Useful for testing or manual recovery.
  """
  @spec reset(key()) :: :ok
  def reset(provider) do
    :ets.insert(@table_name, {provider, :closed, 0, nil})
    :ok
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    table = :ets.new(@table_name, [:named_table, :public, :set])
    # {provider, state, failure_count, last_failure_time}
    :ets.insert(table, {:apns, :closed, 0, nil})
    :ets.insert(table, {:fcm, :closed, 0, nil})

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:record_failure, provider}, _from, state) do
    do_record_failure(provider)
    {:reply, :ok, state}
  end

  def handle_call({:record_success, provider}, _from, state) do
    :ets.insert(@table_name, {provider, :closed, 0, nil})
    {:reply, :ok, state}
  end

  # Serialized open→half_open transition: exactly one caller is granted the
  # probe. Re-checks state under the GenServer because the caller's ETS read
  # happened outside it.
  def handle_call({:try_half_open, key}, _from, state) do
    now = System.monotonic_time(:millisecond)
    cooldown = cooldown_ms()

    reply =
      case :ets.lookup(@table_name, key) do
        [{^key, :open, count, last}] when is_integer(last) and now - last >= cooldown ->
          # This caller becomes the probe; the 4th field now records when the
          # probe was granted so a vanished probe can be replaced later.
          :ets.insert(@table_name, {key, :half_open, count, now})
          :ok

        [{^key, :half_open, count, since}]
        when is_integer(since) and now - since >= cooldown ->
          # The previous probe never reported back (task killed, node issue).
          # Admit a replacement rather than staying wedged forever.
          :ets.insert(@table_name, {key, :half_open, count, now})
          :ok

        [{^key, :open, _count, _last}] ->
          {:error, :circuit_open}

        [{^key, :half_open, _count, _since}] ->
          {:error, :circuit_open}

        _ ->
          # :closed (e.g. the probe already succeeded) — allow
          :ok
      end

    {:reply, reply, state}
  end

  ## Private Functions

  defp enabled? do
    PushX.Config.get(:circuit_breaker_enabled, false)
  end

  defp threshold do
    PushX.Config.get(:circuit_breaker_threshold, 5)
  end

  defp cooldown_ms do
    PushX.Config.get(:circuit_breaker_cooldown_ms, 30_000)
  end

  # Fast path: lock-free ETS read. Only the rare open→half_open transition
  # (and stale-probe replacement) is routed through the GenServer, which
  # guarantees exactly one probe is admitted.
  defp do_allow?(provider) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, provider) do
      [{^provider, :open, _count, last_failure}] when is_integer(last_failure) ->
        if now - last_failure >= cooldown_ms() do
          GenServer.call(__MODULE__, {:try_half_open, provider})
        else
          {:error, :circuit_open}
        end

      [{^provider, :open, _count, _last_failure}] ->
        {:error, :circuit_open}

      [{^provider, :half_open, _count, since}] when is_integer(since) ->
        if now - since >= cooldown_ms() do
          # Previous probe went silent; ask the GenServer for a replacement.
          GenServer.call(__MODULE__, {:try_half_open, provider})
        else
          # A probe is in flight — everyone else waits.
          {:error, :circuit_open}
        end

      _ ->
        # :closed — allow request
        :ok
    end
  end

  defp do_record_failure(provider) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table_name, provider) do
      [{^provider, :half_open, _count, _last}] ->
        # Probe failed, go back to open
        :ets.insert(@table_name, {provider, :open, threshold(), now})
        Logger.warning("[PushX.CircuitBreaker] #{provider} circuit re-opened (probe failed)")

      [{^provider, _state, count, _last}] ->
        new_count = count + 1

        if new_count >= threshold() do
          :ets.insert(@table_name, {provider, :open, new_count, now})

          Logger.warning(
            "[PushX.CircuitBreaker] #{provider} circuit opened after #{new_count} failures"
          )
        else
          :ets.insert(@table_name, {provider, :closed, new_count, now})
        end

      _ ->
        :ets.insert(@table_name, {provider, :closed, 1, now})
    end
  end

  defp maybe_transition_to_half_open(:open, last_failure) when is_integer(last_failure) do
    now = System.monotonic_time(:millisecond)

    if now - last_failure >= cooldown_ms() do
      :half_open
    else
      :open
    end
  end

  defp maybe_transition_to_half_open(state, _last_failure), do: state
end
