defmodule PhoenixAssetPipeline.Utils do
  @moduledoc false

  @assets_path Application.compile_env(:phoenix_asset_pipeline, :assets_path, "assets/css")

  def application_started? do
    List.keymember?(Application.started_applications(), :phoenix_asset_pipeline, 0)
  end

  def assets_path, do: @assets_path

  def cmd(path, args) do
    cmd(path, args, stderr_to_stdout: true)
  end

  def install_sass do
    unless path_exists?(DartSass.bin_path()) do
      DartSass.install()
    end
  end

  def install_esbuild do
    unless File.exists?(Esbuild.bin_path()) do
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
