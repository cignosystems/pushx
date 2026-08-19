defmodule PushX.Instance.LoaderTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PushX.Instance
  alias PushX.Instance.Loader

  defp apns_spec(name, overrides \\ []) do
    {name, :apns,
     Keyword.merge(
       [
         key_id: "K",
         team_id: "T",
         private_key: PushX.Test.apns_private_key(),
         mode: :sandbox,
         connect_timeout: 1
       ],
       overrides
     )}
  end

  def specs_from_mfa(extra), do: [apns_spec(:loader_mfa)] ++ extra

  setup do
    on_exit(fn ->
      for name <- [:loader_a, :loader_b, :loader_fn, :loader_mfa, :loader_raise],
          do: Instance.stop(name)
    end)

    :ok
  end

  test "load/1 starts each instance and reports started / already running / failed" do
    {:ok, _} = Instance.start(:loader_b, :apns, elem(apns_spec(:loader_b), 2))

    log =
      capture_log(fn ->
        result =
          Loader.load(
            instances: [
              apns_spec(:loader_a),
              apns_spec(:loader_b),
              apns_spec(:loader_bad, private_key: "garbage"),
              {:loader_fcm_bad, :fcm, [project_id: "p"]},
              :not_a_spec
            ]
          )

        assert result.started == [:loader_a]
        assert result.already_running == [:loader_b]

        assert [
                 {:loader_bad, {:invalid_private_key, _}},
                 {:loader_fcm_bad, {:missing_config, [:credentials]}},
                 {:not_a_spec, :invalid_spec}
               ] = result.failed

        send(self(), {:result, result})
      end)

    assert log =~ "Could not start :apns instance :loader_bad"
    assert log =~ "Invalid instance spec :not_a_spec"
    assert log =~ "started 1, already running 1, failed 3"
    assert {:ok, %{provider: :apns}} = Instance.status(:loader_a)
  end

  test "accepts a function or an MFA for :instances" do
    capture_log(fn ->
      assert %{started: [:loader_fn]} = Loader.load(instances: fn -> [apns_spec(:loader_fn)] end)

      assert %{started: [:loader_mfa]} =
               Loader.load(instances: {__MODULE__, :specs_from_mfa, [[]]})
    end)

    assert {:ok, _} = Instance.status(:loader_fn)
    assert {:ok, _} = Instance.status(:loader_mfa)
  end

  test "start_link/1 loads synchronously and returns :ignore; child_spec is temporary" do
    capture_log(fn ->
      assert :ignore = Loader.start_link(instances: [apns_spec(:loader_a)])
    end)

    assert {:ok, _} = Instance.status(:loader_a)
    assert %{restart: :temporary, id: Loader} = Loader.child_spec(instances: [])
    assert %{id: :custom} = Loader.child_spec(instances: [], id: :custom)
  end

  test "works as a supervised child: instances exist before the next child starts" do
    capture_log(fn ->
      children = [
        {Loader, instances: [apns_spec(:loader_a)]},
        # A child that checks the instance is already there when it starts.
        %{
          id: :probe,
          start: {Agent, :start_link, [fn -> Instance.status(:loader_a) end]}
        }
      ]

      {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)
      [{:probe, probe, _, _}] = Supervisor.which_children(sup)
      assert {:ok, %{provider: :apns}} = Agent.get(probe, & &1)
      Supervisor.stop(sup)
    end)
  end

  test "on_error: :raise fails the boot with every failure listed" do
    capture_log(fn ->
      err =
        assert_raise RuntimeError, fn ->
          Loader.start_link(
            instances: [apns_spec(:loader_raise), apns_spec(:loader_bad, private_key: "nope")],
            on_error: :raise
          )
        end

      assert err.message =~ "1 instance(s) failed to start"
      assert err.message =~ ":loader_bad"
    end)

    # The good one was still started before raising.
    assert {:ok, _} = Instance.status(:loader_raise)
  end
end
