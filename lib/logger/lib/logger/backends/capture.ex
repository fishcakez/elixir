defmodule Logger.Backends.Capture do
  @moduledoc false

  use GenEvent

  def init(proxy, opts \\ []) do
    {:ok, configure([], proxy, opts)}
  end

  def handle_call({:configure, options}, state) do
    {:ok, :ok, configure(state.events, state.proxy, options)}
  end

  def handle_event({_level, gl, _event}, %{proxy: proxy} = state) when gl != proxy do
    {:ok, state}
  end

  def handle_event({level, _gl, {Logger, msg, ts, md}}, state) do
    if match_level?(level, state.level) do
      log_event(level, msg, ts, md, state)
    else
      {:ok, state}
    end
  end

  def terminate(:get, state) do
    {:ok, Enum.reverse(state.events)}
  end

  def terminate(_reason, _state),
    do: :ok

  defp match_level?(_lvl, nil),
    do: true

  defp match_level?(lvl, min) do
    Logger.compare_levels(lvl, min) != :lt
  end

  ## Helpers

  defp configure(events, proxy, options) do
    config =
      Application.get_env(:logger, :capture, [])
      |> configure_merge(options)

    format =
      Keyword.get(config, :format)
      |> Logger.Formatter.compile
    level    = Keyword.get(config, :level)
    metadata = Keyword.get(config, :metadata, [])
    colors   = configure_colors(config)
    %{format: format, metadata: metadata,
      level: level, colors: colors,
      events: events, proxy: proxy}
  end

  defp configure_merge(env, options) do
    Keyword.merge(env, options, fn
      :colors, v1, v2 -> Keyword.merge(v1, v2)
      _key, _v1, v2 -> v2
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

  defp log_event(level, msg, ts, md, %{colors: colors, events: acc} = state) do
    ansidata = format_event(level, msg, ts, md, state)
    chardata = color_event(level, ansidata, colors)
    {:ok, %{state | events: [chardata | acc]}}
  end

  defp format_event(level, msg, ts, md, %{format: format, metadata: metadata}) do
    Logger.Formatter.format(format, level, msg, ts, Dict.take(md, metadata))
  end

  defp color_event(level, data, %{enabled: true} = colors), do:
    [IO.ANSI.format_fragment(Map.fetch!(colors, level), true), data | IO.ANSI.reset]
  defp color_event(_level, data, %{enabled: false}), do:
    data
end