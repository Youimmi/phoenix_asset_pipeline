defmodule PhoenixAssetPipeline.Utils do
  @moduledoc false

  defmacro __before_compile__(_) do
    Application.put_all_env(
      dart_sass: [version: Application.get_env(:dart_sass, :version, "1.77.8")],
      esbuild: [version: Application.get_env(:esbuild, :version, "0.23.0")],
      tailwind: [version: Application.get_env(:tailwind, :version, "3.4.7")]
    )

    File.exists?(Esbuild.bin_path()) || Esbuild.install()
    Enum.all?(DartSass.bin_paths(), &File.exists?/1) || DartSass.install()
    File.exists?(Tailwind.bin_path()) || Tailwind.install()
  end

  def application_started? do
    List.keymember?(Application.started_applications(), :phoenix_asset_pipeline, 0)
  end

  def assets_paths do
    assets_path = Path.join([File.cwd!(), "assets"])

    glob = [
      Path.join([assets_path, "css", "**/*.{css,sass,scss}"]),
      Path.join([assets_path, "img", "**/*.{png,svg}"]),
      Path.join([assets_path, "js", "**/*.{js,ts}"])
    ]

    for paths <- glob, path <- Path.wildcard(paths), do: path
  end

  def cmd([command | args], extra_args, opts) do
    cmd(command, args ++ extra_args, opts)
  end

  def cmd(command, args, opts) do
    System.cmd(command, args, opts)
  end

  def dets_file(module) when is_atom(module) do
    dets_file_path(module)
    |> String.to_charlist()
  end

  def dets_table(file) do
    with {:ok, table} <- :dets.open_file(file, type: :set), do: table
  end

  def digest(content) do
    :erlang.md5(content)
    |> Base.encode16(case: :lower)
  end

  def integrity(content) do
    :crypto.hash(:sha512, content)
    |> Base.encode64()
  end

  def normalize(path) do
    Regex.replace(~r/(\/)*$/, path, "")
  end

  defp dets_file_path(module) when is_atom(module) do
    path =
      Module.split(module)
      |> Enum.map_join(".", &Macro.underscore/1)

    if Code.loaded?(Mix.Project) do
      Mix.Project.build_path()
      |> Path.dirname()
      |> Path.join(path)
    else
      Path.expand("_build/" <> path)
    end
  end
end
