defmodule PhoenixAssetPipeline.Utils do
  @moduledoc false

  defmacro __before_compile__(_) do
    install_esbuild()
    install_sass()
  end

  def application_started? do
    List.keymember?(Application.started_applications(), :phoenix_asset_pipeline, 0)
  end

  def cmd([command | args], extra_args, opts) do
    System.cmd(command, args ++ extra_args, opts)
  end

  def dets_file(module) when is_atom(module) do
    dets_file_path(module)
    |> String.to_charlist()
  end

  def dets_file_path(module) do
    path =
      Module.split(module)
      |> Enum.map_join(".", &Macro.underscore/1)

    if Code.ensure_loaded?(Mix.Project) do
      Mix.Project.build_path()
      |> Path.dirname()
      |> Path.join(path)
    else
      Path.expand("_build/" <> path)
    end
  end

  def dets_table(file) do
    with {:ok, table} <- :dets.open_file(file, type: :set), do: table
  end

  def digest(content) do
    :erlang.md5(content)
    |> Base.encode16(case: :lower)
  end

  def install_sass do
    paths_exist?(DartSass.bin_paths()) || DartSass.install()
  end

  def install_esbuild do
    unless File.exists?(Esbuild.bin_path()) do
      Esbuild.install()
    end
  end

  def integrity(content) do
    :crypto.hash(:sha512, content)
    |> Base.encode64()
  end

  def normalize(path) do
    Regex.replace(~r/(\/)*$/, path, "")
  end

  defp paths_exist?(paths) when is_list(paths) do
    paths |> Enum.all?(&File.exists?/1)
  end
end
