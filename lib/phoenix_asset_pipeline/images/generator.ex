defmodule PhoenixAssetPipeline.Images.Generator do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Files
  alias PhoenixAssetPipeline.Images.PNG
  alias PhoenixAssetPipeline.Images.References
  alias Vix.Vips.Image
  alias Vix.Vips.Operation

  def generate!(options) do
    project = Path.expand(Keyword.get(options, :project, File.cwd!()))
    source = Path.expand(Keyword.get(options, :source, "artwork"), project)
    output = Path.expand(Keyword.get(options, :output, "assets/img"), project)
    staging = Path.join(Path.dirname(output), "." <> Path.basename(output) <> ".generate")
    destinations = [output, staging, staging <> ".previous"]

    if not within?(output, Path.join(project, "assets")) do
      raise ArgumentError, "output and temporary directories must be inside assets and separate from originals"
    end

    job = %{
      destinations: destinations,
      options: options,
      output: output,
      project: project,
      source: source,
      staging: staging
    }

    Mix.Project.with_build_lock(fn -> Cache.with_lock("images #{project}", fn -> generate_locked!(job) end) end)
  end

  defp contains_identity?(nil, _), do: false

  defp contains_identity?(identity, path) do
    parent = Path.dirname(path)
    file_identity(path) == identity or (parent != path and contains_identity?(identity, parent))
  end

  defp directory!(path, project) do
    path = Path.expand(path, project)
    if not within?(path, project), do: raise(ArgumentError, "directory must be inside the project: #{path}")

    path
    |> Path.relative_to(project)
    |> Path.split()
    |> Enum.reduce(project, fn segment, parent ->
      child = Path.join(parent, segment)

      case File.lstat(child) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} -> :ok
        _ -> raise ArgumentError, "expected a directory without symlinks: #{child}"
      end

      child
    end)
  end

  defp entries!(references, resolver, source) do
    Enum.reduce(references, %{}, fn {src, dimensions, variants?}, entries ->
      mappings = resolver.(src, variants?)
      if not (is_list(mappings) and mappings != []), do: raise(ArgumentError, "no originals for #{inspect(src)}")

      Enum.reduce(mappings, entries, &put_entry!(&1, &2, source, dimensions))
    end)
  end

  defp file_identity(path) do
    case File.stat(path) do
      {:ok, %{inode: inode, major_device: major, minor_device: minor}} when inode != 0 -> {major, minor, inode}
      _ -> nil
    end
  end

  defp generate_entries!(entries, output, staging) do
    File.mkdir_p!(Path.dirname(output))
    File.mkdir!(staging)

    try do
      Enum.each(Enum.sort(entries), &render!(&1, staging))

      generated =
        staging
        |> Files.regular_files()
        |> Enum.map(&Path.relative_to(&1, staging))

      if generated != Enum.sort(Map.keys(entries)) do
        raise ArgumentError,
              "generated image paths differ from declared paths; use consistent spelling for every directory and filename"
      end

      replace!(staging, output)
      map_size(entries)
    after
      File.rm_rf!(staging)
    end
  end

  defp generate_locked!(%{
         destinations: destinations,
         options: options,
         output: output,
         project: project,
         source: source,
         staging: staging
       }) do
    separate_directories!(source, destinations, project)
    paths = template_paths!(options, project, destinations)

    paths =
      if recover!(staging, output) do
        separate_directories!(source, destinations, project)
        template_paths!(options, project, destinations)
      else
        paths
      end

    Enum.each(paths, &Files.regular_file!(&1, project))
    references = References.scan!(paths)
    if references == [], do: raise(ArgumentError, "no picture references found; output was not replaced")
    resolver = Keyword.get(options, :resolve, fn src, false -> [{src <> ".png", src <> ".png"}] end)
    entries = entries!(references, resolver, source)
    generate_entries!(entries, output, staging)
  end

  defp overlap?(left, right) do
    left == right or within?(left, right) or within?(right, left) or
      contains_identity?(file_identity(left), right) or contains_identity?(file_identity(right), left)
  end

  defp put_entry!({target, original}, entries, source, dimensions) do
    relative_png!(target)
    relative_png!(original)
    original = Path.join(source, original)
    Files.regular_file!(original, source)

    Map.update(entries, target, {original, [dimensions]}, fn
      {^original, sizes} -> {original, Enum.uniq([dimensions | sizes])}
      _ -> raise ArgumentError, "different originals map to #{target}"
    end)
  end

  defp recover!(staging, output) do
    backup = staging <> ".previous"
    Enum.each([staging, backup, output], &directory!(&1, Path.dirname(output)))

    restored? = File.dir?(backup) and not File.exists?(output)

    cond do
      restored? -> File.rename!(backup, output)
      File.dir?(backup) -> File.rm_rf!(backup)
      true -> :ok
    end

    File.rm_rf!(staging)
    restored?
  end

  defp relative_png!(path) do
    if not (is_binary(path) and Path.type(path) == :relative and Path.extname(path) == ".png" and
              Enum.all?(String.split(path, "/"), &(&1 not in [".", "..", ""])) and
              not String.contains?(path, ["\\", <<0>>])) do
      raise ArgumentError, "expected a relative PNG path: #{inspect(path)}"
    end
  end

  defp render!({target, {original, sizes}}, staging) do
    {:ok, image} = Image.new_from_file(original)
    {:ok, {image, _}} = Operation.autorot(image)
    width = Image.width(image)
    height = Image.height(image)

    scale =
      sizes
      |> Enum.map(fn
        {nil, h} -> 2 * h / height
        {w, h} -> min(2 * w / width, 2 * h / height)
      end)
      |> Enum.max()

    max_pixels = Config.image_max_pixels()

    if width * height > max_pixels or ceil(width * scale) * ceil(height * scale) > max_pixels do
      raise ArgumentError, "image exceeds the pixel limit: #{original}"
    end

    {:ok, image} = Operation.resize(image, scale, kernel: :VIPS_KERNEL_LANCZOS3)
    {:ok, content} = Image.write_to_buffer(image, ".png", compression: 9, keep: [:VIPS_FOREIGN_KEEP_NONE])
    destination = Path.join(staging, target)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, PNG.strip_resolution(content), [:exclusive])
  end

  defp replace!(staging, output) do
    backup = staging <> ".previous"
    previous? = File.dir?(output)
    if previous?, do: File.rename!(output, backup)

    case File.rename(staging, output) do
      :ok ->
        if previous?, do: File.rm_rf!(backup)

      {:error, reason} ->
        if previous?, do: File.rename!(backup, output)
        raise File.Error, reason: reason, action: "replace generated images", path: output
    end
  end

  defp separate_directories!(source, destinations, project) do
    Enum.each([source | destinations], &directory!(&1, project))

    if Enum.any?(destinations, &overlap?(source, &1)) do
      raise ArgumentError, "output and temporary directories must be separate from originals"
    end
  end

  defp template_paths!(options, project, destinations) do
    paths =
      options
      |> Keyword.get(:templates, ["lib/**/*.{ex,heex}"])
      |> Enum.flat_map(&Path.wildcard(Path.expand(&1, project)))
      |> Enum.uniq()
      |> Enum.sort()

    if Enum.any?(paths, fn path -> Enum.any?(destinations, &overlap?(path, &1)) end) do
      raise ArgumentError, "templates must be separate from output and temporary directories"
    end

    paths
  end

  defp within?(path, root), do: String.starts_with?(path, root <> "/")
end
