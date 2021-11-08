defmodule AssetPipeline do
  @moduledoc """
  Asset pipeline for Phoenix app
  """

  def start(_type, _args) do
    unless DartSass.installed?(), do: DartSass.install()
    unless File.exists?(Esbuild.bin_path()), do: Esbuild.install()

    Supervisor.start_link([], strategy: :one_for_one)
  end
end
