defmodule PushX.Batch do
  @moduledoc false

  # The one batch engine behind PushX.push_batch/4, push_batch_stream/4,
  # PushX.APNS.send_batch/3 and PushX.FCM.send_batch/3. It used to exist as
  # three near-identical copies that drifted (different timeout defaults,
  # concurrency defaults, target guards, and input enumeration). Keep all
  # batch semantics here:
  #
  #   * bounded concurrency under PushX.TaskSupervisor, tasks unlinked so a
  #     raising task is reported per token instead of killing the caller;
  #   * one result per input, in input order, input enumerated exactly once
  #     (killed/crashed tasks recover their token via :zip_input_on_exit);
  #   * per-task timeout sized to the effective retry policy;
  #   * optional local token validation for binary tokens only — FCM
  #     topic/condition targets are validated by the send path itself.

  alias PushX.{Config, Response, Token}

  @type target :: PushX.target()
  @type result :: {:ok, Response.t()} | {:error, Response.t()}

  @doc """
  Lazily runs `send_fun` over `targets` and yields `{target, result}` pairs.

    * `send_fun` — arity-1 function taking a target and returning a result
    * `validate_provider` — `:apns`/`:fcm` to enable `:validate_tokens` for
      binary tokens, or `nil` (named instances) to skip validation
    * `error_provider` — provider stamped on timeout / crash responses
    * `opts` — `:concurrency`, `:timeout`, `:validate_tokens`; the remaining
      options are the caller's send options and are only inspected for
      `:retry` (to size the default timeout)
  """
  @spec stream(
          Enumerable.t(),
          (target() -> result()),
          :apns | :fcm | :webpush | nil,
          atom(),
          keyword()
        ) ::
          Enumerable.t()
  def stream(targets, send_fun, validate_provider, error_provider, opts) do
    concurrency = Keyword.get(opts, :concurrency, Config.get(:batch_concurrency, 50))
    validate = Keyword.get(opts, :validate_tokens, false) and not is_nil(validate_provider)

    timeout =
      Keyword.get_lazy(opts, :timeout, fn ->
        Config.batch_timeout_ms(retry: Keyword.get(opts, :retry, :blocking))
      end)

    PushX.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(
      targets,
      fn target ->
        if validate and is_binary(target) and not Token.valid?(validate_provider, target) do
          {target,
           {:error, Response.error(validate_provider, :invalid_token, "Invalid token format")}}
        else
          {target, send_fun.(target)}
        end
      end,
      max_concurrency: concurrency,
      timeout: timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Stream.map(fn
      {:ok, pair} ->
        pair

      {:exit, {target, :timeout}} ->
        {target, {:error, Response.error(error_provider, :connection_error, "timeout")}}

      # A task that raises (rather than returning an error tuple) exits with
      # {exception, stacktrace}. Report it for that token only.
      {:exit, {target, reason}} ->
        {target,
         {:error,
          Response.error(error_provider, :unknown_error, "task exited: " <> inspect(reason))}}
    end)
  end

  @doc "Options consumed by the batch layer; everything else is passed to the send function."
  @spec batch_option_keys() :: [atom()]
  def batch_option_keys, do: [:concurrency, :timeout, :validate_tokens]
end
