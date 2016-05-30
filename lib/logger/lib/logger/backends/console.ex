defmodule Logger.Backends.Console do
  @moduledoc false

  use GenEvent

  def flush(handler) do
    GenEvent.call(Logger, handler, :flush)
  end

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

  def handle_call(:flush, state) do
    {:ok, :ok, flush_buffer(state)}
  end

  def handle_event({_level, gl, _event}, state)
  when node(gl) != node() do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    %{level: log_level, ref: ref, batch_size: batch_size,
      max_buffer: max_buffer} = state
    cond do
      not meet_level?(level, log_level) ->
        {:ok, state}
      is_nil(ref) ->
        {:ok, log_event(level, msg, ts, md, state)}
      batch_size < max_buffer ->
        {:ok, buffer_event(level, msg, ts, md, state)}
      true ->
        {:ok, %{state | batch_size: batch_size + 1}}
    end
  end

  def handle_info({:io_reply, ref, _}, %{ref: ref} = state) do
    {:ok, flush_buffer(%{state | ref: nil})}
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
      batch_size: 0, buffer: [], ref: nil}
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

  defp log_event(level, msg, ts, md, state) do
    %{colors: colors, device: device} = state
    output =
      format_event(level, msg, ts, md, state)
      |> color_event(level, colors)
    %{state | ref: io_request(device, output)}
  end

  defp io_request(device, output) do
    ref = make_ref
    send(device, {:io_request, self(), ref, {:put_chars, :unicode, output}})
    ref
  end

  defp buffer_event(level, msg, ts, md, state) do
    %{colors: colors, buffer: buffer, batch_size: batch_size} = state
    output =
      format_event(level, msg, ts, md, state)
      |> color_event(level, colors)
    buffer = [buffer | output]
    %{state | buffer: buffer, batch_size: batch_size + 1}
  end

  defp format_event(level, msg, ts, md, %{format: format, metadata: keys}) do
    Logger.Formatter.format(format, level, msg, ts, take_metadata(md, keys))
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

  defp flush_buffer(%{batch_size: 0} = state) do
    state
  end

  defp flush_buffer(%{device: device, buffer: buffer} = state) do
    next_ref = io_request(device, [buffer | dropping(state)])
    %{state | ref: next_ref, buffer: [], batch_size: 0}
  end

  defp dropping(%{batch_size: batch_size, max_buffer: max_buffer})
  when batch_size <= max_buffer do
    []
  end

  defp dropping(state) do
    %{batch_size: batch_size, max_buffer: max_buffer, colors: colors} = state
    dropped = batch_size - max_buffer
    msg = "#{inspect __MODULE__} dropped #{inspect dropped} events as it " <>
          "exceeded the max buffer size of #{inspect max_buffer} messages"
    color_event(msg, :error, colors)
  end
end
