defmodule PushX.Instance.Loader do
  @moduledoc """
  Starts named instances on boot from your own source of truth.

  `PushX.Instance` instances live in memory only (see `PushX.Instance` —
  "Lifecycle"), so after a node restart your application has to start them
  again. Put the loader in your supervision tree **after** whatever it reads
  from (typically your `Repo`) and give it a function that returns the
  instances to start:

      # application.ex
      children = [
        MyApp.Repo,
        {PushX.Instance.Loader, instances: &MyApp.Push.tenant_instances/0},
        MyAppWeb.Endpoint
      ]

      # MyApp.Push
      def tenant_instances do
        for tenant <- Tenants.with_push_credentials() do
          {:"tenant_\#{tenant.id}_apns", :apns,
           key_id: tenant.apns_key_id,
           team_id: tenant.apns_team_id,
           private_key: tenant.apns_private_key,
           mode: :prod}
        end
      end

  The loader runs **synchronously during boot**: `start_link/1` calls
  `load/1`, logs the outcome, and returns `:ignore` (it keeps no process
  around), so by the time the next child starts the instances exist. Each
  instance is started with `PushX.Instance.start/3`; one tenant's bad
  credentials are logged and skipped rather than stopping the application —
  pass `on_error: :raise` if you would rather fail the boot.

  ## Options

    * `:instances` — (required) a list of `{name, provider, config}` tuples,
      or a 0-arity function / `{module, function, args}` that returns one.
      Called at load time, after earlier children (your Repo) are up.
    * `:on_error` — `:log` (default) logs each failure and continues;
      `:raise` raises after attempting all instances, with every failure in
      the message (the supervisor then fails to start — use this when a
      missing tenant must stop the deploy).

  Later provisioning (a new tenant signs up) is just `PushX.Instance.start/3`
  from your own code; the loader is for boot. To re-run it at any time call
  `load/1` — instances that are already running are reported as such, not
  restarted.
  """

  require Logger

  @type spec :: {atom(), :apns | :fcm, keyword()}
  @type result :: %{
          started: [atom()],
          already_running: [atom()],
          failed: [{atom(), term()}]
        }

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      # Never restarted: it runs once, synchronously, and exits with :ignore.
      restart: :temporary,
      type: :worker
    }
  end

  @doc """
  Runs `load/1` synchronously and returns `:ignore` (no process is kept).
  Raises if `on_error: :raise` and any instance failed to start.
  """
  @spec start_link(keyword()) :: :ignore
  def start_link(opts) do
    result = load(opts)

    if Keyword.get(opts, :on_error, :log) == :raise and result.failed != [] do
      raise "PushX.Instance.Loader: #{length(result.failed)} instance(s) failed to start: " <>
              Enum.map_join(result.failed, "; ", fn {name, reason} ->
                "#{inspect(name)} → #{inspect(reason)}"
              end)
    end

    :ignore
  end

  @doc """
  Starts every instance returned by `:instances` and reports what happened.

  Instances that are already running count as `:already_running` (so
  re-running the loader is safe); any other `PushX.Instance.start/3` error
  lands in `:failed` with its reason and is logged at error level.
  """
  @spec load(keyword()) :: result()
  def load(opts) do
    specs = resolve_specs(Keyword.fetch!(opts, :instances))

    result =
      Enum.reduce(specs, %{started: [], already_running: [], failed: []}, fn
        {name, provider, config}, acc
        when is_atom(name) and provider in [:apns, :fcm] and is_list(config) ->
          case PushX.Instance.start(name, provider, config) do
            {:ok, ^name} ->
              %{acc | started: [name | acc.started]}

            {:error, :already_started} ->
              %{acc | already_running: [name | acc.already_running]}

            {:error, reason} ->
              Logger.error(
                "[PushX.Instance.Loader] Could not start #{inspect(provider)} instance #{inspect(name)}: #{inspect(reason)}"
              )

              %{acc | failed: [{name, reason} | acc.failed]}
          end

        other, acc ->
          Logger.error(
            "[PushX.Instance.Loader] Invalid instance spec #{inspect(other)}: expected {name, :apns | :fcm, config}"
          )

          %{acc | failed: [{other, :invalid_spec} | acc.failed]}
      end)

    result = %{
      started: Enum.reverse(result.started),
      already_running: Enum.reverse(result.already_running),
      failed: Enum.reverse(result.failed)
    }

    Logger.info(
      "[PushX.Instance.Loader] started #{length(result.started)}, already running #{length(result.already_running)}, failed #{length(result.failed)}"
    )

    result
  end

  defp resolve_specs(fun) when is_function(fun, 0), do: fun.()
  defp resolve_specs({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: apply(m, f, a)
  defp resolve_specs(list) when is_list(list), do: list
end
