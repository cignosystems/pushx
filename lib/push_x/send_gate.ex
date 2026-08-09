defmodule PushX.SendGate do
  @moduledoc false

  # Shared circuit-breaker + rate-limiter gate for every send path. The
  # static paths (PushX.APNS / PushX.FCM) gate on the provider atom; named
  # instances gate on their instance name so one tenant's failing pool
  # cannot open the breaker for other tenants, while rate limits come from
  # the provider-level config. Centralized here so protections cannot drift
  # between the static and instance paths again.

  alias PushX.{CircuitBreaker, RateLimiter, Response}

  @doc """
  Checks the circuit breaker and rate limiter for `key`.

  Returns `:ok`, or `{:error, %Response{}}` ready to hand back to the caller.
  `key` is the provider atom for static sends or the instance name for
  instance sends; `provider` (`:apns` | `:fcm`) selects the rate-limit
  config and stamps the error response.
  """
  @spec check(atom(), :apns | :fcm) :: :ok | {:error, Response.t()}
  def check(key, provider) do
    with :ok <- CircuitBreaker.allow?(key),
         :ok <- RateLimiter.check_and_increment(key, provider) do
      :ok
    else
      {:error, :circuit_open} ->
        {:error, Response.error(provider, :circuit_open, "Circuit breaker is open")}

      {:error, :rate_limited} ->
        {:error, Response.error(provider, :rate_limited, "Client-side rate limit exceeded")}
    end
  end

  @doc """
  Feeds a send result back into the circuit breaker for `key`.
  """
  @spec record(atom(), {:ok, Response.t()} | {:error, Response.t()} | term()) :: :ok
  def record(key, {:error, %Response{status: status}})
      when status in [:connection_error, :server_error] do
    CircuitBreaker.record_failure(key)
  end

  def record(key, {:ok, _response}) do
    CircuitBreaker.record_success(key)
  end

  def record(_key, _result), do: :ok
end
