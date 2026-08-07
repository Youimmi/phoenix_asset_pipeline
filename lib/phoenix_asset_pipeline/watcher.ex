defmodule PhoenixAssetPipeline.Watcher do
  @moduledoc """
  Watches PhoenixAssetPipeline source directories and rebuilds the manifest in dev.

  Add this child only when Phoenix code reloading is enabled.
  """
  use GenServer

  alias PhoenixAssetPipeline, as: AssetPipeline
  alias PhoenixAssetPipeline.Assets
  alias PhoenixAssetPipeline.Config

  require Logger

  @debounce_ms 120

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    dirs = Assets.watch_dirs()

    case dirs do
      [] ->
        Logger.warning("Could not watch PhoenixAssetPipeline sources: no source directories exist")

        :ignore

      [_ | _] ->
        start_file_system(dirs)
    end
  end

  defp start_file_system(dirs) do
    case FileSystem.start_link(dirs: dirs) do
      {:ok, monitor} ->
        :ok = FileSystem.subscribe(monitor)

        state = %{
          dirs: dirs,
          monitor: monitor,
          pending?: false,
          rebuild: nil,
          timer: nil
        }

        {:ok, schedule_rebuild(state)}

      {:error, reason} ->
        Logger.warning("Could not watch PhoenixAssetPipeline sources: #{inspect(reason)}")

        :ignore
    end
  end

  @impl true
  def handle_info({:file_event, monitor, {path, _}}, %{monitor: monitor} = state) do
    state =
      if source_path?(path, state.dirs),
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

  def handle_info({:asset_pipeline_rebuild_done, pid}, %{rebuild: {pid, ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply, finish_rebuild(state)}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{rebuild: {pid, ref}} = state) do
    if reason != :normal do
      Logger.error("Could not rebuild PhoenixAssetPipeline manifest: #{inspect(reason)}")
    end

    {:noreply, finish_rebuild(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  def child_spec(_) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      restart: :transient
    }
  end

  @doc false
  def start_link do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc false
  def rebuild do
    GenServer.cast(__MODULE__, :rebuild)
  end

  @impl true
  def handle_cast(:rebuild, state), do: {:noreply, schedule_rebuild(state)}

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

  defp run_rebuild do
    previous_signature = AssetPipeline.Manifest.get(:signature)

    :ok = AssetPipeline.run()

    if previous_signature != AssetPipeline.Manifest.get(:signature) do
      broadcast_live_reload()
      Logger.debug("Rebuilt PhoenixAssetPipeline manifest")
    end
  rescue
    exception ->
      Logger.error([
        "Could not rebuild PhoenixAssetPipeline manifest: ",
        Exception.message(exception)
      ])
  end

  defp finish_rebuild(%{pending?: true} = state) do
    schedule_rebuild(%{state | pending?: false, rebuild: nil})
  end

  defp finish_rebuild(state), do: %{state | rebuild: nil}

  defp start_rebuild(%{rebuild: nil} = state) do
    parent = self()

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          run_rebuild()
          send(parent, {:asset_pipeline_rebuild_done, self()})
        end,
        [:link, :monitor]
      )

    %{state | rebuild: {pid, ref}, pending?: false}
  end

  defp start_rebuild(state), do: %{state | pending?: true}

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

  defp source_path?(path, dirs) do
    path =
      path
      |> to_string()
      |> Path.expand()

    !ignored_source_path?(path) and Enum.any?(dirs, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp ignored_source_path?(path) do
    path
    |> Path.split()
    |> Enum.any?(&(&1 == "node_modules"))
  end
end
