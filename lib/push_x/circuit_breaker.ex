defmodule PushX.CircuitBreaker do
  @moduledoc """
  Circuit breaker for push notification providers.

  Tracks consecutive failures per provider and temporarily blocks requests
  when a provider is consistently failing, preventing resource waste on
  dead connections.

  ## States

    * `:closed` — Normal operation, requests flow through
    * `:open` — Provider is failing, requests are rejected immediately
    * `:half_open` — Cooldown expired, one probe request is allowed through

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
  @spec allow?(provider()) :: :ok | {:error, :circuit_open}
  def allow?(provider) do
    if enabled?() do
      do_allow?(provider)
    else
      :ok
    end
  end

  @doc """
  Records a successful request, resetting the circuit to `:closed`.
  """
  @spec record_success(provider()) :: :ok
  def record_success(provider) do
    if enabled?() do
      :ets.insert(@table_name, {provider, :closed, 0, nil})
    end

    :ok
  end

  @doc """
  Records a failed request. Opens the circuit if the failure threshold is reached.
  """
  @spec record_failure(provider()) :: :ok
  def record_failure(provider) do
    if enabled?() do
      do_record_failure(provider)
    end

    :ok
  end

  @doc """
  Returns the current circuit breaker state for a provider.
  """
  @spec state(provider()) :: state()
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
  @spec reset(provider()) :: :ok
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

  defp do_allow?(provider) do
    case :ets.lookup(@table_name, provider) do
      [{^provider, :open, _count, last_failure}] when is_integer(last_failure) ->
        now = System.monotonic_time(:millisecond)

        if now - last_failure >= cooldown_ms() do
          # Transition to half_open, allow one probe
          :ets.insert(@table_name, {provider, :half_open, 0, last_failure})
          :ok
        else
          {:error, :circuit_open}
        end

      [{^provider, :open, _count, _last_failure}] ->
        {:error, :circuit_open}

      _ ->
        # :closed or :half_open — allow request
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
