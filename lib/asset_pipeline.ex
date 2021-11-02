defmodule AssetPipeline do
  @moduledoc """
  Asset pipeline for Phoenix app
  """

  def start(_type, _args) do
    unless DartSass.installed?(), do: DartSass.install()
    unless File.exists?(Esbuild.bin_path()), do: Esbuild.install()

    children = []
    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
