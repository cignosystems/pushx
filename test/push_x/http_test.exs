defmodule PushX.HTTPTest do
  use ExUnit.Case, async: true

  alias PushX.HTTP

  describe "stringify_map/1" do
    test "returns nil for nil and empty map" do
      assert HTTP.stringify_map(nil) == nil
      assert HTTP.stringify_map(%{}) == nil
    end

    test "stringifies binaries, atoms, numbers" do
      assert HTTP.stringify_map(%{"a" => 1, "b" => :ok, "c" => "x"}) ==
               %{"a" => "1", "b" => "ok", "c" => "x"}
    end

    test "JSON-encodes nested maps so values stay strings" do
      result = HTTP.stringify_map(%{"order" => %{"id" => 5, "items" => 3}})

      # Value remains a string (FCM data values must be strings)
      assert is_binary(result["order"])
      assert JSON.decode!(result["order"]) == %{"id" => 5, "items" => 3}
    end

    test "JSON-encodes lists" do
      result = HTTP.stringify_map(%{"tags" => [1, 2, 3]})

      assert is_binary(result["tags"])
      assert JSON.decode!(result["tags"]) == [1, 2, 3]
    end

    test "falls back to inspect/1 for non-encodable terms" do
      result = HTTP.stringify_map(%{"pid" => self()})

      # Doesn't crash; produces a printable representation
      assert is_binary(result["pid"])
      assert result["pid"] =~ "PID"
    end
  end

  describe "parse_retry_after/1" do
    test "returns nil when header is missing" do
      assert HTTP.parse_retry_after([]) == nil
    end

    test "parses delta-seconds" do
      assert HTTP.parse_retry_after([{"retry-after", "120"}]) == 120
    end

    test "rejects negative seconds" do
      assert HTTP.parse_retry_after([{"retry-after", "-5"}]) == nil
    end

    test "rejects garbage" do
      assert HTTP.parse_retry_after([{"retry-after", "not a number"}]) == nil
    end

    test "parses RFC 1123 HTTP-date in the future" do
      future_dt = DateTime.add(DateTime.utc_now(), 600, :second)
      formatted = format_rfc1123(future_dt)

      seconds = HTTP.parse_retry_after([{"retry-after", formatted}])
      assert is_integer(seconds)
      # Allow some tolerance (within 5 seconds of expected)
      assert seconds in 595..605
    end

    test "returns nil for HTTP-date in the past" do
      past_dt = DateTime.add(DateTime.utc_now(), -600, :second)
      formatted = format_rfc1123(past_dt)

      assert HTTP.parse_retry_after([{"retry-after", formatted}]) == nil
    end

    test "returns nil for malformed HTTP-date" do
      assert HTTP.parse_retry_after([{"retry-after", "Wed, 99 Foo 2099 99:99:99 GMT"}]) == nil
    end
  end

  describe "safe_encode/1" do
    test "encodes valid maps" do
      assert {:ok, body} = HTTP.safe_encode(%{"a" => 1})
      assert JSON.decode!(body) == %{"a" => 1}
    end

    test "returns error for un-encodable terms instead of raising" do
      assert {:error, _reason} = HTTP.safe_encode(%{"pid" => self()})
    end
  end

  describe "get_header/2" do
    test "returns the value when header exists" do
      assert HTTP.get_header([{"content-type", "application/json"}], "content-type") ==
               "application/json"
    end

    test "returns nil when header is missing" do
      assert HTTP.get_header([], "content-type") == nil
    end
  end

  describe "maybe_add_header/3" do
    test "appends when value is non-nil" do
      assert HTTP.maybe_add_header([{"a", "1"}], "b", "2") == [{"b", "2"}, {"a", "1"}]
    end

    test "stringifies non-binary values" do
      assert HTTP.maybe_add_header([], "x", 42) == [{"x", "42"}]
    end

    test "returns headers unchanged when value is nil" do
      assert HTTP.maybe_add_header([{"a", "1"}], "b", nil) == [{"a", "1"}]
    end
  end

  describe "maybe_put/3" do
    test "skips nil and empty maps" do
      assert HTTP.maybe_put(%{"a" => 1}, "x", nil) == %{"a" => 1}
      assert HTTP.maybe_put(%{"a" => 1}, "x", %{}) == %{"a" => 1}
    end

    test "inserts non-nil values" do
      assert HTTP.maybe_put(%{}, "x", "value") == %{"x" => "value"}
      assert HTTP.maybe_put(%{}, "x", 0) == %{"x" => 0}
    end
  end

  defp format_rfc1123(dt) do
    # "Wed, 21 Oct 2015 07:28:00 GMT"
    day_of_week = dt |> DateTime.to_date() |> Date.day_of_week() |> day_abbr()
    month = month_abbr(dt.month)

    :io_lib.format("~s, ~2..0B ~s ~4..0B ~2..0B:~2..0B:~2..0B GMT", [
      day_of_week,
      dt.day,
      month,
      dt.year,
      dt.hour,
      dt.minute,
      dt.second
    ])
    |> IO.iodata_to_binary()
  end

  defp day_abbr(1), do: "Mon"
  defp day_abbr(2), do: "Tue"
  defp day_abbr(3), do: "Wed"
  defp day_abbr(4), do: "Thu"
  defp day_abbr(5), do: "Fri"
  defp day_abbr(6), do: "Sat"
  defp day_abbr(7), do: "Sun"

  for {abbr, num} <-
        Enum.with_index(
          ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
          1
        ) do
    defp month_abbr(unquote(num)), do: unquote(abbr)
  end

  describe "pool-saturation guidance" do
    test "too_many_concurrent_requests and connection_not_ready are explained; other errors are silent" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HTTP.explain_pool_error(
            {:error, %Finch.HTTPError{reason: :too_many_concurrent_requests, module: Mint.HTTP2}},
            "T"
          )
        end)

      assert log =~ "HTTP/2 connection saturated"
      assert log =~ ":finch_pool_count"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HTTP.explain_pool_error({:error, %Finch.Error{reason: :connection_not_ready}}, "T")
        end)

      assert log =~ "connection_not_ready"

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HTTP.explain_pool_error({:error, %Mint.TransportError{reason: :timeout}}, "T")
        end)

      refute log =~ "saturated"
      assert :ok = HTTP.explain_pool_error({:ok, %{}}, "T")
    end
  end
end
