defmodule PhoenixAssetPipeline.Assets.Images do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  @cache_file "image_assets.term"
  @cache_version 1
  @image_exts ~w(.avif .png .webp)

  def build(assets_dir) do
    cache = read_cache()

    {assets, {next_cache, changed?}} =
      assets_dir |> image_roots() |> Enum.flat_map_reduce({%{}, false}, &image_assets(&1, &2, cache))

    changed? = changed? or map_size(cache) != map_size(next_cache)

    if changed?, do: save_cache(next_cache)

    Enum.sort(assets)
  end

  defp cache_path do
    Path.join(Config.manifest_cache_dir(), @cache_file)
  end

  defp file_digest(content) do
    content
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  defp forward_path(path), do: String.replace(path, "\\", "/")

  defp image_assets({source_dir, output_prefix}, next_cache, cache) do
    source_dir
    |> regular_files()
    |> Enum.filter(&source?/1)
    |> Enum.flat_map_reduce(next_cache, &image_assets(&1, &2, cache, source_dir, output_prefix))
  end

  defp image_assets(path, {next_cache, changed?}, cache, source_dir, output_prefix) do
    relative = path |> Path.relative_to(source_dir) |> forward_path()
    content = File.read!(path)
    key = {@cache_version, output_prefix, relative, file_digest(content)}

    case Map.fetch(cache, key) do
      {:ok, assets} ->
        {assets, {Map.put(next_cache, key, assets), changed?}}

      :error ->
        assets = image_variants(path, content, relative, output_prefix)
        {assets, {Map.put(next_cache, key, assets), true}}
    end
  end

  defp image_roots(assets_dir) do
    Enum.filter(
      [
        {Path.join(assets_dir, "img"), ""}
      ],
      fn {dir, _} -> File.dir?(dir) end
    )
  end

  defp image_variants(path, content, relative, output_prefix) do
    image = load_image!(path, content)
    base = Path.rootname(relative)

    [
      {"assets/img/" <> output_prefix <> base <> ".png", write_image!(image, ".png", compression: 9, strip: true)},
      {"assets/img/" <> output_prefix <> base <> ".avif", write_avif!(image, Q: 82, effort: 9, strip: true)},
      {"assets/img/" <> output_prefix <> base <> ".webp", write_image!(image, ".webp", Q: 88, strip: true)}
    ]
  end

  defp load_image!(path, content) do
    case Image.new_from_buffer(content) do
      {:ok, image} -> image
      {:error, reason} -> raise "could not load image #{path}: #{inspect(reason)}"
    end
  end

  defp read_cache do
    Cache.read_term(cache_path(), %{}, fn
      %{version: @cache_version, assets: cache} when is_map(cache) -> {:ok, cache}
      _ -> :error
    end)
  end

  defp regular_entry(_, "." <> _), do: []

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

  defp save_cache(cache) do
    Cache.write_term!(cache_path(), %{assets: cache, version: @cache_version})
  end

  defp source?(path) do
    path
    |> Path.extname()
    |> String.downcase()
    |> Kernel.in(@image_exts)
  end

  defp write_avif!(image, opts) do
    opts = Keyword.put(opts, :compression, :VIPS_FOREIGN_HEIF_COMPRESSION_AV1)

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
