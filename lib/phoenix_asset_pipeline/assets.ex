defmodule PhoenixAssetPipeline.Assets do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Bun
  alias PhoenixAssetPipeline.Assets.Images
  alias PhoenixAssetPipeline.Assets.Sprites
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files

  @digest_cache_file "asset_digests.term"

  def build(nil), do: []

  def build({assets_dir, sprites, asset_terms, colocated_terms}) do
    Images.build(assets_dir, asset_terms) ++ Bun.build(assets_dir, sprites, asset_terms, colocated_terms)
  end

  def signature_terms(nil), do: []

  def signature_terms({assets_dir, sprites, asset_terms, colocated_terms}) do
    sprite_terms = Sprites.source_terms(sprites)

    asset_build =
      if sprite_terms != [] or Enum.any?(asset_terms, &String.starts_with?(elem(&1, 1), ["css/", "js/", "svg/"])),
        do: {:asset_build, Bun.fingerprint(assets_dir, asset_terms, colocated_terms)},
        else: :no_asset_build

    {asset_terms, colocated_terms, sprite_terms, asset_build, Images.signature(asset_terms)}
  end

  def snapshot do
    assets_dir = Config.assets_dir()

    if File.dir?(assets_dir) do
      {assets_dir, Sprites.snapshot(assets_dir), asset_source_terms(assets_dir), colocated_source_terms()}
    end
  end

  def watch_sources do
    assets_dir = Config.assets_dir()
    project_dir = Config.project_dir()
    sprites = if File.dir?(assets_dir), do: Sprites.snapshot(assets_dir), else: []
    {dependency_dirs, files} = Bun.watch_sources(assets_dir)

    dirs =
      [
        Config.static_dir(),
        assets_dir,
        Config.colocated_dir(),
        Path.join(project_dir, "config"),
        Path.join(project_dir, "lib"),
        Path.join(project_dir, "priv")
      ]
      |> Kernel.++(List.wrap(Config.application_ebin_dir()))
      |> Kernel.++(Sprites.source_dirs(sprites))
      |> Kernel.++(dependency_dirs)
      |> Enum.map(&Path.expand/1)
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)

    watch_dirs =
      files
      |> Enum.reject(&(Path.basename(&1) == ".gitignore" and not String.starts_with?(&1, project_dir <> "/")))
      |> Enum.map(&Path.dirname/1)
      |> Kernel.++(dirs)
      |> Enum.uniq()
      |> Enum.filter(&File.dir?/1)
      |> drop_nested_dirs()

    {watch_dirs, dirs, MapSet.new(files)}
  end

  defp asset_source_terms(assets_dir) do
    for {path, digest} <- Files.digests(assets_dir, @digest_cache_file),
        relative = Path.relative_to(path, assets_dir),
        relative not in ["bun.lock", "package.json"],
        do: {:asset, relative, digest}
  end

  defp colocated_source_terms do
    build_path = Config.build_path()

    for path <- Files.regular_files(Config.colocated_dir()) do
      {:colocated, Path.relative_to(path, build_path), Digest.file(path)}
    end
  end

  defp drop_nested_dirs(dirs) do
    Enum.reject(dirs, fn dir ->
      Enum.any?(dirs, fn other -> dir != other and String.starts_with?(dir, other <> "/") end)
    end)
  end
end
