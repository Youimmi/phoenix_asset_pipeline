defmodule PhoenixAssetPipeline.Watcher do
  @moduledoc """
  Watches PhoenixAssetPipeline source directories and rebuilds the manifest in dev.

  Add this child only when Phoenix code reloading is enabled.
  """
  use GenServer

  alias PhoenixAssetPipeline.Assets
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest

  require Logger

  @debounce_ms 120

  def child_spec(run) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [run]},
      restart: :transient
    }
  end

  @impl true
  def handle_cast(:rebuild, state), do: {:noreply, schedule_rebuild(state)}

  @impl true
  def handle_info({:file_event, monitor, {path, _}}, %{monitor: monitor} = state) do
    state =
      if source_path?(path, state.sources),
        do: schedule_rebuild(state),
        else: state

    {:noreply, state}
  end

  def handle_info({:file_event, monitor, :stop}, %{monitor: monitor} = state) do
    {:stop, {:file_system_stopped, monitor}, state}
  end

  def handle_info({:EXIT, monitor, reason}, %{monitor: monitor} = state) do
    {:stop, {:file_system_exit, reason}, state}
  end

  def handle_info(:rebuild_asset_pipeline, state) do
    {:noreply, start_rebuild(%{state | timer: nil})}
  end

  def handle_info({:asset_pipeline_rebuild_done, pid, sources}, %{rebuild: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, state |> refresh_sources(sources) |> finish_rebuild()}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{rebuild: {pid, ref}} = state) do
    Logger.error("Could not rebuild PhoenixAssetPipeline manifest: #{Exception.format_exit(reason)}")
    {:noreply, finish_rebuild(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def init(run) do
    Process.flag(:trap_exit, true)

    case Assets.watch_sources() do
      {[], _, _} ->
        raise "could not watch PhoenixAssetPipeline sources: no source directories exist"

      sources ->
        start_file_system(sources, run)
    end
  end

  @doc false
  def rebuild do
    GenServer.cast(__MODULE__, :rebuild)
  end

  @doc false
  def start_link(run) when is_function(run, 0) do
    GenServer.start_link(__MODULE__, run, name: __MODULE__)
  end

  @impl true
  def terminate(_, %{rebuild: {pid, _}}) do
    Process.exit(pid, :shutdown)
    :ok
  end

  def terminate(_, _), do: :ok

  defp broadcast_live_reload do
    endpoint = Config.endpoint()

    if is_atom(endpoint) and Process.whereis(endpoint) do
      endpoint.broadcast(
        Config.live_reload_topic(),
        Config.live_reload_event(),
        Config.live_reload_payload()
      )
    end
  end

  defp finish_rebuild(%{pending?: true} = state) do
    schedule_rebuild(%{state | pending?: false, rebuild: nil})
  end

  defp finish_rebuild(state), do: %{state | rebuild: nil}

  defp ignored_source_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == "node_modules"))
  end

  defp refresh_sources(%{sources: {dirs, _, _}} = state, {dirs, _, _} = sources) do
    %{state | sources: sources}
  end

  defp refresh_sources(%{monitor: monitor} = state, sources) do
    new_monitor = start_monitor!(sources)
    Process.unlink(monitor)
    Process.exit(monitor, :shutdown)
    %{state | sources: sources, monitor: new_monitor}
  end

  defp run_rebuild(run) do
    previous_signature = Manifest.get(:signature)

    :ok = run.()

    if previous_signature != Manifest.get(:signature) do
      broadcast_live_reload()
      Logger.debug("Rebuilt PhoenixAssetPipeline manifest")
    end

    Assets.watch_sources()
  end

  defp schedule_rebuild(%{timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)

    receive do
      :rebuild_asset_pipeline -> :ok
    after
      0 -> :ok
    end

    schedule_rebuild(%{state | timer: nil})
  end

  defp schedule_rebuild(%{rebuild: {_, _}} = state), do: %{state | pending?: true}

  defp schedule_rebuild(%{timer: nil} = state) do
    timer = Process.send_after(self(), :rebuild_asset_pipeline, @debounce_ms)
    %{state | timer: timer}
  end

  defp source_path?(path, {_, dirs, files}) do
    path =
      path
      |> to_string()
      |> Path.expand()

    ignored? = ignored_source_path?(path)

    MapSet.member?(files, path) or
      Enum.any?(dirs, fn dir ->
        (path == dir or String.starts_with?(path, dir <> "/")) and
          (!ignored? or ignored_source_path?(dir))
      end)
  end

  defp start_file_system(sources, run) do
    state = %{
      sources: sources,
      monitor: start_monitor!(sources),
      pending?: false,
      rebuild: nil,
      run: run,
      timer: nil
    }

    {:ok, schedule_rebuild(state)}
  end

  defp start_monitor!({dirs, _, _}) do
    {:ok, monitor} = FileSystem.start_link(dirs: dirs)
    :ok = FileSystem.subscribe(monitor)
    monitor
  end

  defp start_rebuild(%{rebuild: nil, run: run} = state) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          sources = run_rebuild(run)
          send(parent, {:asset_pipeline_rebuild_done, self(), sources})
        end,
        [:link, :monitor]
      )

    %{state | rebuild: {pid, ref}, pending?: false}
  end

  defp start_rebuild(state), do: %{state | pending?: true}
end
