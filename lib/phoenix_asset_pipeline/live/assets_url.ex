defmodule PhoenixAssetPipeline.Live.AssetsURL do
  @moduledoc false

  import Phoenix.LiveView

  def on_mount(_, _, %{"assets_url" => assets_url}, socket) do
    {:cont, assign_new(socket, :assets_url, fn -> assets_url end)}
  end

  def on_mount(_, _, _, socket), do: {:cont, socket}
end
