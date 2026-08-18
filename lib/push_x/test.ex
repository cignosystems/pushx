defmodule PushX.Test do
  @moduledoc """
  Test delivery mode: assert what your application pushed without touching
  APNS or FCM.

  Set `delivery: :test` in your test config and every send — `PushX.push/4`,
  `push_data/4`, batches, `PushX.APNS`/`PushX.FCM` directly, and named
  instances — is validated exactly as in production (required `:topic`,
  target format, `:mode`, payload encoding and size limits) and then
  **recorded and answered locally** with `{:ok, %PushX.Response{status: :sent}}`
  instead of being sent. No credentials are needed; retries, the circuit
  breaker and rate limiter are not involved.

      # config/test.exs
      config :pushx, delivery: :test

  Recorded pushes are scoped to the **test process**: a test only sees the
  pushes made by itself and by processes it started (`Task`, `Task.Supervisor`
  children including `push_batch/4` workers, and anything else that carries
  `$callers`), so `async: true` tests do not interfere.

  ## Asserting

      use ExUnit.Case, async: true
      import PushX.Test.Assertions

      test "order shipped notifies the customer" do
        MyApp.Orders.ship(order)

        push = assert_pushed(%{provider: :apns, target: ^device_token})
        assert push.payload["aps"]["alert"]["title"] == "Order shipped"
        assert push.opts[:topic] == "com.example.app"

        refute_pushed(%{provider: :fcm})
      end

  `assert_pushed/1` and `refute_pushed/1` take a pattern (pins allowed) that
  is matched against each recorded `t:PushX.Test.Push.t/0`; `pushes/0` returns
  the raw list when you'd rather filter yourself.

  ## Scripting failures

  Use `stub/1` to make specific pushes fail — the idiomatic way to test token
  cleanup, since `:on_invalid_token` and `PushX.Response.should_remove_token?/1`
  behave exactly as with a real provider response:

      test "dead tokens are deleted" do
        PushX.Test.stub(fn
          %{target: "dead-token"} -> {:error, :unregistered}
          _push -> :ok
        end)

        MyApp.Notifier.broadcast("Hi")

        assert_receive {:token_deleted, "dead-token"}
      end

  The stub receives the `t:PushX.Test.Push.t/0` and returns `:ok` (delivered),
  `{:error, status}` (a `PushX.Response` error with that status), or a full
  `{:ok, %PushX.Response{}}` / `{:error, %PushX.Response{}}`. Stubs are per
  test process too.

  ## Named instances in tests

  `PushX.Instance.start/3` validates credentials before starting, so use the
  throwaway-key helpers rather than committing keys:

      PushX.Instance.start(:tenant_apns, :apns,
        key_id: "TEST", team_id: "TEST", private_key: PushX.Test.apns_private_key(), mode: :sandbox)

      PushX.Instance.start(:tenant_fcm, :fcm,
        project_id: "tenant", credentials: PushX.Test.fcm_credentials())

  In test delivery mode the instances never contact the providers.

  ## What is *not* simulated

  Test mode answers after local validation, so it cannot tell you what Apple
  or Google would have said about a token or payload — only that PushX would
  have sent it. Use `stub/1` to model provider responses you care about.
  """

  alias PushX.{Config, Response, Telemetry}

  @pushes_table :pushx_test_pushes
  @stubs_table :pushx_test_stubs

  defmodule Push do
    @moduledoc """
    One recorded push. Fields:

      * `:provider` — `:apns` | `:fcm`
      * `:target` — device token, or for FCM `{:topic, name}` / `{:condition, expr}`
      * `:payload` — the decoded wire payload PushX would have sent: for APNS the
        `%{"aps" => ...}` map, for FCM the `%{"message" => ...}` envelope
      * `:opts` — the send options after `PushX.Message` delivery fields were
        merged in (`:topic`, `:push_type`, `:priority`, `:collapse_id`, ...)
      * `:instance` — the named instance, or `nil` for the static configuration
      * `:result` — what the caller received (`{:ok, %Response{}}` or a stubbed error)
      * `:id` — the generated message id (`"test-N"`), also on the response
      * `:sent_at` — `DateTime` of the send
    """
    @type t :: %__MODULE__{
            provider: :apns | :fcm,
            target: PushX.target(),
            payload: map(),
            opts: keyword(),
            instance: atom() | nil,
            result: {:ok, Response.t()} | {:error, Response.t()},
            id: String.t(),
            sent_at: DateTime.t()
          }
    defstruct [:provider, :target, :payload, :opts, :instance, :result, :id, :sent_at]
  end

  @doc false
  # Called from PushX.Application: the tables are cheap and always exist so
  # test mode can be switched on at runtime (Application.put_env) as well as
  # in config.
  def init_tables do
    :ets.new(@pushes_table, [:named_table, :public, :ordered_set])
    :ets.new(@stubs_table, [:named_table, :public, :set])
    :ok
  end

  @doc "True when `delivery: :test` is configured."
  @spec active?() :: boolean()
  def active?, do: Config.delivery() == :test

  @doc """
  All pushes recorded for the current test process (and processes it spawned),
  in recording order — for concurrent batch workers that is completion order,
  not input order.
  """
  @spec pushes() :: [Push.t()]
  def pushes do
    owner = owner()

    :ets.select(@pushes_table, [{{{owner, :_}, :"$1"}, [], [:"$1"]}])
  end

  @doc "The most recent recorded push for the current test process, or `nil`."
  @spec last_push() :: Push.t() | nil
  def last_push, do: pushes() |> List.last()

  @doc """
  Forgets the current test process's recorded pushes and stub.

  Not required between tests (records are per process), but handy inside a
  test that exercises several scenarios.
  """
  @spec clear() :: :ok
  def clear do
    owner = owner()
    :ets.match_delete(@pushes_table, {{owner, :_}, :_})
    :ets.delete(@stubs_table, owner)
    :ok
  end

  @doc """
  Scripts responses for the current test process. `fun` receives each
  `t:PushX.Test.Push.t/0` (with `result: nil`) and returns:

    * `:ok` — delivered (the default when no stub is set)
    * `{:error, status}` — a `PushX.Response` error with that status atom
    * `{:ok, %PushX.Response{}}` or `{:error, %PushX.Response{}}` — verbatim

  Pass `nil` to remove the stub.
  """
  @spec stub(
          (Push.t() -> :ok | {:error, atom()} | {:ok, Response.t()} | {:error, Response.t()})
          | nil
        ) ::
          :ok
  def stub(nil) do
    :ets.delete(@stubs_table, owner())
    :ok
  end

  def stub(fun) when is_function(fun, 1) do
    :ets.insert(@stubs_table, {owner(), fun})
    :ok
  end

  @doc false
  # The delivery hook. Called by the send paths after all local validation,
  # in place of the network request. Records the push, consults the stub,
  # emits the same telemetry as a real send, and returns the result.
  @spec deliver(:apns | :fcm, PushX.target(), binary(), keyword(), atom() | nil) ::
          {:ok, Response.t()} | {:error, Response.t()}
  def deliver(provider, target, body, opts, instance) do
    Telemetry.start(provider, target)
    start_time = System.monotonic_time()

    seq = System.unique_integer([:positive, :monotonic])
    id = "test-#{seq}"

    push = %Push{
      provider: provider,
      target: target,
      payload: JSON.decode!(body),
      opts: opts,
      instance: instance,
      id: id,
      sent_at: DateTime.utc_now()
    }

    result = stubbed_result(push, Response.success(provider, id))
    push = %{push | result: result}
    :ets.insert(@pushes_table, {{owner(), seq}, push})

    case result do
      {:ok, response} -> Telemetry.stop(provider, target, start_time, response)
      {:error, response} -> Telemetry.error(provider, target, start_time, response)
    end

    result
  end

  defp stubbed_result(push, default_response) do
    case :ets.lookup(@stubs_table, owner()) do
      [] ->
        {:ok, default_response}

      [{_owner, fun}] ->
        case fun.(push) do
          :ok ->
            {:ok, default_response}

          {:ok, %Response{} = r} ->
            {:ok, r}

          {:error, %Response{} = r} ->
            {:error, r}

          {:error, status} when is_atom(status) ->
            {:error, Response.error(push.provider, status, "stubbed by PushX.Test")}

          other ->
            raise ArgumentError,
                  "PushX.Test.stub/1 function returned #{inspect(other)}; expected :ok, {:error, status}, {:ok, %Response{}} or {:error, %Response{}}"
        end
    end
  end

  # The recording owner is the outermost caller (the test process) when the
  # push happens inside a Task / batch worker, else the current process.
  defp owner do
    case Process.get(:"$callers") do
      [_ | _] = callers -> List.last(callers)
      _ -> self()
    end
  end

  # -- Throwaway credentials -----------------------------------------------

  @doc """
  A freshly generated P-256 EC private key (PEM), the kind APNS signs with.
  Generated once per VM and cached; tied to no Apple account. For starting
  APNS instances in tests.
  """
  @spec apns_private_key() :: String.t()
  def apns_private_key do
    cached({__MODULE__, :apns_key}, fn ->
      {:namedCurve, :secp256r1}
      |> :public_key.generate_key()
      |> then(&:public_key.pem_entry_encode(:ECPrivateKey, &1))
      |> List.wrap()
      |> :public_key.pem_encode()
    end)
  end

  @doc """
  A service-account credentials map with a freshly generated RSA key, valid
  for `PushX.Instance.start/3`'s credential validation. Generated once per VM
  and cached; tied to no Google project.
  """
  @spec fcm_credentials() :: map()
  def fcm_credentials do
    cached({__MODULE__, :fcm_credentials}, fn ->
      rsa = :public_key.generate_key({:rsa, 2048, 65_537})
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, rsa)])

      %{
        "type" => "service_account",
        "project_id" => "pushx-test",
        "private_key" => pem,
        "client_email" => "pushx-test@pushx-test.iam.gserviceaccount.com"
      }
    end)
  end

  defp cached(key, generate) do
    :persistent_term.get(key, nil) ||
      (
        value = generate.()
        :persistent_term.put(key, value)
        value
      )
  end
end
