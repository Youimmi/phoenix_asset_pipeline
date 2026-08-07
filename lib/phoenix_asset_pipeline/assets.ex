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
    {assets_dir, sprites}
    |> snapshot()
    |> build()
  end

  def build({assets_dir, sprites, asset_terms, colocated_terms}) do
    assets_dir
    |> build_assets(sprites, asset_terms, colocated_terms)
    |> unique_assets()
  end

  def signature_terms(source \\ sources())

  def signature_terms(nil), do: []

  def signature_terms(assets_dir) when is_binary(assets_dir) do
    assets_dir
    |> sources()
    |> snapshot()
    |> signature_terms()
  end

  def signature_terms({assets_dir, sprites}) do
    {assets_dir, sprites}
    |> snapshot()
    |> signature_terms()
  end

  def signature_terms({assets_dir, sprites, asset_terms, colocated_terms}) do
    sprite_terms = Sprites.source_terms(sprites)
    asset_signature_terms = Enum.map(asset_terms, &asset_signature_term/1)

    asset_build =
      if bun_required?(asset_signature_terms, sprite_terms),
        do: {:asset_build, Bun.fingerprint(assets_dir)},
        else: :no_asset_build

    image_build = Images.signature(asset_signature_terms)

    {
      asset_signature_terms,
      colocated_terms,
      sprite_terms,
      asset_build,
      image_build
    }
  end

  def snapshot(source \\ sources())

  def snapshot(nil), do: nil

  def snapshot({assets_dir, sprites}) do
    {assets_dir, sprites, asset_source_terms(assets_dir), colocated_source_terms()}
  end

  def snapshot({_, _, _, _} = snapshot), do: snapshot

  def sources(assets_dir \\ Config.assets_dir()) do
    if File.dir?(assets_dir) do
      {Path.expand(assets_dir), Sprites.snapshot(assets_dir)}
    end
  end

  def watch_dirs(static_dir \\ Config.static_dir(), assets_dir \\ Config.assets_dir()) do
    source = sources(assets_dir)

    ([
       static_dir,
       assets_dir,
       Config.colocated_dir(),
       Path.join(project_dir(assets_dir), "config"),
       Path.join(project_dir(assets_dir), "lib"),
       Path.join(project_dir(assets_dir), "priv")
     ] ++ List.wrap(Config.application_ebin_dir()))
    |> Kernel.++(sprite_source_dirs(source))
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.filter(&File.dir?/1)
    |> drop_nested_dirs()
  end

  defp asset_source_terms(assets_dir) do
    assets_dir
    |> regular_files()
    |> Enum.reduce([], fn path, terms ->
      relative = path |> Path.relative_to(assets_dir) |> forward_path()

      if relative in ["package.json", "bun.lock"] do
        terms
      else
        [asset_source_term(path, relative) | terms]
      end
    end)
    |> :lists.reverse()
  end

  defp build_assets(assets_dir, sprites, asset_terms, colocated_terms) do
    Images.build(assets_dir, asset_terms) ++
      Bun.build(assets_dir, Sprites.entries(sprites), asset_terms, colocated_terms)
  end

  defp bun_required?(_asset_terms, [_ | _]), do: true

  defp bun_required?(asset_terms, []) do
    Enum.any?(asset_terms, fn
      {:asset, "js/" <> _, _} -> true
      {:asset, "css/" <> _, _} -> true
      {:asset, "svg/" <> _, _} -> true
      {:asset, "js/" <> _, _, _} -> true
      {:asset, "css/" <> _, _, _} -> true
      {:asset, "svg/" <> _, _, _} -> true
      _ -> false
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

  defp asset_signature_term({:asset, path, digest, _}), do: {:asset, path, digest}
  defp asset_signature_term(term), do: term

  defp asset_source_term(path, relative) do
    content = File.read!(path)
    digest = :erlang.md5(content)

    if String.starts_with?(relative, "img/"),
      do: {:asset, relative, digest, content},
      else: {:asset, relative, digest}
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, content} -> :erlang.md5(content)
      {:error, :enoent} -> :missing
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp forward_path(path), do: String.replace(path, "\\", "/")

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

  defp sprite_source_dirs(nil), do: []
  defp sprite_source_dirs({_, sprites}), do: Sprites.source_dirs(sprites)

  defp regular_entry(_, "." <> _), do: []
  defp regular_entry(_, "node_modules"), do: []

  defp regular_entry(dir, entry) do
    path = Path.join(dir, entry)

    case File.stat(path) do
      {:ok, %{type: :directory}} -> regular_files_in(path)
      {:ok, %{type: :regular}} -> [path]
      {:ok, _} -> []
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "stat asset source", path: path
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
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "list asset sources", path: dir
    end
  end

  defp source_term(type, path, root) do
    {type, path |> Path.relative_to(root) |> forward_path(), file_digest(path)}
  end

  defp unique_assets(assets) do
    assets
    |> Enum.reduce(%{}, fn {path, content}, acc -> Map.put(acc, path, content) end)
    |> Enum.sort()
  end
end
