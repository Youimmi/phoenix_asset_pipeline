defmodule PhoenixAssetPipeline.Assets do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Bun
  alias PhoenixAssetPipeline.Assets.Images
  alias PhoenixAssetPipeline.Assets.Sprites
  alias PhoenixAssetPipeline.Config

  def build(source \\ sources())

  def build(nil), do: []
  def build(assets_dir) when is_binary(assets_dir), do: assets_dir |> sources() |> build()

  def build({assets_dir, sprites}) do
    assets_dir
    |> build_assets(sprites)
    |> unique_assets()
  end

  def signature_terms(source \\ sources())

  def signature_terms(nil), do: []
  def signature_terms(assets_dir) when is_binary(assets_dir), do: assets_dir |> sources() |> signature_terms()

  def signature_terms({assets_dir, sprites}) do
    asset_source_terms(assets_dir) ++
      colocated_source_terms() ++
      Sprites.source_terms(sprites) ++
      [{:asset_mode, asset_mode()}]
  end

  def sources(assets_dir \\ Config.assets_dir()) do
    if File.dir?(assets_dir) do
      {Path.expand(assets_dir), Sprites.snapshot(assets_dir)}
    end
  end

  def watch_dirs(static_dir \\ Config.static_dir(), assets_dir \\ Config.assets_dir()) do
    source = sources(assets_dir)

    [
      static_dir,
      assets_dir,
      Config.colocated_dir(),
      Path.join(project_dir(assets_dir), "config"),
      Path.join(project_dir(assets_dir), "lib"),
      Path.join(project_dir(assets_dir), "priv")
    ]
    |> Kernel.++(sprite_source_dirs(source))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
    |> drop_nested_dirs()
  end

  defp asset_mode do
    if Config.precompiled_manifest?(), do: :prod, else: :dev
  end

  defp asset_source_terms(assets_dir) do
    assets_dir
    |> regular_files()
    |> Enum.map(&source_term(:asset, &1, assets_dir))
  end

  defp build_assets(assets_dir, sprites) do
    Images.build(assets_dir) ++
      Bun.build(assets_dir, Sprites.entries(sprites))
  end

  defp colocated_source_terms do
    Config.colocated_dir()
    |> regular_files()
    |> Enum.map(&source_term(:colocated, &1, Config.build_path()))
  end

  defp drop_nested_dirs(dirs) do
    Enum.reject(dirs, fn dir ->
      Enum.any?(dirs, fn other -> dir != other and String.starts_with?(dir, other <> "/") end)
    end)
  end

  defp file_digest(path) do
    if File.regular?(path) do
      path
      |> File.read!()
      |> :erlang.md5()
      |> Base.encode16(case: :lower)
    else
      :missing
    end
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

  defp sprite_source_dirs(nil), do: []
  defp sprite_source_dirs({_, sprites}), do: Sprites.source_dirs(sprites)

  defp regular_entry(_, "." <> _), do: []
  defp regular_entry(_, "node_modules"), do: []

  defp regular_entry(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) -> regular_files_in(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  defp regular_files(dir) do
    dir
    |> Path.expand()
    |> regular_files_in()
    |> Enum.sort()
  end

  defp regular_files_in(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &regular_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp source_term(type, path, root) do
    {type, Path.relative_to(path, root), file_digest(path)}
  end

  defp unique_assets(assets) do
    assets
    |> Enum.reduce(%{}, fn {path, content}, acc -> Map.put(acc, path, content) end)
    |> Enum.sort()
  end
end
