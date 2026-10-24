defmodule PhoenixAssetPipeline.Assets do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Bun
  alias PhoenixAssetPipeline.Assets.Images
  alias PhoenixAssetPipeline.Assets.Sprites
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files

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
        do: {:asset_build, Bun.fingerprint(assets_dir, asset_signature_terms, colocated_terms)},
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

  def watch_sources(static_dir \\ Config.static_dir(), assets_dir \\ Config.assets_dir()) do
    source = sources(assets_dir)
    {dependency_dirs, files} = Bun.watch_sources(assets_dir)

    dirs =
      ([
         static_dir,
         assets_dir,
         Config.colocated_dir(),
         Path.join(project_dir(assets_dir), "config"),
         Path.join(project_dir(assets_dir), "lib"),
         Path.join(project_dir(assets_dir), "priv")
       ] ++ List.wrap(Config.application_ebin_dir()))
      |> Kernel.++(sprite_source_dirs(source))
      |> Kernel.++(dependency_dirs)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)

    watch_dirs =
      files
      |> Enum.map(&Path.dirname/1)
      |> Kernel.++(dirs)
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)
      |> drop_nested_dirs()

    {watch_dirs, dirs, MapSet.new(files)}
  end

  defp asset_signature_term({:asset, path, digest, _}), do: {:asset, path, digest}
  defp asset_signature_term(term), do: term

  defp asset_source_term(path, relative) do
    content = File.read!(path)
    digest = Digest.binary(content)

    if String.starts_with?(relative, "img/"),
      do: {:asset, relative, digest, content},
      else: {:asset, relative, digest}
  end

  defp asset_source_terms(assets_dir) do
    assets_dir
    |> Files.regular_files()
    |> Enum.reduce([], fn path, terms ->
      relative = Files.relative_path(path, assets_dir)

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
    |> Files.regular_files()
    |> Enum.map(&source_term(:colocated, &1, Config.build_path()))
  end

  defp drop_nested_dirs(dirs) do
    Enum.reject(dirs, fn dir ->
      Enum.any?(dirs, fn other -> dir != other and String.starts_with?(dir, other <> "/") end)
    end)
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, content} -> Digest.binary(content)
      {:error, :enoent} -> :missing
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

  defp source_term(type, path, root) do
    {type, Files.relative_path(path, root), file_digest(path)}
  end

  defp sprite_source_dirs(nil), do: []
  defp sprite_source_dirs({_, sprites}), do: Sprites.source_dirs(sprites)

  defp unique_assets(assets) do
    assets
    |> Enum.reduce(%{}, fn asset, acc ->
      path = elem(asset, 0)
      if is_map_key(acc, path), do: raise(ArgumentError, "duplicate asset output path: #{inspect(path)}")
      Map.put(acc, path, asset)
    end)
    |> Map.values()
    |> Enum.sort()
  end
end
