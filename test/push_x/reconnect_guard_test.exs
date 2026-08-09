defmodule PushX.ReconnectGuardTest do
  use ExUnit.Case, async: false

  alias PushX.ReconnectGuard

  setup do
    ReconnectGuard.reset()

    on_exit(fn ->
      Application.delete_env(:pushx, :reconnect_cooldown_ms)
      ReconnectGuard.reset()
    end)

    :ok
  end

  test "first acquire per key is granted, repeats within the cooldown are not" do
    assert ReconnectGuard.acquire(:default) == true
    assert ReconnectGuard.acquire(:default) == false
    assert ReconnectGuard.acquire(:default) == false
  end

  test "keys are independent" do
    assert ReconnectGuard.acquire(:default) == true
    assert ReconnectGuard.acquire(:tenant_a) == true
    assert ReconnectGuard.acquire(:tenant_a) == false
  end

  test "grants again after the cooldown elapses" do
    Application.put_env(:pushx, :reconnect_cooldown_ms, 50)

    assert ReconnectGuard.acquire(:default) == true
    assert ReconnectGuard.acquire(:default) == false

    Process.sleep(60)

    assert ReconnectGuard.acquire(:default) == true
  end

  test "exactly one of many concurrent acquirers is granted" do
    grants =
      1..50
      |> Enum.map(fn _ -> Task.async(fn -> ReconnectGuard.acquire(:default) end) end)
      |> Task.await_many(5_000)

    assert Enum.count(grants, & &1) == 1
  end
end
