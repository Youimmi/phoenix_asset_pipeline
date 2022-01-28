defmodule PhoenixAssetPipeline.Utils do
  @moduledoc false

  @assets_path Application.compile_env(:phoenix_asset_pipeline, :assets_path, "assets/css")

  def assets_path, do: @assets_path

  def cmd(path, args) do
    cmd(path, args, stderr_to_stdout: true)
  end

  def install_sass do
    path = DartSass.bin_path()

    unless path_exists?(path) do
      DartSass.install()
    end
  end

  def install_esbuild do
    path = Esbuild.bin_path()

    unless File.exists?(path) do
      Esbuild.install()
    end
  end

  defp cmd([command | args], extra_args, opts) do
    System.cmd(command, args ++ extra_args, opts)
  end

  defp path_exists?(path) do
    Enum.all?(path, &File.exists?/1)
  end
end
