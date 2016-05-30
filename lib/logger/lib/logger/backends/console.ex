defmodule Logger.Backends.Console do
  @moduledoc false

  use GenEvent

  def init(:console) do
    if Process.whereis(:user) do
      init({:user, []})
    else
      {:error, :ignore}
    end
  end

  def init({device, opts}) do
    {:ok, configure(device, opts)}
  end

  def handle_call({:configure, options}, state) do
    {:ok, :ok, configure(state.device, options)}
  end

  def handle_event({_level, gl, _event}, state)
  when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    %{level: log_level, ref: ref, buffer_size: buffer_size,
      max_buffer: max_buffer} = state
    cond do
      not meet_level?(level, log_level) ->
        {:ok, state}
      is_nil(ref) ->
        {:ok, log_event(level, msg, ts, md, state)}
      buffer_size < max_buffer ->
        {:ok, buffer_event(level, msg, ts, md, state)}
      buffer_size === max_buffer ->
        state = buffer_event(level, msg, ts, md, state)
        {:ok, await_and_log(state)}
    end
  end

  def handle_event(:flush, state) do
    {:ok, flush(state)}
  end

  def handle_info({:io_reply, ref, :ok}, %{ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:ok, log_buffer(%{state | ref: nil, last_ts: nil})}
  end

  def handle_info({:io_reply, ref, {:error, error}}, %{ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    {:ok, handle_error(error, %{state | ref: nil})}
  end

  def handle_info({:DOWN, ref, _, pid, reason}, %{ref: ref}) do
    raise "device #{inspect pid} exited: " <> Exception.format_exit(reason)
  end

  def handle_info(_, state) do
    {:ok, state}
  end

  ## Helpers

  defp meet_level?(_lvl, nil), do: true

  defp meet_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  defp configure(device, options) do
    config =
      Application.get_env(:logger, :console, [])
      |> configure_merge(options)

    if device === :user do
      Application.put_env(:logger, :console, config)
    end

    format     = Logger.Formatter.compile Keyword.get(config, :format)
    level      = Keyword.get(config, :level)
    metadata   = Keyword.get(config, :metadata, [])
    colors     = configure_colors(config)
    max_buffer = Keyword.get(config, :max_buffer, 32)
    %{format: format, metadata: Enum.reverse(metadata),
      level: level, colors: colors, device: device, max_buffer: max_buffer,
      buffer_size: 0, buffer_ts: nil, buffer: [], ref: nil, last_ts: nil}
  end

  defp configure_merge(env, options) do
    Keyword.merge(env, options, fn
      :colors, v1, v2 -> Keyword.merge(v1, v2)
      _, _v1, v2 -> v2
    end)
  end

  defp configure_colors(config) do
    colors = Keyword.get(config, :colors, [])
    %{debug: Keyword.get(colors, :debug, :cyan),
      info: Keyword.get(colors, :info, :normal),
      warn: Keyword.get(colors, :warn, :yellow),
      error: Keyword.get(colors, :error, :red),
      enabled: Keyword.get(colors, :enabled, IO.ANSI.enabled?)}
  end

  defp log_event(level, msg, ts, md, %{device: device} = state) do
    output = format_event(level, msg, ts, md, state)
    %{state | ref: async_io(device, output), last_ts: ts}
  end

  defp buffer_event(level, msg, ts, md, state) do
    %{buffer: buffer, buffer_size: buffer_size} = state
    buffer = [buffer | format_event(level, msg, ts, md, state)]
    %{state | buffer: buffer, buffer_size: buffer_size + 1, buffer_ts: ts}
  end

  defp async_io(device, output) do
    pid = GenServer.whereis(device)
    ref = Process.monitor(pid)
    send(pid, {:io_request, self(), ref, {:put_chars, :unicode, output}})
    ref
  end

  defp await_io(%{ref: nil} = state), do: state

  defp await_io(%{ref: ref} = state) do
    receive do
      {:io_reply, ^ref, :ok} ->
        Process.demonitor(ref, [:flush])
        %{state | ref: nil, last_ts: nil}
      {:io_reply, ^ref, {:error, error}} ->
        Process.demonitor(ref, [:flush])
        await_io(handle_error(error, %{state | ref: nil}))
      {:DOWN, ^ref, _, pid, reason} ->
        raise "device #{inspect pid} exited: " <> Exception.format_exit(reason)
    end
  end

  defp format_event(level, msg, ts, md, state) do
    %{format: format, metadata: keys, colors: colors} = state
    format
    |> Logger.Formatter.format(level, msg, ts, take_metadata(md, keys))
    |> color_event(level, colors)
  end

  defp take_metadata(metadata, keys) do
    Enum.reduce keys, [], fn key, acc ->
      case Keyword.fetch(metadata, key) do
        {:ok, val} -> [{key, val} | acc]
        :error     -> acc
      end
    end
  end

  defp color_event(data, _level, %{enabled: false}), do: data

  defp color_event(data, level, %{enabled: true} = colors) do
    [IO.ANSI.format_fragment(Map.fetch!(colors, level), true), data | IO.ANSI.reset]
  end

  defp log_buffer(%{buffer_size: 0, buffer: []} = state), do: state

  defp log_buffer(state) do
    %{device: device, buffer: buffer, buffer_ts: buffer_ts} = state
    %{state | ref: async_io(device, buffer), buffer: [], buffer_size: 0,
      buffer_ts: nil, last_ts: buffer_ts}
  end

  defp handle_error(error, %{last_ts: :error}) do
    raise "failure while logging console messages: " <>
      inspect(error, width: :infinity)
  end

  defp handle_error({:put_chars, :unicode, data} = error, state) do
    %{device: device} = state
    case :unicode.characters_to_binary(data) do
      {_, good, bad} ->
        unicode_data = [good | Logger.Formatter.prune(bad)]
        %{state | ref: async_io(device, unicode_data)}
      _ ->
        # A well behaved IO device should not error on good data
        io_error(error, state)
    end
  end

  defp handle_error(error, state) do
    io_error(error, state)
  end

  defp io_error(error, %{last_ts: last_ts} = state) do
    msg = ["Failure while logging console messages: " |
      inspect(error, width: :infinity)]
    log_event(:error, msg, last_ts, [], %{state | last_ts: :error})
  end

  defp await_and_log(state) do
    state
    |> await_io()
    |> log_buffer()
  end

  defp flush(state) do
    state
    |> await_io()
    |> log_buffer()
    |> await_io()
  end
end
