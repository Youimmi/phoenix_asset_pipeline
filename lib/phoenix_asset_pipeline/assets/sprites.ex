defmodule PhoenixAssetPipeline.Assets.Sprites do
  @moduledoc false

  alias PhoenixAssetPipeline.Config

  @direct_sprite_ref_pattern ~r/svg_sprite_href\(\s*"([^"#{}]+)#([^"#{}]+)"\s*\)/
  @icon_value_pattern ~r/(?:\bicon:|\sicon\s*=)\s*"([^"]+)"|\bicon_name\([^)]*\),\s*do:\s*"([^"]+)"/
  @literal_attr_pattern ~r/\s+(name|sprite)\s*=\s*"([^"]*)"/
  @component_pattern ~r/<\.(menu_icon|icon)\b[^>]*>/s
  @source_exts ~w(.ex .heex)
  @sprite_group_type :svg_sprite_group
  @sprite_source_type :svg_sprite_source

  def snapshot(assets_dir \\ Config.assets_dir()) do
    snapshot(assets_dir, Config.svg_sprites())
  end

  @doc false
  def snapshot(assets_dir, config) when is_list(config) do
    assets_dir
    |> Path.expand()
    |> configured_entries(config)
  end

  def entries(source \\ snapshot())
  def entries(assets_dir) when is_binary(assets_dir), do: assets_dir |> snapshot() |> entries()
  def entries(entries) when is_list(entries), do: entries

  def source_terms(nil), do: []

  def source_terms(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {@sprite_group_type, sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, path, name, root, _, digest} ->
        relative = path |> Path.relative_to(root) |> forward_path()
        {@sprite_source_type, sprite, name, relative, digest}
    end)
  end

  def source_dirs(nil), do: []

  def source_dirs(entries) do
    entries
    |> Enum.flat_map(fn
      {@sprite_group_type, _, _, _, nil, _} -> []
      {@sprite_group_type, _, _, _, metadata_path, _} -> [Path.dirname(metadata_path)]
      {@sprite_source_type, _, _, _, _, watch_dir, _} -> [watch_dir]
    end)
    |> Enum.uniq()
  end

  def signature(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, _, name, _, _, digest} ->
        {sprite, name, digest}
    end)
  end

  defp configured_entries(assets_dir, config) do
    specs = Enum.map(config, &source_config(assets_dir, &1))
    used_ids_by_sprite = used_sprite_ids(assets_dir, specs)
    source_names = assigned_source_names(assets_dir, used_ids_by_sprite, specs)
    groups = configured_sprite_groups(specs)

    sources =
      specs
      |> Enum.with_index()
      |> Enum.flat_map(fn {spec, index} -> configured_source_entries(spec, Map.get(source_names, index, [])) end)
      |> Enum.reduce(%{}, fn {@sprite_source_type, sprite, _, name, _, _, _} = source, sources ->
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
      |> Enum.sort_by(fn {@sprite_source_type, sprite, _, name, _, _, _} -> {sprite, name} end)

    groups ++ sources
  end

  defp configured_source_entries(
         {sprite, _, source, source_type, root, watch_dir, prefix, suffix, _, _, opts},
         source_names
       ) do
    for {path, name, digest} <- configured_source_files(opts, source, source_type, source_names) do
      {@sprite_source_type, sprite, path, sprite_entry_name(prefix, name, suffix), root, watch_dir, digest}
    end
  end

  defp configured_sprite_groups(specs) do
    specs
    |> Enum.reduce(%{}, fn {sprite, mode, _, _, _, _, _, _, namespace_ids?, metadata, _}, groups ->
      options = {mode, namespace_ids?, metadata}
      Map.update(groups, sprite, options, &merge_sprite_options!(sprite, &1, options))
    end)
    |> Enum.map(fn {sprite, {mode, namespace_ids?, metadata}} ->
      {metadata_path, metadata_digest} = metadata || {nil, nil}
      {@sprite_group_type, sprite, mode, namespace_ids? != false, metadata_path, metadata_digest}
    end)
    |> Enum.sort_by(fn {@sprite_group_type, sprite, _, _, _, _} -> sprite end)
  end

  defp merge_sprite_options!(sprite, {mode, namespace_ids?, metadata}, {mode, next_namespace_ids?, next_metadata}) do
    {mode, merge_sprite_option!(sprite, :namespace_ids, namespace_ids?, next_namespace_ids?),
     merge_sprite_option!(sprite, :metadata_file, metadata, next_metadata)}
  end

  defp merge_sprite_options!(sprite, existing, next) do
    raise ArgumentError,
          "conflicting SVG sprite options for #{inspect(sprite)}: #{inspect(existing)} and #{inspect(next)}"
  end

  defp merge_sprite_option!(_, _, nil, value), do: value
  defp merge_sprite_option!(_, _, value, nil), do: value
  defp merge_sprite_option!(_, _, value, value), do: value

  defp merge_sprite_option!(sprite, option, existing, next) do
    raise ArgumentError,
          "conflicting SVG sprite #{option} values for #{inspect(sprite)}: " <>
            "#{inspect(existing)} and #{inspect(next)}"
  end

  defp configured_source_files(opts, source, source_type, source_names) do
    case {Map.get(opts, :names), Map.get(opts, :files)} do
      {nil, nil} ->
        Enum.map(source_names, &configured_source_file(source, source_type, &1))

      {names, nil} when is_list(names) and source_type == :directory ->
        Enum.map(names, fn
          name when is_binary(name) and name != "" ->
            path = source_path(source, name)
            {path, name, file_digest!(path)}

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

  defp configured_source_file(source, :directory, name) do
    path = source_path(source, name)
    {path, name, file_digest!(path)}
  end

  defp configured_source_file(source, _, name) do
    path = Path.expand(source)
    {path, name, file_digest!(path)}
  end

  defp default_mode("app.svg"), do: :stack
  defp default_mode(_), do: :symbol

  defp ensure_svg_ext(path) do
    if Path.extname(path) == ".svg", do: path, else: path <> ".svg"
  end

  defp expand_project_path(path, assets_dir) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: assets_dir |> project_dir() |> Path.join(path) |> Path.expand()
  end

  defp file_digest!(path), do: path |> File.read!() |> :erlang.md5()

  defp forward_path(path), do: String.replace(path, "\\", "/")

  defp collect_direct_sprite_refs(content, ids_by_sprite) do
    Enum.reduce(Regex.scan(@direct_sprite_ref_pattern, content), ids_by_sprite, fn [_, sprite, id], ids_by_sprite ->
      put_sprite_id(ids_by_sprite, sprite, id)
    end)
  end

  defp collect_icon_component_ref(tag, ids_by_sprite) do
    {name, sprite} = literal_attrs(tag)

    if is_binary(name),
      do: put_sprite_id(ids_by_sprite, sprite || "icons.svg", name),
      else: ids_by_sprite
  end

  defp collect_menu_icon_component_ref(tag, %{"icons.svg" => _} = ids_by_sprite) do
    {name, sprite} = literal_attrs(tag)

    ids_by_sprite = put_icons_id(name, ids_by_sprite)

    put_icons_id(sprite, ids_by_sprite)
  end

  defp collect_menu_icon_component_ref(_, ids_by_sprite), do: ids_by_sprite

  defp collect_icon_value_refs(content, %{"icons.svg" => _} = ids_by_sprite) do
    Enum.reduce(Regex.scan(@icon_value_pattern, content), ids_by_sprite, fn [_ | captures], ids_by_sprite ->
      put_icons_id(first_capture(captures), ids_by_sprite)
    end)
  end

  defp collect_icon_value_refs(_, ids_by_sprite), do: ids_by_sprite

  defp first_capture(captures), do: Enum.find(captures, &(is_binary(&1) and &1 != ""))

  defp literal_attrs(tag) do
    Enum.reduce(Regex.scan(@literal_attr_pattern, tag), {nil, nil}, fn
      [_, "name", value], {_, sprite} -> {value, sprite}
      [_, "sprite", value], {name, _} -> {name, value}
    end)
  end

  defp sprite_entry_name(prefix, name, suffix) do
    prefix <> (name |> Path.basename() |> Path.rootname()) <> suffix <> ".svg"
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

  defp source_config(assets_dir, %{file: file, src: src} = opts)
       when is_binary(file) and file != "" and is_binary(src) and src != "" do
    sprite = sprite_name(file)
    mode = opts |> Map.get(:mode, default_mode(sprite)) |> sprite_mode!()
    prefix = Map.get(opts, :prefix, "")
    suffix = Map.get(opts, :suffix, "")
    namespace_ids? = optional_boolean!(opts, :namespace_ids)
    metadata = metadata_source(assets_dir, opts)
    source = expand_project_path(src, assets_dir)
    source_type = source_type!(source)
    root = if source_type == :directory, do: source, else: Path.dirname(source)
    watch_dir = if source_type == :directory, do: source, else: Path.dirname(source)

    if not (is_binary(prefix) and is_binary(suffix)) do
      raise ArgumentError, ":prefix and :suffix in :svg_sprites entries must be strings"
    end

    {sprite, mode, source, source_type, root, watch_dir, prefix, suffix, namespace_ids?, metadata, opts}
  end

  defp source_config(_, opts) do
    raise ArgumentError,
          "invalid :svg_sprites entry #{inspect(opts)}; expected a map with non-empty :file and :src strings"
  end

  defp optional_boolean!(opts, key) do
    case Map.fetch(opts, key) do
      :error -> nil
      {:ok, value} when is_boolean(value) -> value
      _ -> raise ArgumentError, "invalid #{inspect(key)} in :svg_sprites entry; expected a boolean"
    end
  end

  defp metadata_source(assets_dir, opts) do
    case Map.fetch(opts, :metadata_file) do
      :error ->
        nil

      {:ok, path} when is_binary(path) and path != "" ->
        path = expand_project_path(path, assets_dir)
        {path, file_digest!(path)}

      _ ->
        raise ArgumentError, "invalid :metadata_file in :svg_sprites entry; expected a non-empty path"
    end
  end

  defp sprite_mode!(:stack), do: "stack"
  defp sprite_mode!(:symbol), do: "symbol"

  defp sprite_mode!(mode) do
    raise ArgumentError, "invalid SVG sprite mode #{inspect(mode)}; expected :symbol or :stack"
  end

  defp sprite_name(name) do
    name = to_string(name)

    if Path.extname(name) == ".svg", do: name, else: name <> ".svg"
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
    case Path.safe_relative(ensure_svg_ext(name), source) do
      {:ok, path} -> Path.expand(path, source)
      :error -> raise ArgumentError, "SVG sprite name resolves outside its source directory: #{inspect(name)}"
    end
  end

  defp assigned_source_names(assets_dir, used_ids_by_sprite, specs) do
    sources_by_sprite =
      specs
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {{sprite, _, _, _, _, _, _, _, _, _, _} = spec, index}, sources ->
        Map.update(sources, sprite, [{index, spec}], &[{index, spec} | &1])
      end)

    Enum.reduce(used_ids_by_sprite, %{}, fn {sprite, ids}, assigned ->
      candidates = Map.fetch!(sources_by_sprite, sprite)
      local_source = Path.join([assets_dir, "svg", "sprites", Path.rootname(sprite)])
      Enum.reduce(ids, assigned, &assign_source_name(&1, &2, sprite, candidates, local_source))
    end)
  end

  defp assign_source_name(id, assigned, sprite, candidates, local_source) do
    case best_source_candidate(id, candidates) do
      nil ->
        path = source_path(local_source, id)

        case File.stat(path) do
          {:ok, %{type: :regular}} -> assigned
          {:ok, %{type: type}} -> raise ArgumentError, "invalid SVG sprite source type #{inspect(type)}: #{path}"
          {:error, :enoent} -> raise ArgumentError, "missing SVG sprite source for #{inspect(sprite)}##{id}"
          {:error, reason} -> raise File.Error, reason: reason, action: "stat SVG sprite source", path: path
        end

      {_, index, name, _} ->
        Map.update(assigned, index, [name], &[name | &1])
    end
  end

  defp best_source_candidate(id, candidates) do
    Enum.reduce(candidates, nil, fn {index, spec}, best ->
      case source_candidate(id, index, spec) do
        nil -> best
        candidate -> select_source_candidate(id, candidate, best)
      end
    end)
  end

  defp select_source_candidate(_, candidate, nil), do: candidate

  defp select_source_candidate(_, {score, _, _, _} = candidate, {best_score, _, _, _}) when score > best_score,
    do: candidate

  defp select_source_candidate(_, {score, _, _, _}, {best_score, _, _, _} = best) when score < best_score, do: best

  defp select_source_candidate(id, {_, _, _, source}, {_, _, _, other_source}) do
    raise ArgumentError,
          "ambiguous SVG sprite source for ##{id}: #{inspect(other_source)} and #{inspect(source)}"
  end

  defp source_candidate(id, index, {_, _, source, :directory, _, _, prefix, suffix, _, _, opts}) do
    case {Map.get(opts, :names), Map.get(opts, :files)} do
      {nil, nil} ->
        case source_name(id, prefix, suffix) do
          nil -> nil
          name -> {byte_size(prefix) + byte_size(suffix), index, name, source}
        end

      {names, nil} when is_list(names) ->
        explicit_source_candidate(id, index, source, prefix, suffix, names, false)

      {nil, files} when is_list(files) ->
        explicit_source_candidate(id, index, source, prefix, suffix, files, true)

      _ ->
        nil
    end
  end

  defp source_candidate(id, index, {_, _, source, _, _, _, prefix, suffix, _, _, _}) do
    name = Path.basename(source)

    if id == Path.rootname(sprite_entry_name(prefix, name, suffix)),
      do: {byte_size(id) + 1, index, name, source}
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

  defp used_sprite_ids(assets_dir, specs) do
    sprites =
      Enum.reduce(specs, MapSet.new(), fn
        {sprite, _, _, _, _, _, _, _, _, _, opts}, sprites ->
          if Map.has_key?(opts, :names) or Map.has_key?(opts, :files),
            do: sprites,
            else: MapSet.put(sprites, sprite)
      end)

    if MapSet.size(sprites) == 0 do
      %{}
    else
      ids_by_sprite = Map.new(sprites, &{&1, MapSet.new()})

      assets_dir
      |> project_dir()
      |> Path.join("lib")
      |> reduce_source_files(ids_by_sprite, fn path, ids_by_sprite ->
        path
        |> File.read!()
        |> collect_used_sprite_ids(ids_by_sprite)
      end)
    end
  end

  defp collect_used_sprite_ids(content, ids_by_sprite) do
    ids_by_sprite = collect_direct_sprite_refs(content, ids_by_sprite)
    ids_by_sprite = collect_icon_value_refs(content, ids_by_sprite)

    Enum.reduce(Regex.scan(@component_pattern, content), ids_by_sprite, fn
      [tag, "menu_icon"], ids_by_sprite -> collect_menu_icon_component_ref(tag, ids_by_sprite)
      [tag, "icon"], ids_by_sprite -> collect_icon_component_ref(tag, ids_by_sprite)
    end)
  end

  defp put_icons_id(nil, ids_by_sprite), do: ids_by_sprite
  defp put_icons_id("", ids_by_sprite), do: ids_by_sprite
  defp put_icons_id(id, ids_by_sprite), do: put_sprite_id(ids_by_sprite, "icons.svg", id)

  defp put_sprite_id(ids_by_sprite, sprite, id) do
    case ids_by_sprite do
      %{^sprite => ids} ->
        if MapSet.member?(ids, id),
          do: ids_by_sprite,
          else: Map.put(ids_by_sprite, sprite, MapSet.put(ids, :binary.copy(id)))

      _ ->
        ids_by_sprite
    end
  end

  defp source_type!(source) do
    case File.stat(source) do
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

  defp reduce_source_entry(_, "." <> _, acc, _), do: acc
  defp reduce_source_entry(_, "node_modules", acc, _), do: acc

  defp reduce_source_entry(dir, entry, acc, fun) do
    path = Path.join(dir, entry)

    case File.stat(path) do
      {:ok, %{type: :directory}} -> reduce_source_files(path, acc, fun)
      {:ok, %{type: :regular}} -> if Path.extname(path) in @source_exts, do: fun.(path, acc), else: acc
      {:ok, _} -> acc
      {:error, :enoent} -> acc
      {:error, reason} -> raise File.Error, reason: reason, action: "stat source file", path: path
    end
  end

  defp reduce_source_files(dir, acc, fun) do
    dir = Path.expand(dir)

    case File.ls(dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &reduce_source_entry(dir, &1, &2, fun))
      {:error, :enoent} -> acc
      {:error, reason} -> raise File.Error, reason: reason, action: "list source files", path: dir
    end
  end
end
