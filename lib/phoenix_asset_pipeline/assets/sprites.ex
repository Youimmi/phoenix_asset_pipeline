defmodule PhoenixAssetPipeline.Assets.Sprites do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files
  alias PhoenixAssetPipeline.HTML.TemplateScanner

  @scan_cache_file "sprite_scan.term"
  @source_digest_cache_file "sprite_source_digests.term"
  @sprite_group_type :svg_sprite_group
  @sprite_source_type :svg_sprite_source
  @stack_sprites ["app.svg"]

  def signature(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, _, name, _, digest} ->
        {sprite, name, digest}
    end)
  end

  def snapshot(assets_dir, config \\ Config.svg_sprites()) when is_list(config) do
    assets_dir
    |> Path.expand()
    |> configured_entries(config)
  end

  def source_dirs(entries) do
    configured =
      for %{src: src} <- Config.svg_sprites(), path = Path.expand(src, Config.project_dir()) do
        if File.dir?(path), do: path, else: Path.dirname(path)
      end

    entries
    |> Enum.flat_map(fn
      {@sprite_group_type, _, _, _, nil, _} -> []
      {@sprite_group_type, _, _, _, metadata_path, _} -> [Path.dirname(metadata_path)]
      {@sprite_source_type, _, _, _, root, _} -> [root]
    end)
    |> Kernel.++(configured)
    |> Enum.uniq()
  end

  def source_terms(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {@sprite_group_type, sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, path, name, root, digest} ->
        relative = Path.relative_to(path, root)
        {@sprite_source_type, sprite, name, relative, digest}
    end)
  end

  def stack_sprites, do: @stack_sprites

  defp assign_source_name(id, assigned, candidates, local_source) do
    case best_source_candidate(id, candidates) do
      nil ->
        with false <- File.exists?(Path.join(local_source, ensure_svg_ext(id))),
             path when is_binary(path) <- configured_source_path(id, candidates) do
          raise ArgumentError, "missing SVG sprite source for ##{id}: #{path}"
        else
          _ -> source_path(local_source, id)
        end

        assigned

      {_, index, name, _} ->
        Map.update(assigned, index, [name], &[name | &1])
    end
  end

  defp assigned_source_names(assets_dir, used_ids_by_sprite, specs) do
    sources_by_sprite =
      specs
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{sprite, _, _, _, _, _, _, _, _, _} = spec, index}, sources ->
        Map.update(sources, sprite, [{index, spec}], &[{index, spec} | &1])
      end)

    Enum.reduce(used_ids_by_sprite, %{}, fn {sprite, ids}, assigned ->
      candidates = Map.fetch!(sources_by_sprite, sprite)
      local_source = Path.join([assets_dir, "svg", "sprites", Path.rootname(sprite)])
      Enum.reduce(ids, assigned, &assign_source_name(&1, &2, candidates, local_source))
    end)
  end

  defp best_source_candidate(id, candidates) do
    candidates
    |> Enum.reduce({nil, nil}, fn {index, spec}, acc ->
      case source_candidate(id, index, spec) do
        nil -> acc
        candidate -> select_source_candidate(candidate, acc)
      end
    end)
    |> case do
      {best, nil} ->
        best

      {{_, _, _, source}, other_source} ->
        raise ArgumentError,
              "ambiguous SVG sprite source for ##{id}: #{inspect(source)} and #{inspect(other_source)}"
    end
  end

  defp collect_source_file({path, digest}, {files, ids_by_sprite} = acc, cache) do
    case Path.extname(path) do
      extname when extname in [".ex", ".heex"] ->
        references =
          case cache do
            %{^path => {^digest, references}} when is_list(references) -> references
            _ -> source_references(extname, path, File.read!(path))
          end

        {Map.put(files, path, {digest, references}), Enum.reduce(references, ids_by_sprite, &put_reference/2)}

      _ ->
        acc
    end
  end

  defp collect_sprite_href(value, ids) do
    case :binary.split(value, "#", [:global]) do
      [sprite, id] when sprite != "" and id != "" -> put_sprite_id(ids, sprite, id)
      _ -> ids
    end
  end

  defp collect_tag(type, tag, attrs, ids) do
    {name, sprite, ids} = Enum.reduce(attrs, {nil, nil, ids}, &put_attribute/2)

    case component(type, tag) do
      "icon" when is_binary(name) -> put_sprite_id(ids, sprite || "icons.svg", name)
      _ -> ids
    end
  end

  defp component(:local_component, tag), do: tag
  defp component(:remote_component, tag), do: tag |> :binary.split(".", [:global]) |> List.last()
  defp component(_, _), do: nil

  defp configured_entries(assets_dir, config) do
    specs = Enum.map(config, &source_config/1)
    used_ids_by_sprite = used_sprite_ids(specs)
    source_names = assigned_source_names(assets_dir, used_ids_by_sprite, specs)
    groups = configured_sprite_groups(specs)

    sources =
      specs
      |> Enum.with_index()
      |> Enum.flat_map(fn {spec, index} -> configured_source_entries(spec, Map.get(source_names, index, [])) end)
      |> Enum.reduce(%{}, fn {@sprite_source_type, sprite, _, name, _, _} = source, sources ->
        key = {sprite, name}

        case sources do
          %{^key => existing} ->
            raise ArgumentError,
                  "duplicate SVG sprite entry #{inspect(sprite)}##{name}: " <>
                    "#{inspect(existing)} and #{inspect(source)}"

          _ ->
            Map.put(sources, key, source)
        end
      end)
      |> Map.values()
      |> Enum.sort_by(fn {@sprite_source_type, sprite, _, name, _, _} -> {sprite, name} end)

    groups ++ sources
  end

  defp configured_source_entries({sprite, _, source, source_type, root, prefix, suffix, _, _, opts}, source_names) do
    for {path, name, digest} <- configured_source_files(opts, source, source_type, source_names) do
      {@sprite_source_type, sprite, path, sprite_entry_name(prefix, name, suffix), root, digest}
    end
  end

  defp configured_source_file(source, source_type, name) do
    path = if source_type == :directory, do: source_path(source, name), else: source
    {path, name, file_digest!(path)}
  end

  defp configured_source_files(opts, source, source_type, source_names) do
    case {Map.get(opts, :names), Map.get(opts, :files)} do
      {nil, nil} ->
        Enum.map(source_names, &configured_source_file(source, source_type, &1))

      {names, nil} when is_list(names) and source_type == :directory ->
        Enum.map(names, fn
          name when is_binary(name) and name != "" ->
            configured_source_file(source, source_type, name)

          name ->
            raise ArgumentError, "invalid SVG sprite name #{inspect(name)}; expected a non-empty string"
        end)

      {nil, files} when is_list(files) and source_type == :directory ->
        Enum.map(files, fn
          file when is_binary(file) and file != "" ->
            path = source_path(source, file)
            {path, Path.basename(file), file_digest!(path)}

          file ->
            raise ArgumentError, "invalid SVG sprite file #{inspect(file)}; expected a non-empty string"
        end)

      _ ->
        raise ArgumentError,
              ":names and :files are mutually exclusive lists valid only for SVG sprite source directories"
    end
  end

  defp configured_source_path(id, candidates) do
    candidates
    |> Enum.flat_map(fn
      {_, {_, _, source, :directory, _, prefix, suffix, _, _, opts}}
      when not is_map_key(opts, :names) and not is_map_key(opts, :files) ->
        case source_name(id, prefix, suffix) do
          nil -> []
          name -> [{byte_size(prefix) + byte_size(suffix), Path.join(source, ensure_svg_ext(name))}]
        end

      _ ->
        []
    end)
    |> Enum.max_by(&elem(&1, 0), fn -> {0, nil} end)
    |> elem(1)
  end

  defp configured_sprite_groups(specs) do
    specs
    |> Enum.reduce(%{}, fn {sprite, mode, _, _, _, _, _, namespace_ids?, metadata, _}, groups ->
      options = {mode, namespace_ids?, metadata}
      Map.update(groups, sprite, options, &merge_sprite_options!(sprite, &1, options))
    end)
    |> Enum.map(fn {sprite, {mode, namespace_ids?, metadata}} ->
      {metadata_path, metadata_digest} = metadata || {nil, nil}
      {@sprite_group_type, sprite, mode, namespace_ids? != false, metadata_path, metadata_digest}
    end)
    |> Enum.sort_by(fn {@sprite_group_type, sprite, _, _, _, _} -> sprite end)
  end

  defp default_mode(sprite) when sprite in @stack_sprites, do: :stack
  defp default_mode(_), do: :symbol

  defp ensure_svg_ext(path) do
    if Path.extname(path) == ".svg", do: path, else: path <> ".svg"
  end

  defp explicit_source_candidate(id, index, source, prefix, suffix, [entry | entries], basename?)
       when is_binary(entry) and entry != "" do
    name = if basename?, do: Path.basename(entry), else: entry

    if id == Path.rootname(sprite_entry_name(prefix, name, suffix)),
      do: {byte_size(id) + 1, index, name, source},
      else: explicit_source_candidate(id, index, source, prefix, suffix, entries, basename?)
  end

  defp explicit_source_candidate(id, index, source, prefix, suffix, [_ | entries], basename?) do
    explicit_source_candidate(id, index, source, prefix, suffix, entries, basename?)
  end

  defp explicit_source_candidate(_, _, _, _, _, [], _), do: nil

  defp file_digest!(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> path |> File.read!() |> Digest.binary()
      {:ok, %{type: type}} -> raise ArgumentError, "invalid SVG sprite source type #{inspect(type)}: #{path}"
      {:error, reason} -> raise File.Error, reason: reason, action: "stat SVG sprite source", path: path
    end
  end

  defp merge_sprite_option!(_, _, nil, value), do: value
  defp merge_sprite_option!(_, _, value, nil), do: value
  defp merge_sprite_option!(_, _, value, value), do: value

  defp merge_sprite_option!(sprite, option, existing, next) do
    raise ArgumentError,
          "conflicting SVG sprite #{option} values for #{inspect(sprite)}: " <>
            "#{inspect(existing)} and #{inspect(next)}"
  end

  defp merge_sprite_options!(sprite, {mode, namespace_ids?, metadata}, {mode, next_namespace_ids?, next_metadata}) do
    {mode, merge_sprite_option!(sprite, :namespace_ids, namespace_ids?, next_namespace_ids?),
     merge_sprite_option!(sprite, :metadata_file, metadata, next_metadata)}
  end

  defp merge_sprite_options!(sprite, existing, next) do
    raise ArgumentError,
          "conflicting SVG sprite options for #{inspect(sprite)}: #{inspect(existing)} and #{inspect(next)}"
  end

  defp metadata_source(opts) do
    case Map.fetch(opts, :metadata_file) do
      :error ->
        nil

      {:ok, path} when is_binary(path) and path != "" ->
        path = Path.expand(path, Config.project_dir())
        {path, file_digest!(path)}

      _ ->
        raise ArgumentError, "invalid :metadata_file in :svg_sprites entry; expected a non-empty path"
    end
  end

  defp optional_boolean!(opts, key) do
    case Map.fetch(opts, key) do
      :error -> nil
      {:ok, value} when is_boolean(value) -> value
      _ -> raise ArgumentError, "invalid #{inspect(key)} in :svg_sprites entry; expected a boolean"
    end
  end

  defp put_attribute({key, value}, {name, sprite, ids}) do
    value =
      case value do
        {:expr, ast} -> ast
        {:string, value} -> value
        _ -> nil
      end

    case {key, value} do
      {"name", value} when is_binary(value) -> {value, sprite, ids}
      {"sprite", value} when is_binary(value) -> {name, value, ids}
      {"icon", value} when is_binary(value) -> {name, sprite, put_icons_id(value, ids)}
      _ -> {name, sprite, ids}
    end
  end

  defp put_icons_id(id, ids) when id in [nil, ""], do: ids
  defp put_icons_id(id, ids), do: put_sprite_id(ids, "icons.svg", id)

  defp put_reference({sprite, id}, ids_by_sprite) do
    case ids_by_sprite do
      %{^sprite => ids} -> Map.put(ids_by_sprite, sprite, MapSet.put(ids, id))
      _ -> ids_by_sprite
    end
  end

  defp put_sprite_id(ids, sprite, id), do: MapSet.put(ids, {sprite, :binary.copy(id)})

  defp scan_fingerprint do
    {
      __MODULE__.module_info(:md5),
      TemplateScanner.module_info(:md5),
      Application.spec(:phoenix_live_view, :vsn),
      System.version()
    }
  end

  defp scanner, do: %{tag: &collect_tag/4, visit: &visit/2}

  defp select_source_candidate(candidate, {nil, _}), do: {candidate, nil}

  defp select_source_candidate({score, _, _, _} = candidate, {{best_score, _, _, _}, _}) when score > best_score do
    {candidate, nil}
  end

  defp select_source_candidate({score, _, _, _}, {{best_score, _, _, _}, _} = acc) when score < best_score, do: acc
  defp select_source_candidate({_, _, _, source}, {best, _}), do: {best, source}

  defp source_candidate(id, index, {_, _, source, :directory, _, prefix, suffix, _, _, opts}) do
    case {Map.get(opts, :names), Map.get(opts, :files)} do
      {nil, nil} ->
        with name when is_binary(name) <- source_name(id, prefix, suffix),
             true <- File.exists?(Path.join(source, ensure_svg_ext(name))) do
          {byte_size(prefix) + byte_size(suffix), index, name, source}
        else
          _ -> nil
        end

      {names, nil} when is_list(names) ->
        explicit_source_candidate(id, index, source, prefix, suffix, names, false)

      {nil, files} when is_list(files) ->
        explicit_source_candidate(id, index, source, prefix, suffix, files, true)

      _ ->
        nil
    end
  end

  defp source_candidate(id, index, {_, _, source, _, _, prefix, suffix, _, _, _}) do
    name = Path.basename(source)

    if id == Path.rootname(sprite_entry_name(prefix, name, suffix)),
      do: {byte_size(id) + 1, index, name, source}
  end

  defp source_config(%{file: file, src: src} = opts)
       when is_binary(file) and file != "" and is_binary(src) and src != "" do
    sprite = ensure_svg_ext(file)
    mode = opts |> Map.get(:mode, default_mode(sprite)) |> sprite_mode!()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")
    namespace_ids? = optional_boolean!(opts, :namespace_ids)
    metadata = metadata_source(opts)
    source = Path.expand(src, Config.project_dir())
    source_type = source_type!(source)
    root = if source_type == :directory, do: source, else: Path.dirname(source)

    if not (is_binary(prefix) and is_binary(suffix)) do
      raise ArgumentError, ":prefix and :suffix in :svg_sprites entries must be strings"
    end

    {sprite, mode, source, source_type, root, prefix, suffix, namespace_ids?, metadata, opts}
  end

  defp source_config(opts) do
    raise ArgumentError,
          "invalid :svg_sprites entry #{inspect(opts)}; expected a map with non-empty :file and :src strings"
  end

  defp source_name(id, prefix, suffix) do
    prefix_size = byte_size(prefix)
    suffix_size = byte_size(suffix)

    if String.starts_with?(id, prefix) and (suffix == "" or String.ends_with?(id, suffix)) do
      size = byte_size(id) - prefix_size - suffix_size
      if size > 0, do: binary_part(id, prefix_size, size)
    end
  end

  defp source_path(source, name) do
    path = ensure_svg_ext(name)

    if Path.type(path) != :relative do
      raise ArgumentError, "SVG sprite name resolves outside its source directory: #{inspect(name)}"
    end

    source |> Path.join(path) |> Files.regular_file!(source)
  end

  defp source_references(".ex", path, content) do
    content |> Code.string_to_quoted!(file: path) |> TemplateScanner.ast(MapSet.new(), scanner()) |> MapSet.to_list()
  end

  defp source_references(".heex", path, content) do
    content |> TemplateScanner.heex(MapSet.new(), scanner(), path) |> MapSet.to_list()
  end

  defp source_type!(source) do
    case File.lstat(source) do
      {:ok, %{type: :directory}} ->
        :directory

      {:ok, %{type: :regular}} ->
        if Path.extname(source) == ".svg",
          do: :regular,
          else: raise(ArgumentError, "SVG sprite source file must have an .svg extension: #{source}")

      {:ok, %{type: type}} ->
        raise ArgumentError, "invalid SVG sprite source type #{inspect(type)}: #{source}"

      {:error, reason} ->
        raise File.Error, reason: reason, action: "stat SVG sprite source", path: source
    end
  end

  defp sprite_entry_name(prefix, name, suffix) do
    prefix <> (name |> Path.basename() |> Path.rootname()) <> suffix <> ".svg"
  end

  defp sprite_mode!(:stack), do: "stack"
  defp sprite_mode!(:symbol), do: "symbol"

  defp sprite_mode!(mode) do
    raise ArgumentError, "invalid SVG sprite mode #{inspect(mode)}; expected :symbol or :stack"
  end

  defp used_sprite_ids(specs) do
    ids_by_sprite =
      for {sprite, _, _, _, _, _, _, _, _, opts} <- specs,
          not is_map_key(opts, :names) and not is_map_key(opts, :files),
          into: %{},
          do: {sprite, MapSet.new()}

    if ids_by_sprite == %{} do
      ids_by_sprite
    else
      cache_path = Path.join(Config.manifest_cache_dir(), @scan_cache_file)
      fingerprint = scan_fingerprint()

      cache = Cache.read_map(cache_path, fingerprint)

      {files, ids_by_sprite} =
        Config.project_dir()
        |> Path.join("lib")
        |> Files.digests(@source_digest_cache_file)
        |> Enum.reduce({%{}, ids_by_sprite}, &collect_source_file(&1, &2, cache))

      if files != cache, do: Cache.write_term!(cache_path, {fingerprint, files})
      ids_by_sprite
    end
  end

  defp visit({:svg_sprite_href, _, [value]}, ids) when is_binary(value), do: {:ok, collect_sprite_href(value, ids)}

  defp visit({{:., _, [_, :svg_sprite_href]}, _, [value]}, ids) when is_binary(value) do
    {:ok, collect_sprite_href(value, ids)}
  end

  defp visit({kind, _, [{:when, _, [{:icon_name, _, _} | _]}, [do: value]]}, ids)
       when kind in [:def, :defp] and is_binary(value) do
    {:ok, put_icons_id(value, ids)}
  end

  defp visit({kind, _, [{:icon_name, _, _}, [do: value]]}, ids) when kind in [:def, :defp] and is_binary(value) do
    {:ok, put_icons_id(value, ids)}
  end

  defp visit({:icon, value}, ids) when is_binary(value), do: {:ok, put_icons_id(value, ids)}
  defp visit(_, _), do: :next
end
