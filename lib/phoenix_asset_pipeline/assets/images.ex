defmodule PhoenixAssetPipeline.Assets.Images do
  @moduledoc false

  alias PhoenixAssetPipeline.Bun, as: BunRuntime
  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @cache_file "image_assets.term"
  @image_exts ~w(.avif .jpeg .jpg .png .webp)
  @png_options [compression: 9, strip: true]
  @placeholder_png_options [Q: 80, compression: 9, dither: 0, palette: true, strip: true]
  @avif_options [compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1, effort: 9, strip: true]
  @avif_1x_options [Q: 82] ++ @avif_options
  @avif_high_density_options [Q: 55] ++ @avif_options
  @webp_options [Q: 88, strip: true]
  @placeholder_script ~S"""
  const maxPixels = Number(process.env.PHOENIX_ASSET_PIPELINE_IMAGE_MAX_PIXELS);
  const paths = process.env.PHOENIX_ASSET_PIPELINE_IMAGE_PATHS.split("\n");
  const placeholders = await Promise.all(paths.map(path =>
    new Bun.Image(path, { autoOrient: true, maxPixels }).placeholder()
  ));

  process.stdout.write(placeholders.join("\0"));
  """

  @doc false
  def signature(asset_terms) when is_list(asset_terms) do
    if Enum.any?(asset_terms, &image_source_term?/1),
      do: {:image_build, cache_fingerprint()},
      else: :no_image_build
  end

  def build(assets_dir, asset_terms) do
    cache = read_cache()

    {sources, missing, next_cache} =
      Enum.reduce(asset_terms, {[], %{}, %{}}, fn
        {:asset, "img/" <> relative, digest, content}, {sources, missing, next_cache} ->
          case source?(relative) and Map.fetch(cache, digest) do
            {:ok, variants} ->
              {[{relative, digest} | sources], missing, Map.put(next_cache, digest, variants)}

            :error ->
              path = Path.join([assets_dir, "img", relative])

              {[{relative, digest} | sources], Map.put_new(missing, digest, {digest, content, path}), next_cache}

            false ->
              {sources, missing, next_cache}
          end

        _, state ->
          state
      end)

    missing = Map.values(missing)
    next_cache = put_missing_variants(missing, placeholders!(missing), next_cache)

    if missing != [] or map_size(cache) != map_size(next_cache), do: save_cache(next_cache)

    assets =
      sources
      |> Enum.reduce([], fn {relative, digest}, assets ->
        prepend_assets(assets, Map.fetch!(next_cache, digest), relative)
      end)
      |> Enum.sort()

    ensure_unique_assets!(assets)
    assets
  end

  defp cache_path, do: Path.join(Config.manifest_cache_dir(), @cache_file)

  defp image_assets(path, content, placeholder) do
    image = load_image!(path, content)
    ensure_pixel_limit!(image, path)
    image = auto_orient!(image, path)
    densities = Config.image_densities()
    max_density = List.last(densities)

    variants =
      Enum.map(densities, fn density ->
        variant = resize!(image, density / max_density, path)

        {density, write_image!(variant, ".png", @png_options),
         write_avif!(
           variant,
           if(density == 1, do: @avif_1x_options, else: @avif_high_density_options)
         ), write_image!(variant, ".webp", @webp_options)}
      end)

    {variants, mask_placeholder(image, placeholder, path, max_density)}
  end

  defp image_source_term?({:asset, "img/" <> relative, _}), do: source?(relative)
  defp image_source_term?({:asset, "img/" <> relative, _, _}), do: source?(relative)
  defp image_source_term?(_), do: false

  defp load_image!(path, content) do
    case Image.new_from_buffer(content) do
      {:ok, image} -> image
      {:error, reason} -> raise "could not load image #{path}: #{inspect(reason)}"
    end
  end

  defp auto_orient!(image, path) do
    case Operation.autorot(image) do
      {:ok, {image, _orientation}} -> image
      {:error, reason} -> raise "could not auto-orient image #{path}: #{inspect(reason)}"
    end
  end

  defp ensure_pixel_limit!(image, path) do
    pixels = Image.width(image) * Image.height(image)

    if pixels > Config.image_max_pixels() do
      raise "could not load image #{path}: #{pixels} pixels exceeds configured limit of #{Config.image_max_pixels()}"
    end
  end

  defp resize!(image, 1.0, _path), do: image

  defp resize!(image, scale, path) do
    case Operation.resize(image, scale, kernel: :VIPS_KERNEL_LANCZOS3) do
      {:ok, image} -> image
      {:error, reason} -> raise "could not resize image #{path}: #{inspect(reason)}"
    end
  end

  defp placeholders!([]), do: []

  defp placeholders!(missing) do
    env = [
      {"PHOENIX_ASSET_PIPELINE_IMAGE_MAX_PIXELS", Integer.to_string(Config.image_max_pixels())},
      {"PHOENIX_ASSET_PIPELINE_IMAGE_PATHS", Enum.map_join(missing, "\n", &elem(&1, 2))}
    ]

    case BunRuntime.run(["--eval", @placeholder_script], env: env, stderr_to_stdout: true) do
      {output, 0} -> :binary.split(output, <<0>>, [:global])
      {output, status} -> raise "could not generate image placeholders: Bun exited with #{status}\n#{output}"
    end
  end

  defp mask_placeholder(image, placeholder, path, max_density) do
    <<"data:image/png;base64,", content::binary>> = placeholder
    placeholder_image = load_image!(path, Base.decode64!(content))
    source_width = Image.width(image)
    source_height = Image.height(image)
    size = round(max(Image.width(placeholder_image), Image.height(placeholder_image)) * 1.5)
    scale = size / max(source_width, source_height)
    width = max(round(source_width * scale), 1)
    height = max(round(source_height * scale), 1)

    alpha =
      if Image.has_alpha?(image) do
        image
        |> Operation.extract_band!(Image.bands(image) - 1)
        |> Operation.relational_const!(:VIPS_OPERATION_RELATIONAL_MORE, [128])
        |> Operation.resize!(width / source_width,
          vscale: height / source_height,
          kernel: :VIPS_KERNEL_LINEAR
        )
        |> Operation.relational_const!(:VIPS_OPERATION_RELATIONAL_MORE, [240])
        |> Operation.rank!(3, 3, 0)
      else
        width
        |> Operation.black!(height)
        |> Operation.linear!([0], [255], uchar: true)
      end

    placeholder_image =
      [
        Operation.linear!(alpha, [0], [211], uchar: true),
        Operation.linear!(alpha, [0.8], [0], uchar: true)
      ]
      |> Operation.bandjoin!()
      |> Operation.copy!(interpretation: :VIPS_INTERPRETATION_B_W)
      |> Operation.resize!(round(source_width / max_density) / width,
        vscale: round(source_height / max_density) / height,
        kernel: :VIPS_KERNEL_NEAREST
      )

    write_image!(placeholder_image, ".png", @placeholder_png_options)
  end

  defp read_cache do
    Cache.read_term(cache_path(), %{}, fn
      {fingerprint, cache} when is_map(cache) ->
        if fingerprint == cache_fingerprint(), do: {:ok, cache}, else: :error

      _ ->
        :error
    end)
  end

  defp save_cache(cache), do: Cache.write_term!(cache_path(), {cache_fingerprint(), cache})

  defp source?(path) do
    path |> Path.extname() |> String.downcase() |> Kernel.in(@image_exts)
  end

  defp cache_fingerprint do
    {
      Application.spec(:vix, :vsn),
      Vix.Vips.version(),
      __MODULE__.module_info(:md5),
      BunRuntime.version(),
      Config.image_densities(),
      Config.image_max_pixels()
    }
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

  defp prepend_assets(assets, {variants, placeholder}, relative) do
    base = "assets/img/" <> Path.rootname(relative)

    Enum.reduce(variants, assets, fn {density, png, avif, webp}, assets ->
      base = base <> density_suffix(density)

      [
        {base <> ".webp", webp},
        {base <> ".avif", avif},
        image_asset(base <> ".png", png, density, placeholder)
        | assets
      ]
    end)
  end

  defp image_asset(path, content, 1, placeholder), do: {path, content, {:image_placeholder, placeholder}}
  defp image_asset(path, content, _, _), do: {path, content}

  defp density_suffix(1), do: ""
  defp density_suffix(density), do: "-#{density}x"

  defp put_missing_variants([{digest, content, path} | missing], ["data:image/" <> _ = placeholder | placeholders], cache) do
    put_missing_variants(
      missing,
      placeholders,
      Map.put(cache, digest, image_assets(path, content, placeholder))
    )
  end

  defp put_missing_variants([], [], cache), do: cache

  defp write_avif!(image, opts) do
    case Operation.heifsave_buffer(image, opts) do
      {:ok, content} -> content
      {:error, reason} -> raise "could not write .avif image: #{inspect(reason)}"
    end
  end

  defp write_image!(image, suffix, opts) do
    case Image.write_to_buffer(image, suffix, opts) do
      {:ok, content} -> content
      {:error, reason} -> raise "could not write #{suffix} image: #{inspect(reason)}"
    end
  end
end
