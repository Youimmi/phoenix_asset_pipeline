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
  # Bump the version when the variants change for a reason the options do not show.
  @encoding {1, @png_options, @avif_1x_options, @avif_high_density_options, @webp_options}

  def build(assets_dir, asset_terms) do
    cache = Cache.read_map(cache_path(), cache_fingerprint())

    {sources, missing, next_cache} =
      Enum.reduce(asset_terms, {[], %{}, %{}}, fn
        {:asset, "img/" <> relative, digest}, {sources, missing, next_cache} ->
          case source?(relative) and Map.fetch(cache, digest) do
            {:ok, variants} ->
              {[{relative, digest} | sources], missing, Map.put(next_cache, digest, variants)}

            :error ->
              path = Path.join([assets_dir, "img", relative])

              {[{relative, digest} | sources], Map.put_new(missing, digest, path), next_cache}

            false ->
              {sources, missing, next_cache}
          end

        _, state ->
          state
      end)

    # A file rewritten after the snapshot is rebuilt by the caller's consistency pass,
    # so its variants serve this build only and stay out of the cache.
    {next_cache, changed} =
      Enum.reduce(missing, {next_cache, []}, fn {digest, path}, {next_cache, changed} ->
        content = File.read!(path)
        changed = if Digest.binary(content) == digest, do: changed, else: [digest | changed]

        {Map.put(next_cache, digest, image_assets(path, content)), changed}
      end)

    if map_size(missing) != 0 or map_size(cache) != map_size(next_cache) do
      Cache.write_term!(cache_path(), {cache_fingerprint(), Map.drop(next_cache, changed)})
    end

    assets =
      sources
      |> Enum.reduce([], fn {relative, digest}, assets ->
        prepend_assets(assets, Map.fetch!(next_cache, digest), relative)
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
