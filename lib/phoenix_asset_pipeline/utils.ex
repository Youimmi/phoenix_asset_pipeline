defmodule PhoenixAssetPipeline.Utils do
  @moduledoc false

  def application_started? do
    List.keymember?(Application.started_applications(), :phoenix_asset_pipeline, 0)
  end

  def cmd([command | args], extra_args, opts) do
    System.cmd(command, args ++ extra_args, opts)
  end

  def dets_file(module) when is_atom(module) do
    file_name =
      Module.split(module)
      |> Enum.map_join(".", &Macro.underscore/1)

    if Code.ensure_loaded?(Mix.Project) do
      Path.join(Path.dirname(Mix.Project.build_path()), file_name)
    else
      Path.expand("_build/" <> file_name)
    end
    |> String.to_charlist()
  end

  def dets_table(file) do
    with {:ok, table} <- :dets.open_file(file, type: :set), do: table
  end

  def digest(content) do
    :erlang.md5(content)
    |> Base.encode16(case: :lower)
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

  def integrity(content) do
    :crypto.hash(:sha512, content)
    |> Base.encode64()
  end

  def normalize(path) do
    Regex.replace(~r/(\/)*$/, path, "")
  end

  defp path_exists?(path) when is_list(path) do
    Enum.all?(path, &File.exists?/1)
  end
end
