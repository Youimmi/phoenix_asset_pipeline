defmodule PhoenixAssetPipeline.Assets.Images do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Images.PNG
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @cache_file "image_assets.term"
  @image_exts ~w(.avif .jpeg .jpg .png .webp)
  @png_options [compression: 9, keep: [:VIPS_FOREIGN_KEEP_NONE]]
  @avif_options [compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1, effort: 9, keep: [:VIPS_FOREIGN_KEEP_NONE]]
  @avif_1x_options [Q: 82] ++ @avif_options
  @avif_high_density_options [Q: 55] ++ @avif_options
  @webp_options [Q: 88, keep: [:VIPS_FOREIGN_KEEP_NONE]]
  @encoding {2, @png_options, @avif_1x_options, @avif_high_density_options, @webp_options}

  def blob_refs do
    cache_path()
    |> Cache.read_map(cache_fingerprint())
    |> Enum.flat_map(fn {_, refs} -> Enum.flat_map(refs, fn {_, png, avif, webp} -> [png, avif, webp] end) end)
  end

  def build(assets_dir, asset_terms) do
    cache = Cache.read_map(cache_path(), cache_fingerprint())

    {sources, variants, next_cache, changed} =
      Enum.reduce(asset_terms, {[], %{}, %{}, []}, fn
        {:asset, "img/" <> relative, digest}, {sources, variants, next_cache, changed} = acc ->
          cond do
            not source?(relative) ->
              acc

            Map.has_key?(variants, digest) ->
              {[{relative, digest} | sources], variants, next_cache, changed}

            true ->
              {contents, refs, changed} = image_variants(assets_dir, relative, digest, cache, changed)

              {[{relative, digest} | sources], Map.put(variants, digest, contents), Map.put(next_cache, digest, refs),
               changed}
          end

        _, acc ->
          acc
      end)

    next_cache = Map.drop(next_cache, changed)
    if next_cache != cache, do: Cache.write_term!(cache_path(), {cache_fingerprint(), next_cache})

    assets =
      sources
      |> Enum.reduce([], fn {relative, digest}, assets ->
        prepend_assets(assets, Map.fetch!(variants, digest), relative)
      end)
      |> Enum.sort()

    ensure_unique_assets!(assets)
    assets
  end

  def density_suffix(1), do: ""
  def density_suffix(density), do: "-#{density}x"

  def signature(asset_terms) when is_list(asset_terms) do
    if Enum.any?(asset_terms, fn {_, path, _} -> match?("img/" <> _, path) and source?(path) end),
      do: {:image_build, __MODULE__.module_info(:md5), cache_fingerprint()},
      else: :no_image_build
  end

  defp cache_fingerprint do
    # Vix is a build-time dependency, so nothing has loaded its application.
    _ = Application.load(:vix)

    {
      Application.spec(:vix, :vsn),
      Vix.Vips.version(),
      @encoding,
      Config.image_densities(),
      Config.image_max_pixels()
    }
  end

  defp cache_path, do: Path.join(Config.manifest_cache_dir(), @cache_file)

  defp cached_variants(cache, digest) do
    with {:ok, refs} <- Map.fetch(cache, digest) do
      {:ok, refs,
       Enum.map(refs, fn {density, png, avif, webp} ->
         {density, Cache.read_blob!(png), Cache.read_blob!(avif), Cache.read_blob!(webp)}
       end)}
    end
  rescue
    File.Error -> :error
  end

  defp ensure_pixel_limit!(image, path) do
    pixels = Image.width(image) * Image.height(image)

    if pixels > Config.image_max_pixels() do
      raise "could not load image #{path}: #{pixels} pixels exceeds configured limit of #{Config.image_max_pixels()}"
    end
  end

  defp ensure_unique_assets!([]), do: :ok
  defp ensure_unique_assets!([_]), do: :ok

  defp ensure_unique_assets!([first, second | assets]) do
    if elem(first, 0) == elem(second, 0) do
      raise ArgumentError,
            "multiple source images produce #{inspect(elem(first, 0))}; keep only one source extension for each relative image path"
    end

    ensure_unique_assets!([second | assets])
  end

  defp image_assets(path, content) do
    image = content |> Image.new_from_buffer() |> ok!("load image #{path}")
    ensure_pixel_limit!(image, path)
    {image, _} = image |> Operation.autorot() |> ok!("auto-orient image #{path}")
    densities = Config.image_densities()
    max_density = List.last(densities)

    Enum.map(densities, fn density ->
      variant = resize!(image, density / max_density, path)
      avif_options = if density == 1, do: @avif_1x_options, else: @avif_high_density_options

      {
        density,
        variant |> Image.write_to_buffer(".png", @png_options) |> ok!("write .png image") |> PNG.strip_resolution(),
        variant |> Operation.heifsave_buffer(avif_options) |> ok!("write .avif image"),
        variant |> Image.write_to_buffer(".webp", @webp_options) |> ok!("write .webp image")
      }
    end)
  end

  defp image_variants(assets_dir, relative, digest, cache, changed) do
    case cached_variants(cache, digest) do
      {:ok, refs, contents} ->
        {contents, refs, changed}

      :error ->
        path = Path.join([assets_dir, "img", relative])
        content = File.read!(path)
        contents = image_assets(path, content)

        refs =
          Enum.map(contents, fn {density, png, avif, webp} ->
            {density, Cache.put_blob!(png), Cache.put_blob!(avif), Cache.put_blob!(webp)}
          end)

        {contents, refs, if(Digest.binary(content) == digest, do: changed, else: [digest | changed])}
    end
  end

  defp ok!({:ok, value}, _), do: value
  defp ok!({:error, reason}, action), do: raise("could not #{action}: #{inspect(reason)}")

  defp prepend_assets(assets, variants, relative) do
    base = "assets/img/" <> Path.rootname(relative)

    Enum.reduce(variants, assets, fn {density, png, avif, webp}, assets ->
      base = base <> density_suffix(density)

      [
        {base <> ".webp", webp},
        {base <> ".avif", avif},
        {base <> ".png", png}
        | assets
      ]
    end)
  end

  defp resize!(image, 1.0, _), do: image

  defp resize!(image, scale, path) do
    image |> Operation.resize(scale, kernel: :VIPS_KERNEL_LANCZOS3) |> ok!("resize image #{path}")
  end

  defp source?(path) do
    path |> Path.extname() |> String.downcase() |> Kernel.in(@image_exts)
  end
end
