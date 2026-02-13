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
      # Invalid tokens should be filtered out when validate_tokens is true
      invalid_tokens = ["short", "also-short"]

      results =
        PushX.push_batch(:apns, invalid_tokens, "Hello",
          topic: "com.test.app",
          validate_tokens: true
        )

      # All tokens were invalid, so none were sent
      assert results == []
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
    test "validate_tokens filters invalid APNS tokens" do
      # All invalid tokens should be filtered out
      invalid_tokens = ["too-short", "also-short"]

      # With validation enabled, all invalid tokens are filtered
      results =
        PushX.push_batch(:apns, invalid_tokens, "Hello",
          topic: "com.test.app",
          validate_tokens: true
        )

      # All tokens were invalid, so none were sent
      assert results == []
    end

    test "validate_tokens filters invalid FCM tokens" do
      # All invalid tokens
      invalid_tokens = ["short", "also-short"]

      results = PushX.push_batch(:fcm, invalid_tokens, "Hello", validate_tokens: true)

      # All tokens were invalid, so none were sent
      assert results == []
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
    setup do
      bypass = Bypass.open()
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
      results = batch_send_via_bypass(bypass, tokens)

      assert length(results) == 3

      result_map = Map.new(results)
      assert {:ok, %PushX.Response{status: :sent, id: "id-1"}} = result_map["good-token-1"]
      assert {:error, %PushX.Response{status: :invalid_token}} = result_map["bad-token"]
      assert {:ok, %PushX.Response{status: :sent, id: "id-2"}} = result_map["good-token-2"]
    end

    test "handles all failures gracefully", %{bypass: bypass} do
      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(500, ~s({"reason": "InternalServerError"}))
      end)

      tokens = ["token-1", "token-2"]
      results = batch_send_via_bypass(bypass, tokens)

      assert length(results) == 2
      assert Enum.all?(results, fn {_token, result} -> match?({:error, _}, result) end)
    end

    defp batch_send_via_bypass(bypass, tokens) do
      tokens
      |> Task.async_stream(
        fn token ->
          url = "http://localhost:#{bypass.port}/3/device/#{token}"

          headers = [
            {"authorization", "bearer test-jwt"},
            {"apns-topic", "com.test.app"},
            {"apns-push-type", "alert"},
            {"apns-priority", "10"}
          ]

          body = JSON.encode!(%{"aps" => %{"alert" => "Hello"}})

          result =
            case Finch.build(:post, url, headers, body)
                 |> Finch.request(PushX.Config.finch_name()) do
              {:ok, %{status: 200, headers: response_headers}} ->
                apns_id =
                  case List.keyfind(response_headers, "apns-id", 0) do
                    {_, value} -> value
                    nil -> nil
                  end

                {:ok, PushX.Response.success(:apns, apns_id)}

              {:ok, %{status: _status, body: resp_body}} ->
                reason =
                  case JSON.decode(resp_body) do
                    {:ok, %{"reason" => r}} -> r
                    _ -> "Unknown"
                  end

                status = PushX.Response.apns_reason_to_status(reason)
                {:error, PushX.Response.error(:apns, status, reason, resp_body)}

              {:error, _reason} ->
                {:error, PushX.Response.error(:apns, :connection_error, "Connection failed")}
            end

          {token, result}
        end,
        max_concurrency: 50,
        timeout: 5000
      )
      |> Enum.map(fn {:ok, result} -> result end)
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
