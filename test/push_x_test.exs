defmodule PushXTest do
  use ExUnit.Case
  doctest PushX

  alias PushX.Message

  describe "message/0" do
    test "creates an empty message" do
      message = PushX.message()
      assert %Message{} = message
      assert message.title == nil
      assert message.body == nil
    end
  end

  describe "message/2" do
    test "creates a message with title and body" do
      message = PushX.message("Hello", "World")
      assert message.title == "Hello"
      assert message.body == "World"
    end
  end

  describe "push/4 argument validation" do
    test "raises for unknown provider" do
      assert_raise FunctionClauseError, fn ->
        PushX.push(:unknown, "token", "message")
      end
    end
  end
end
