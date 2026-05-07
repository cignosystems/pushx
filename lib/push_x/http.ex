defmodule PushX.HTTP do
  @moduledoc false

  # Helpers shared by PushX.APNS, PushX.FCM, and PushX.Instance for parsing
  # HTTP responses and building requests. Extracted so that bug fixes (e.g.,
  # the `Retry-After` parser) only need to be made in one place.

  @doc "Returns the value of an HTTP header by name (case-sensitive), or nil."
  @spec get_header([{String.t(), String.t()}], String.t()) :: String.t() | nil
  def get_header(headers, key) do
    case List.keyfind(headers, key, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  @doc """
  Parses an HTTP `Retry-After` header (RFC 7231 §7.1.3) to seconds.

  Accepts either:
    * delta-seconds (e.g. `"120"`)
    * HTTP-date in RFC 1123 format (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`)

  Returns nil if the header is missing, malformed, or in the past.
  """
  @spec parse_retry_after([{String.t(), String.t()}]) :: non_neg_integer() | nil
  def parse_retry_after(headers) do
    case get_header(headers, "retry-after") do
      nil -> nil
      value -> parse_retry_after_value(value)
    end
  end

  defp parse_retry_after_value(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> seconds
      _ -> parse_http_date(value)
    end
  end

  defp parse_retry_after_value(_), do: nil

  # RFC 1123 HTTP-date: "Wed, 21 Oct 2015 07:28:00 GMT"
  @http_date_regex ~r/\A\w{3}, (\d{2}) (\w{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT\z/

  defp parse_http_date(value) do
    with [_, day, month, year, hour, minute, second] <- Regex.run(@http_date_regex, value),
         {:ok, month_num} <- month_to_int(month),
         {:ok, dt} <-
           DateTime.new(
             Date.new!(String.to_integer(year), month_num, String.to_integer(day)),
             Time.new!(
               String.to_integer(hour),
               String.to_integer(minute),
               String.to_integer(second)
             )
           ) do
      diff = DateTime.diff(dt, DateTime.utc_now())
      if diff > 0, do: diff, else: nil
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  for {abbr, num} <-
        Enum.with_index(
          ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec),
          1
        ) do
    defp month_to_int(unquote(abbr)), do: {:ok, unquote(num)}
  end

  defp month_to_int(_), do: :error

  @doc "Prepends a header tuple if the value is non-nil."
  @spec maybe_add_header([{String.t(), String.t()}], String.t(), term()) ::
          [{String.t(), String.t()}]
  def maybe_add_header(headers, _key, nil), do: headers
  def maybe_add_header(headers, key, value), do: [{key, to_string(value)} | headers]

  @doc """
  Converts a map's keys and values to strings, as required by FCM `data`.

  Nested maps and lists are JSON-encoded so they survive transport as strings.
  Other non-stringable terms (PIDs, refs, tuples, etc.) are rendered with
  `inspect/1` rather than crashing the calling process.
  """
  @spec stringify_map(nil | map()) :: map() | nil
  def stringify_map(nil), do: nil
  def stringify_map(map) when map == %{}, do: nil

  def stringify_map(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), value_to_string(v)} end)
  end

  defp value_to_string(v) when is_binary(v), do: v
  defp value_to_string(v) when is_atom(v), do: Atom.to_string(v)
  defp value_to_string(v) when is_number(v), do: to_string(v)
  defp value_to_string(v) when is_map(v) or is_list(v), do: JSON.encode!(v)
  defp value_to_string(v), do: inspect(v)

  @doc "Inserts a key only when the value is non-nil and not an empty map."
  @spec maybe_put(map(), String.t(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, _key, data) when data == %{}, do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  JSON-encodes `value` without raising. Returns `{:ok, binary}` or
  `{:error, reason}`. Used on the send path so a payload containing
  un-encodable terms (PIDs, refs, functions, tuples, etc.) doesn't crash
  the calling Task ahead of the regular error-tuple contract.
  """
  @spec safe_encode(term()) :: {:ok, binary()} | {:error, String.t()}
  def safe_encode(value) do
    {:ok, JSON.encode!(value)}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
