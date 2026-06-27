defmodule PhoenixAssetPipeline.Assets do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Bun
  alias PhoenixAssetPipeline.Assets.Images
  alias PhoenixAssetPipeline.Config

  @hero_icon_name_pattern ~r/<\.(?:icon|menu_icon)\b[^>]*\bname\s*=\s*"([a-z0-9][a-z0-9-]*)"[^>]*>|\bicon:\s*"([a-z0-9][a-z0-9-]*)"|\bicon_name\([^)]*\),\s*do:\s*"([a-z0-9][a-z0-9-]*)"/

  def build(assets_dir \\ Config.assets_dir()) do
    assets_dir
    |> build_assets()
    |> unique_assets()
  end

  def signature_terms(assets_dir \\ Config.assets_dir()) do
    if File.dir?(assets_dir) do
      asset_source_terms(assets_dir) ++
        colocated_source_terms() ++
        hero_source_terms(assets_dir) ++
        [{:asset_mode, asset_mode()}]
    else
      []
    end
  end

  def watch_dirs(static_dir \\ Config.static_dir(), assets_dir \\ Config.assets_dir()) do
    [
      static_dir,
      assets_dir,
      Config.colocated_dir(),
      Path.join(project_dir(assets_dir), "config"),
      heroicons_dir(assets_dir),
      Path.join(project_dir(assets_dir), "lib"),
      Path.join(project_dir(assets_dir), "priv")
    ]
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

  defp build_assets(assets_dir) do
    if File.dir?(assets_dir) do
      Images.build(assets_dir) ++
        Bun.build(assets_dir, hero_icon_names(assets_dir))
    else
      []
    end
  end

  defp collect_hero_icon_names(content, names) do
    Enum.reduce(Regex.scan(@hero_icon_name_pattern, content), names, fn [_ | captures], names ->
      case Enum.find(captures, &(&1 != "")) do
        nil -> names
        name -> MapSet.put(names, name)
      end
    end)
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

  defp hero_icon_names(assets_dir) do
    assets_dir
    |> project_lib_dir()
    |> source_files(~w(.ex .heex))
    |> Enum.reduce(MapSet.new(), fn path, names ->
      path
      |> File.read!()
      |> collect_hero_icon_names(names)
    end)
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp hero_icon_path(assets_dir, name) do
    base = heroicons_dir(assets_dir)

    cond do
      String.ends_with?(name, "-micro") -> Path.join([base, "16/solid", String.trim_trailing(name, "-micro") <> ".svg"])
      String.ends_with?(name, "-mini") -> Path.join([base, "20/solid", String.trim_trailing(name, "-mini") <> ".svg"])
      String.ends_with?(name, "-solid") -> Path.join([base, "24/solid", String.trim_trailing(name, "-solid") <> ".svg"])
      true -> Path.join([base, "24/outline", name <> ".svg"])
    end
  end

  defp hero_source_terms(assets_dir) do
    lib_terms =
      assets_dir
      |> project_lib_dir()
      |> source_files(~w(.ex .heex))
      |> Enum.map(&source_term(:hero_source, &1, project_dir(assets_dir)))

    icon_terms =
      assets_dir
      |> hero_icon_names()
      |> Enum.map(fn name -> source_term(:heroicon, hero_icon_path(assets_dir, name), heroicons_dir(assets_dir)) end)

    lib_terms ++ icon_terms
  end

  defp heroicons_dir(assets_dir), do: assets_dir |> project_dir() |> Path.join("deps/heroicons/optimized")

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))
  defp project_lib_dir(assets_dir), do: assets_dir |> project_dir() |> Path.join("lib")

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

  defp source_files(dir, exts) do
    dir
    |> regular_files()
    |> Enum.filter(&(Path.extname(&1) in exts))
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
