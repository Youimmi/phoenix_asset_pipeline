defmodule PhoenixAssetPipeline.Assets.Images do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @cache_file "image_assets.term"
  @image_exts ~w(.avif .png .webp)
  @png_options [compression: 9, strip: true]
  @avif_options [Q: 82, compression: :VIPS_FOREIGN_HEIF_COMPRESSION_AV1, effort: 9, strip: true]
  @webp_options [Q: 88, strip: true]

  @doc false
  def signature(asset_terms) when is_list(asset_terms) do
    if Enum.any?(asset_terms, &image_source_term?/1),
      do: {:image_build, cache_fingerprint()},
      else: :no_image_build
  end

  def build(assets_dir, asset_terms) do
    cache = read_cache()

    {assets, next_cache, changed?} =
      Enum.reduce(asset_terms, {[], %{}, false}, fn
        {:asset, "img/" <> relative, digest, content}, state ->
          if source?(relative),
            do: image_assets(relative, digest, content, state, cache, assets_dir),
            else: state

        _, state ->
          state
      end)

    changed? = changed? or map_size(cache) != map_size(next_cache)

    if changed?, do: save_cache(next_cache)

    assets = Enum.sort(assets)
    ensure_unique_assets!(assets)
    assets
  end

  defp cache_path do
    Path.join(Config.manifest_cache_dir(), @cache_file)
  end

  defp image_assets(relative, digest, content, {assets, next_cache, changed?}, cache, assets_dir) do
    path = Path.join([assets_dir, "img", relative])
    {variants, next_cache, changed?} = cached_variants(digest, content, path, next_cache, cache, changed?)

    {prepend_assets(assets, variants, relative), next_cache, changed?}
  end

  defp image_variants(path, content) do
    image = load_image!(path, content)

    {
      write_image!(image, ".png", @png_options),
      write_avif!(image, @avif_options),
      write_image!(image, ".webp", @webp_options)
    }
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

  defp read_cache do
    Cache.read_term(cache_path(), %{}, fn
      {fingerprint, cache} when is_map(cache) ->
        if fingerprint == cache_fingerprint(), do: {:ok, cache}, else: :error

      _ ->
        :error
    end)
  end

  defp save_cache(cache) do
    Cache.write_term!(cache_path(), {cache_fingerprint(), cache})
  end

  defp source?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in(@image_exts)
  end

  defp cache_fingerprint do
    {
      Application.spec(:vix, :vsn),
      Vix.Vips.version(),
      @png_options,
      @avif_options,
      @webp_options
    }
  end

  defp cached_variants(digest, content, path, next_cache, cache, changed?) do
    case fetch_variants(next_cache, digest) do
      {:ok, variants} ->
        {variants, next_cache, changed?}

      :error ->
        case fetch_variants(cache, digest) do
          {:ok, variants} -> {variants, Map.put(next_cache, digest, variants), changed?}
          :error -> put_variants(digest, image_variants(path, content), next_cache)
        end
    end
  end

  defp ensure_unique_assets!([]), do: :ok
  defp ensure_unique_assets!([_]), do: :ok

  defp ensure_unique_assets!([{path, _}, {path, _} | _]) do
    raise ArgumentError,
          "multiple source images produce #{inspect(path)}; keep only one source extension for each relative image path"
  end

  defp ensure_unique_assets!([_ | assets]), do: ensure_unique_assets!(assets)

  defp fetch_variants(cache, digest) do
    case Map.fetch(cache, digest) do
      {:ok, {png, avif, webp} = variants}
      when is_binary(png) and is_binary(avif) and is_binary(webp) ->
        {:ok, variants}

      _ ->
        :error
    end
  end

  defp prepend_assets(assets, {png, avif, webp}, relative) do
    base = "assets/img/" <> Path.rootname(relative)

    [
      {base <> ".webp", webp},
      {base <> ".avif", avif},
      {base <> ".png", png}
      | assets
    ]
  end

  defp put_variants(digest, variants, next_cache) do
    {variants, Map.put(next_cache, digest, variants), true}
  end

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
