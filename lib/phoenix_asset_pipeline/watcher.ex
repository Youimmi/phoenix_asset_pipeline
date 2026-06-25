defmodule PhoenixAssetPipeline.Watcher do
  @moduledoc """
  Watches the configured static directory and rebuilds the manifest in dev.

  Add this child only when Phoenix code reloading is enabled.
  """
  use GenServer

  alias PhoenixAssetPipeline, as: AssetPipeline
  alias PhoenixAssetPipeline.Config

  require Logger

  @debounce_ms 120

  @impl true
  def init(_) do
    static_dir = Path.expand(AssetPipeline.static_dir())

    case FileSystem.start_link(dirs: [static_dir]) do
      {:ok, monitor} ->
        :ok = FileSystem.subscribe(monitor)

        state = %{
          monitor: monitor,
          static_dir: static_dir,
          timer: nil
        }

        {:ok, schedule_rebuild(state)}

      {:error, reason} ->
        Logger.warning("Could not watch static assets for live AssetPipeline rebuilds: #{inspect(reason)}")

        :ignore
    end
  end

  @impl true
  def handle_info({:file_event, monitor, {path, _}}, %{monitor: monitor} = state) do
    state =
      if static_path?(path, state.static_dir),
        do: schedule_rebuild(state),
        else: state

    {:noreply, state}
  end

  def handle_info({:file_event, monitor, :stop}, %{monitor: monitor} = state) do
    {:stop, :normal, state}
  end

  def handle_info(:rebuild_asset_pipeline, state) do
    try do
      if !AssetPipeline.current?() do
        :ok = AssetPipeline.run()
        broadcast_live_reload()
        Logger.debug("Rebuilt AssetPipeline after static asset changes")
      end
    rescue
      exception ->
        Logger.error([
          "Could not rebuild AssetPipeline after static asset changes: ",
          Exception.message(exception)
        ])
    end

    {:noreply, %{state | timer: nil}}
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

  defp schedule_rebuild(%{timer: timer} = state) when is_reference(timer) do
    Process.cancel_timer(timer)

    receive do
      :rebuild_asset_pipeline -> :ok
    after
      0 -> :ok
    end

    schedule_rebuild(%{state | timer: nil})
  end

  defp schedule_rebuild(%{timer: nil} = state) do
    timer = Process.send_after(self(), :rebuild_asset_pipeline, @debounce_ms)
    %{state | timer: timer}
  end

  defp static_path?(path, static_dir) do
    path =
      path
      |> to_string()
      |> Path.expand()

    relative_path = Path.relative_to(path, static_dir)

    relative_path != AssetPipeline.Manifest.cache_relative_path() and
      (path == static_dir or String.starts_with?(path, static_dir <> "/"))
  end
end
