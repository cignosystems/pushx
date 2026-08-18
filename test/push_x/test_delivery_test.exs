defmodule PushX.TestDeliveryTest do
  # The suite as a whole runs with delivery: :live (the real send paths are
  # exercised against Bypass elsewhere); this file switches to :test for its
  # duration to exercise PushX.Test itself.
  use ExUnit.Case, async: false

  import PushX.Test.Assertions

  alias PushX.{Response, Test}

  defmodule Sink do
    def invalid(provider, token, pid), do: send(pid, {:invalid_token, provider, token})
  end

  setup do
    Application.put_env(:pushx, :delivery, :test)
    on_exit(fn -> Application.delete_env(:pushx, :delivery) end)
    Test.clear()
    :ok
  end

  describe "recording" do
    test "static APNS push is validated, recorded, and answered locally" do
      assert {:ok, %Response{status: :sent, provider: :apns, id: "test-" <> _}} =
               PushX.push(:apns, "abc123", "Hello", topic: "com.example.app", push_type: "alert")

      push = assert_pushed(%{provider: :apns, target: "abc123", instance: nil})
      assert push.payload["aps"]["alert"]["title"] == "Hello"
      assert push.opts[:topic] == "com.example.app"
      assert push.opts[:push_type] == "alert"
      assert {:ok, %Response{id: id}} = push.result
      assert id == push.id
      assert %DateTime{} = push.sent_at
    end

    test "static FCM push, push_data and topic targets are recorded with the wire envelope" do
      assert {:ok, %Response{provider: :fcm}} =
               PushX.push(:fcm, "fcm-token", %{title: "T", body: "B"})

      assert {:ok, _} = PushX.push_data(:fcm, "fcm-token", %{action: "sync", id: 7})
      assert {:ok, _} = PushX.push(:fcm, {:topic, "news"}, "Breaking")

      assert %{
               payload: %{
                 "message" => %{"token" => "fcm-token", "notification" => %{"title" => "T"}}
               }
             } =
               assert_pushed(%{
                 provider: :fcm,
                 target: "fcm-token",
                 payload: %{"message" => %{"notification" => _}}
               })

      assert %{payload: %{"message" => %{"data" => %{"action" => "sync", "id" => "7"}}}} =
               assert_pushed(%{provider: :fcm, payload: %{"message" => %{"data" => _}}})

      assert %{payload: %{"message" => %{"topic" => "news"}}} =
               assert_pushed(%{target: {:topic, "news"}})

      assert length(Test.pushes()) == 3
      assert Test.last_push().target == {:topic, "news"}
    end

    test "provider modules and named instances record too, with the instance name" do
      assert {:ok, _} = PushX.APNS.send("tok", %{"aps" => %{"alert" => "direct"}}, topic: "t")
      assert {:ok, _} = PushX.FCM.send_data("tok", %{k: "v"})

      {:ok, _} =
        PushX.Instance.start(:tenant_apns, :apns,
          key_id: "K",
          team_id: "T",
          private_key: Test.apns_private_key(),
          mode: :sandbox,
          connect_timeout: 1
        )

      {:ok, _} =
        PushX.Instance.start(:tenant_fcm, :fcm,
          project_id: "tenant",
          credentials: Test.fcm_credentials(),
          token_fetcher: {PushX.TestOAuth, :fetch, []},
          connect_timeout: 1
        )

      on_exit(fn ->
        PushX.Instance.stop(:tenant_apns)
        PushX.Instance.stop(:tenant_fcm)
      end)

      assert {:ok, %Response{status: :sent}} = PushX.push(:tenant_apns, "tok", "Hi", topic: "t")
      assert {:ok, %Response{status: :sent}} = PushX.push(:tenant_fcm, "tok", "Hi")

      assert_pushed(%{
        provider: :apns,
        instance: nil,
        payload: %{"aps" => %{"alert" => "direct"}}
      })

      assert_pushed(%{
        provider: :fcm,
        instance: nil,
        payload: %{"message" => %{"data" => %{"k" => "v"}}}
      })

      assert_pushed(%{provider: :apns, instance: :tenant_apns})

      assert_pushed(%{
        provider: :fcm,
        instance: :tenant_fcm,
        payload: %{"message" => %{"token" => "tok"}}
      })
    end

    test "batches record every target, from the batch workers, under the test process" do
      results = PushX.push_batch(:apns, ["t1", "t2", "t3"], "Hi", topic: "t", concurrency: 2)
      assert Enum.all?(results, &match?({_, {:ok, %Response{status: :sent}}}, &1))

      assert length(Test.pushes()) == 3
      assert Enum.map(Test.pushes(), & &1.target) == ["t1", "t2", "t3"]

      # A stream consumed here also lands here.
      PushX.push_batch_stream(:fcm, ["s1"], "Hi") |> Stream.run()
      assert_pushed(%{provider: :fcm, target: "s1"})
    end

    test "local validation still runs: invalid calls are rejected and not recorded" do
      assert {:error, %Response{status: :invalid_request}} = PushX.push(:apns, "tok", "no topic")

      assert {:error, %Response{status: :invalid_request}} =
               PushX.push(:fcm, {:topic, "/topics/x"}, "Hi")

      assert {:error, %Response{status: :invalid_token}} =
               PushX.push(:apns, "bad token!", "Hi", topic: "t")

      assert {:error, %Response{status: :payload_too_large}} =
               PushX.push(:apns, "tok", %{"aps" => %{"alert" => String.duplicate("x", 5000)}},
                 topic: "t"
               )

      assert_no_pushes()
    end

    test "needs no credentials: works with APNS unconfigured" do
      original = Application.get_env(:pushx, :apns_key_id)
      Application.delete_env(:pushx, :apns_key_id)
      on_exit(fn -> Application.put_env(:pushx, :apns_key_id, original) end)

      assert {:ok, %Response{status: :sent}} = PushX.push(:apns, "tok", "Hi", topic: "t")
      assert_pushed(%{provider: :apns, target: "tok"})
    end

    test "emits the same telemetry as a real send" do
      test_pid = self()
      handler = "pushx-test-delivery-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler,
        [[:pushx, :push, :start], [:pushx, :push, :stop], [:pushx, :push, :error]],
        fn event, _m, meta, _ -> send(test_pid, {event, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      PushX.push(:apns, "tok", "Hi", topic: "t")
      assert_receive {[:pushx, :push, :start], %{provider: :apns}}
      assert_receive {[:pushx, :push, :stop], %{provider: :apns, status: :sent}}

      Test.stub(fn _ -> {:error, :server_error} end)
      PushX.push(:apns, "tok", "Hi", topic: "t")
      assert_receive {[:pushx, :push, :error], %{provider: :apns, status: :server_error}}
    end
  end

  describe "stubs" do
    test "script failures per push; :on_invalid_token fires exactly as for a real response" do
      Application.put_env(:pushx, :on_invalid_token, {Sink, :invalid, [self()]})
      on_exit(fn -> Application.delete_env(:pushx, :on_invalid_token) end)

      Test.stub(fn
        %{target: "dead"} -> {:error, :unregistered}
        %{target: "flaky"} -> {:error, Response.error(:apns, :server_error, "boom", nil, 3)}
        %{target: "custom-ok"} -> {:ok, Response.success(:apns, "my-id")}
        _ -> :ok
      end)

      assert {:error, %Response{status: :unregistered, reason: "stubbed by PushX.Test"} = dead} =
               PushX.push(:apns, "dead", "Hi", topic: "t")

      assert Response.should_remove_token?(dead)
      assert_receive {:invalid_token, :apns, "dead"}

      assert {:error, %Response{status: :server_error, retry_after: 3}} =
               PushX.push(:apns, "flaky", "Hi", topic: "t")

      assert {:ok, %Response{id: "my-id"}} = PushX.push(:apns, "custom-ok", "Hi", topic: "t")
      assert {:ok, %Response{status: :sent}} = PushX.push(:apns, "fine", "Hi", topic: "t")

      # Failed pushes are recorded too, with their result.
      assert %{result: {:error, %Response{status: :unregistered}}} =
               assert_pushed(%{target: "dead"})

      refute_receive {:invalid_token, _, "fine"}
    end

    test "retryable stubbed failures are not retried in test mode (no sleeping)" do
      Application.put_env(:pushx, :retry_enabled, true)
      Application.put_env(:pushx, :retry_base_delay_ms, 60_000)

      on_exit(fn ->
        Application.delete_env(:pushx, :retry_enabled)
        Application.delete_env(:pushx, :retry_base_delay_ms)
      end)

      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Test.stub(fn _ ->
        Agent.update(counter, &(&1 + 1))
        {:error, :rate_limited}
      end)

      {us, result} = :timer.tc(fn -> PushX.push(:fcm, "tok", "Hi") end)
      assert {:error, %Response{status: :rate_limited}} = result
      assert Agent.get(counter, & &1) == 1
      assert us < 5_000_000
    end

    test "a stub returning garbage is a clear error; stub(nil) removes it" do
      Test.stub(fn _ -> :nope end)

      assert_raise ArgumentError, ~r/PushX.Test.stub\/1 function returned :nope/, fn ->
        PushX.push(:apns, "tok", "Hi", topic: "t")
      end

      Test.stub(nil)
      assert {:ok, _} = PushX.push(:apns, "tok", "Hi", topic: "t")
    end
  end

  describe "isolation" do
    test "pushes made by other processes are not visible; ones via $callers are" do
      # Another, unrelated process pushes: invisible here.
      other =
        spawn(fn ->
          receive do
            :go -> PushX.push(:apns, "elsewhere", "Hi", topic: "t")
          end
        end)

      send(other, :go)
      Process.sleep(50)
      refute_pushed(%{target: "elsewhere"})

      # A Task started by this test carries $callers: visible.
      Task.async(fn -> PushX.push(:apns, "from-task", "Hi", topic: "t") end) |> Task.await()
      assert_pushed(%{target: "from-task"})

      # A supervised task too.
      {:ok, sup} = Task.Supervisor.start_link()

      Task.Supervisor.async_nolink(sup, fn -> PushX.push(:fcm, "from-sup", "Hi") end)
      |> Task.await()

      assert_pushed(%{target: "from-sup"})
    end

    test "clear/0 forgets this process's pushes and stub only" do
      PushX.push(:apns, "a", "Hi", topic: "t")
      Test.stub(fn _ -> {:error, :server_error} end)
      Test.clear()

      assert_no_pushes()
      assert {:ok, %Response{status: :sent}} = PushX.push(:apns, "b", "Hi", topic: "t")
    end
  end

  describe "assertions" do
    test "assert_pushed returns the match and supports pins" do
      token = "pinned"
      PushX.push(:apns, token, "Hi", topic: "t")

      assert %Test.Push{target: "pinned"} = assert_pushed(%{target: ^token})
    end

    test "failure messages list what was recorded" do
      PushX.push(:apns, "recorded", "Hi", topic: "t")

      err = assert_raise ExUnit.AssertionError, fn -> assert_pushed(%{target: "missing"}) end
      assert err.message =~ ~s(Expected a push matching %{target: "missing"})
      assert err.message =~ ~s(apns -> "recorded")

      err = assert_raise ExUnit.AssertionError, fn -> refute_pushed(%{target: "recorded"}) end
      assert err.message =~ "Expected no push matching"

      err = assert_raise ExUnit.AssertionError, fn -> assert_no_pushes() end
      assert err.message =~ "Expected no pushes, but 1 were recorded"
    end
  end

  describe "throwaway credentials" do
    test "are stable per VM and pass instance validation" do
      assert Test.apns_private_key() == Test.apns_private_key()
      assert Test.apns_private_key() =~ "BEGIN EC PRIVATE KEY"
      assert Test.fcm_credentials() == Test.fcm_credentials()

      assert %{"private_key" => "-----BEGIN RSA PRIVATE KEY" <> _, "client_email" => _} =
               Test.fcm_credentials()
    end
  end
end
