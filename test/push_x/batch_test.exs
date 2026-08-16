defmodule PushX.BatchTest do
  use ExUnit.Case, async: false

  setup do
    :ok
  end

  describe "PushX.push_batch/4" do
    test "returns list of token-result tuples" do
      # Since we can't easily mock HTTP in batch, we'll test the structure
      # by checking that the function exists and handles empty list correctly
      results = PushX.push_batch(:fcm, [], "Test message")
      assert results == []
    end

    test "handles empty token list" do
      results = PushX.push_batch(:apns, [], "Hello", topic: "com.test.app")
      assert results == []
    end

    test "accepts concurrency option" do
      # This tests that the option is accepted without error
      results = PushX.push_batch(:fcm, [], "Hello", concurrency: 100)
      assert results == []
    end

    test "accepts timeout option" do
      results = PushX.push_batch(:fcm, [], "Hello", timeout: 5000)
      assert results == []
    end

    test "accepts validate_tokens option" do
      invalid_tokens = ["short", "also-short"]

      results =
        PushX.push_batch(:apns, invalid_tokens, "Hello",
          topic: "com.test.app",
          validate_tokens: true
        )

      # Invalid tokens get error responses; the result list matches input length.
      assert length(results) == 2

      assert Enum.all?(results, fn {_token, result} ->
               match?({:error, %PushX.Response{status: :invalid_token}}, result)
             end)
    end
  end

  describe "PushX.push_batch!/4" do
    test "returns summary map" do
      result = PushX.push_batch!(:fcm, [], "Hello")

      assert %{success: 0, failure: 0, total: 0} = result
    end

    test "counts successes and failures" do
      # With empty list, all counts are zero
      result = PushX.push_batch!(:apns, [], "Hello", topic: "com.test.app")

      assert result.success == 0
      assert result.failure == 0
      assert result.total == 0
    end
  end

  describe "token validation in batch" do
    test "validate_tokens returns invalid_token error for bad APNS tokens" do
      invalid_tokens = ["too-short", "also-short"]

      results =
        PushX.push_batch(:apns, invalid_tokens, "Hello",
          topic: "com.test.app",
          validate_tokens: true
        )

      # The result list matches the input length — invalid tokens get an
      # error response instead of being silently dropped.
      assert length(results) == 2

      assert Enum.all?(results, fn {token, result} ->
               token in invalid_tokens and
                 match?({:error, %PushX.Response{status: :invalid_token}}, result)
             end)
    end

    test "validate_tokens returns invalid_token error for bad FCM tokens" do
      invalid_tokens = ["short", "also-short"]

      results = PushX.push_batch(:fcm, invalid_tokens, "Hello", validate_tokens: true)

      assert length(results) == 2

      assert Enum.all?(results, fn {token, result} ->
               token in invalid_tokens and
                 match?({:error, %PushX.Response{status: :invalid_token}}, result)
             end)
    end

    test "without validate_tokens option, all tokens are processed" do
      # Empty list case - validates the function signature works
      results = PushX.push_batch(:fcm, [], "Hello", validate_tokens: false)
      assert results == []
    end
  end

  describe "PushX.validate_token/2" do
    test "delegates to Token module" do
      valid_apns = String.duplicate("a", 64)
      assert PushX.validate_token(:apns, valid_apns) == :ok

      invalid_apns = "too-short"
      assert {:error, :invalid_length} = PushX.validate_token(:apns, invalid_apns)
    end
  end

  describe "PushX.valid_token?/2" do
    test "returns boolean" do
      valid_apns = String.duplicate("a", 64)
      assert PushX.valid_token?(:apns, valid_apns) == true

      invalid_apns = "too-short"
      assert PushX.valid_token?(:apns, invalid_apns) == false
    end
  end

  describe "batch with mixed results via HTTP" do
    # Drives the real PushX.push_batch/4 → PushX.APNS.send/3 path against
    # Bypass via the test-only :apns_url_override seam.
    setup do
      bypass = Bypass.open()
      Application.put_env(:pushx, :apns_url_override, "http://localhost:#{bypass.port}")
      Application.put_env(:pushx, :retry_enabled, false)
      PushX.JWTCache.invalidate(:apns_jwt)

      on_exit(fn ->
        Application.delete_env(:pushx, :apns_url_override)
        Application.delete_env(:pushx, :retry_enabled)
        PushX.JWTCache.invalidate(:apns_jwt)
      end)

      {:ok, bypass: bypass}
    end

    test "returns mix of success and failure results", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/3/device/good-token-1", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("apns-id", "id-1")
        |> Plug.Conn.resp(200, "")
      end)

      Bypass.expect(bypass, "POST", "/3/device/bad-token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      Bypass.expect(bypass, "POST", "/3/device/good-token-2", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("apns-id", "id-2")
        |> Plug.Conn.resp(200, "")
      end)

      tokens = ["good-token-1", "bad-token", "good-token-2"]
      results = PushX.push_batch(:apns, tokens, "Hello", topic: "com.test.app")

      assert length(results) == 3

      result_map = Map.new(results)
      assert {:ok, %PushX.Response{status: :sent, id: "id-1"}} = result_map["good-token-1"]
      assert {:error, %PushX.Response{status: :invalid_token}} = result_map["bad-token"]
      assert {:ok, %PushX.Response{status: :sent, id: "id-2"}} = result_map["good-token-2"]
    end

    test "push_batch_stream/4 is lazy, yields in input order, and can stop early", %{
      bypass: bypass
    } do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Bypass.stub(bypass, "POST", "/3/device/t1", fn conn ->
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_resp_header("apns-id", "one") |> Plug.Conn.resp(200, "")
      end)

      Bypass.stub(bypass, "POST", "/3/device/t2", fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, ~s({"reason": "BadDeviceToken"}))
      end)

      stream =
        PushX.push_batch_stream(:apns, ["t1", "t2", "t3"], "Hello",
          topic: "com.test.app",
          concurrency: 1
        )

      # Nothing has been sent yet.
      assert Agent.get(counter, & &1) == 0

      # Taking two results sends (at most) the first two with concurrency 1.
      assert [
               {"t1", {:ok, %PushX.Response{id: "one"}}},
               {"t2", {:error, %PushX.Response{status: :invalid_token}}}
             ] =
               Enum.take(stream, 2)

      assert Agent.get(counter, & &1) == 2
    end

    test "push_batch_stream/4 accepts any enumerable and matches push_batch/4", %{bypass: bypass} do
      Bypass.stub(bypass, "POST", "/3/device/s1", fn conn ->
        conn |> Plug.Conn.put_resp_header("apns-id", "s1") |> Plug.Conn.resp(200, "")
      end)

      Bypass.stub(bypass, "POST", "/3/device/s2", fn conn ->
        conn |> Plug.Conn.put_resp_header("apns-id", "s2") |> Plug.Conn.resp(200, "")
      end)

      tokens = Stream.map(1..2, &"s#{&1}")

      assert PushX.push_batch_stream(:apns, tokens, "Hello", topic: "com.test.app")
             |> Enum.to_list() ==
               PushX.push_batch(:apns, tokens, "Hello", topic: "com.test.app")
    end

    test "handles all failures gracefully", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"reason": "InternalServerError"}))
      end)

      tokens = ["token-1", "token-2"]
      results = PushX.push_batch(:apns, tokens, "Hello", topic: "com.test.app")

      assert length(results) == 2
      assert Enum.all?(results, fn {_token, result} -> match?({:error, _}, result) end)
    end

    test "reports a task that exceeds :timeout as a connection_error timeout" do
      # A bare TCP listener that never answers: the send blocks in the HTTP
      # client until the batch's per-task :timeout kills it.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)
      Application.put_env(:pushx, :apns_url_override, "http://localhost:#{port}")
      Application.put_env(:pushx, :fcm_url_override, "http://localhost:#{port}")
      on_exit(fn -> Application.delete_env(:pushx, :fcm_url_override) end)

      assert [{"slow-token", {:error, %PushX.Response{} = apns_err}}] =
               PushX.push_batch(:apns, ["slow-token"], "Hello",
                 topic: "com.test.app",
                 timeout: 50
               )

      assert %{status: :connection_error, reason: "timeout", provider: :apns} = apns_err

      assert [{"slow-token", {:error, %PushX.Response{} = apns_batch_err}}] =
               PushX.APNS.send_batch(["slow-token"], %{"aps" => %{"alert" => "Hi"}},
                 topic: "com.test.app",
                 timeout: 50
               )

      assert %{status: :connection_error, reason: "timeout", provider: :apns} = apns_batch_err

      assert [{"slow-token", {:error, %PushX.Response{} = fcm_err}}] =
               PushX.FCM.send_batch(["slow-token"], %{"title" => "Hi", "body" => "x"},
                 timeout: 50
               )

      assert %{status: :connection_error, reason: "timeout", provider: :fcm} = fcm_err

      # Named instances: the facade cannot know the provider for a timed-out
      # task, so the error is stamped :unknown.
      {:ok, _} =
        PushX.Instance.start(:batch_timeout_inst, :apns,
          key_id: "TEST_KEY_ID",
          team_id: "TEST_TEAM_ID",
          private_key: Application.get_env(:pushx, :apns_private_key),
          mode: :sandbox
        )

      on_exit(fn ->
        PushX.Instance.stop(:batch_timeout_inst)
        PushX.JWTCache.invalidate({:apns_jwt, :batch_timeout_inst})
      end)

      assert [{"slow-token", {:error, %PushX.Response{} = inst_err}}] =
               PushX.push_batch(:batch_timeout_inst, ["slow-token"], "Hello",
                 topic: "com.test.app",
                 timeout: 50
               )

      assert %{status: :connection_error, reason: "timeout", provider: :unknown} = inst_err
    end
  end

  describe "batch isolation when a task crashes" do
    # An integer message has no normalize_payload/encode clause, so the task
    # raises FunctionClauseError. The batch must still return one result per
    # input token instead of crashing the calling process.

    @tag capture_log: true
    test "PushX.push_batch survives a raising task" do
      tokens = ["crash-token-1", "crash-token-2"]
      results = PushX.push_batch(:apns, tokens, 12_345, topic: "com.test.app")

      assert length(results) == 2

      for {token, result} <- results do
        assert token in tokens
        assert {:error, %PushX.Response{status: :unknown_error, reason: reason}} = result
        assert reason =~ "function_clause"
      end
    end

    @tag capture_log: true
    test "PushX.APNS.send_batch survives a raising task" do
      results = PushX.APNS.send_batch(["crash-token"], 12_345, topic: "com.test.app")

      assert [{"crash-token", {:error, %PushX.Response{status: :unknown_error}}}] = results
    end

    @tag capture_log: true
    test "PushX.FCM.send_batch survives a raising task" do
      results = PushX.FCM.send_batch(["crash-token"], 12_345)

      assert [{"crash-token", {:error, %PushX.Response{status: :unknown_error}}}] = results
    end
  end

  describe "PushX.check_rate_limit/1" do
    setup do
      # Disable rate limiting for most tests
      Application.put_env(:pushx, :rate_limit_enabled, false)

      on_exit(fn ->
        Application.delete_env(:pushx, :rate_limit_enabled)
      end)

      :ok
    end

    test "returns :ok when rate limiting is disabled" do
      assert PushX.check_rate_limit(:apns) == :ok
      assert PushX.check_rate_limit(:fcm) == :ok
    end

    test "delegates to RateLimiter module" do
      Application.put_env(:pushx, :rate_limit_enabled, true)
      Application.put_env(:pushx, :rate_limit_apns, 1)

      PushX.RateLimiter.reset(:apns)

      assert PushX.check_rate_limit(:apns) == :ok
    end
  end
end
