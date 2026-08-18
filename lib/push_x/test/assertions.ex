defmodule PushX.Test.Assertions do
  @moduledoc """
  ExUnit assertions for `PushX.Test` (test delivery mode).

      import PushX.Test.Assertions

      push = assert_pushed(%{provider: :apns, target: ^token})
      assert push.payload["aps"]["alert"]["title"] == "Order shipped"

      refute_pushed(%{provider: :fcm, target: ^token})
      assert_no_pushes()

  Patterns are ordinary match patterns (pins allowed) checked against each
  recorded `t:PushX.Test.Push.t/0` of the current test process, like
  `assert_receive/1`. Failure messages list what *was* recorded.
  """

  @doc """
  Asserts that at least one recorded push matches `pattern` and returns the
  first match. `pattern` is a match pattern, e.g.
  `%{provider: :apns, target: ^token, instance: nil}`.
  """
  defmacro assert_pushed(pattern) do
    pattern_string = Macro.to_string(pattern)

    quote do
      pushes = PushX.Test.pushes()

      case Enum.find(pushes, &match?(unquote(pattern), &1)) do
        nil ->
          ExUnit.Assertions.flunk(
            "Expected a push matching #{unquote(pattern_string)}, but none did.\n" <>
              PushX.Test.Assertions.format_pushes(pushes)
          )

        push ->
          push
      end
    end
  end

  @doc "Asserts that no recorded push matches `pattern`."
  defmacro refute_pushed(pattern) do
    pattern_string = Macro.to_string(pattern)

    quote do
      pushes = PushX.Test.pushes()

      case Enum.find(pushes, &match?(unquote(pattern), &1)) do
        nil ->
          :ok

        push ->
          ExUnit.Assertions.flunk(
            "Expected no push matching #{unquote(pattern_string)}, but found:\n" <>
              PushX.Test.Assertions.format_pushes([push])
          )
      end
    end
  end

  @doc "Asserts that the current test process recorded no pushes at all."
  defmacro assert_no_pushes do
    quote do
      case PushX.Test.pushes() do
        [] ->
          :ok

        pushes ->
          ExUnit.Assertions.flunk(
            "Expected no pushes, but #{length(pushes)} were recorded:\n" <>
              PushX.Test.Assertions.format_pushes(pushes)
          )
      end
    end
  end

  @doc false
  def format_pushes([]), do: "  (no pushes recorded for this test process)"

  def format_pushes(pushes) do
    Enum.map_join(pushes, "\n", fn push ->
      "  * #{push.provider} -> #{inspect(push.target)}" <>
        if(push.instance, do: " (instance #{inspect(push.instance)})", else: "") <>
        " opts=#{inspect(push.opts)} payload=#{inspect(push.payload, limit: 20)}"
    end)
  end
end
