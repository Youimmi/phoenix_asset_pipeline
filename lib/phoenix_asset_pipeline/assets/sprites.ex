defmodule PhoenixAssetPipeline.Assets.Sprites do
  @moduledoc false

  alias PhoenixAssetPipeline.Config

  @direct_sprite_ref_pattern ~r/svg_sprite_href\(\s*"([^"#{}]+)#([^"#{}]+)"\s*\)/
  @hero_value_pattern ~r/\bicon:\s*"([^"]+)"|\bicon_name\([^)]*\),\s*do:\s*"([^"]+)"/
  @icon_component_pattern ~r/<\.icon\b[^>]*>/s
  @literal_attr_pattern ~r/\b([a-zA-Z_][\w-]*)\s*=\s*"([^"]*)"/
  @menu_icon_component_pattern ~r/<\.menu_icon\b[^>]*>/s
  @source_exts ~w(.ex .heex)
  @sprite_source_type :svg_sprite_source

  def snapshot(assets_dir \\ Config.assets_dir()) do
    assets_dir
    |> Path.expand()
    |> configured_entries()
    |> Enum.uniq_by(fn {sprite, mode, _, name, _, _, _} -> {sprite, mode, name} end)
    |> Enum.sort_by(fn {sprite, mode, _, name, _, _, _} -> {sprite, mode, name} end)
  end

  def entries(source \\ snapshot())
  def entries(assets_dir) when is_binary(assets_dir), do: assets_dir |> snapshot() |> entries()
  def entries(entries) when is_list(entries), do: entries

  def source_terms(nil), do: []

  def source_terms(entries) do
    Enum.map(entries, fn {sprite, mode, path, name, root, _, digest} ->
      {@sprite_source_type, sprite, mode, name, Path.relative_to(path, root), digest}
    end)
  end

  def source_dirs(nil), do: []

  def source_dirs(entries) do
    entries
    |> Enum.map(fn {_, _, _, _, _, watch_dir, _} -> watch_dir end)
    |> Enum.uniq()
  end

  def signature(entries) do
    Enum.map(entries, fn {sprite, mode, _, name, _, _, digest} -> {sprite, mode, name, digest} end)
  end

  defp configured_entries(assets_dir) do
    specs =
      Config.svg_sprites()
      |> configured_source_specs()
      |> Enum.map(&source_config(assets_dir, &1))

    used_ids_by_sprite = used_sprite_ids(assets_dir, specs)

    Enum.flat_map(specs, &configured_source_entries(&1, used_ids_by_sprite))
  end

  defp configured_source_entries({sprite, mode, source, root, watch_dir, prefix, suffix, opts}, used_ids_by_sprite) do
    source_files = configured_source_files(opts, source, Map.get(used_ids_by_sprite, sprite), prefix, suffix)

    for {path, name} <- source_files do
      entry(sprite, mode, path, sprite_entry_name(prefix, name, suffix), root, watch_dir)
    end
  end

  defp configured_source_files(opts, source, used_ids, prefix, suffix) do
    cond do
      names = fetch_optional(opts, :names, nil) ->
        for name <- list_strings(names), do: {Path.expand(ensure_svg_ext(name), source), name}

      files = fetch_optional(opts, :files, nil) ->
        for file <- list_strings(files), do: {expand_path(file, source), Path.basename(file)}

      true ->
        used_source_files(source, used_ids, prefix, suffix)
    end
  end

  defp configured_source_specs([]), do: []

  defp configured_source_specs(config) when is_list(config) do
    if Keyword.keyword?(config) and source_spec?(config),
      do: [Map.new(config)],
      else: Enum.flat_map(config, &configured_source_spec/1)
  end

  defp configured_source_specs(config), do: configured_source_specs(List.wrap(config))

  defp configured_source_spec({file, opts}) when is_atom(file) or is_binary(file) do
    [Map.put_new(opts_map(opts), :file, file)]
  end

  defp configured_source_spec(opts) when is_map(opts), do: [opts]
  defp configured_source_spec(opts) when is_list(opts), do: [Map.new(opts)]

  defp configured_source_spec(opts) do
    raise ArgumentError,
          "invalid :svg_sprites entry #{inspect(opts)}; expected a map, keyword list, or {file, opts}"
  end

  defp default_mode("app.svg"), do: "stack"
  defp default_mode(_), do: "symbol"

  defp ensure_svg_ext(path) do
    if Path.extname(path) == ".svg", do: path, else: path <> ".svg"
  end

  defp entry(sprite, mode, path, name, root, watch_dir) do
    {sprite, mode, path, name, root, watch_dir, file_digest(path)}
  end

  defp expand_path(path, root) do
    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: Path.expand(path, root)
  end

  defp expand_project_path(path, assets_dir) do
    path = to_string(path)

    if Path.type(path) == :absolute,
      do: Path.expand(path),
      else: assets_dir |> project_dir() |> Path.join(path) |> Path.expand()
  end

  defp fetch_optional(opts, key, default), do: Map.get(opts, key) || Map.get(opts, to_string(key), default)

  defp fetch_required!(opts, key) do
    fetch_optional(opts, key, nil) ||
      raise ArgumentError, "missing #{inspect(key)} in :svg_sprites entry #{inspect(opts)}"
  end

  defp fetch_src!(opts) do
    fetch_optional(opts, :src, nil) ||
      fetch_optional(opts, :path, nil) ||
      fetch_optional(opts, :dir, nil) ||
      raise ArgumentError, "missing :src in :svg_sprites entry #{inspect(opts)}"
  end

  defp file_digest(path) do
    if File.regular?(path) do
      path
      |> File.read!()
      |> :erlang.md5()
      |> Base.encode16(case: :lower)
    else
      :missing
    end
  end

  defp collect_direct_sprite_refs(content, ids_by_sprite) do
    Enum.reduce(Regex.scan(@direct_sprite_ref_pattern, content), ids_by_sprite, fn [_, sprite, id], ids_by_sprite ->
      put_sprite_id(ids_by_sprite, sprite, id)
    end)
  end

  defp collect_icon_component_refs(content, ids_by_sprite) do
    Enum.reduce(Regex.scan(@icon_component_pattern, content), ids_by_sprite, fn [tag], ids_by_sprite ->
      attrs = literal_attrs(tag)
      sprite = Map.get(attrs, "sprite", "icons.svg")

      case Map.fetch(attrs, "name") do
        {:ok, name} -> put_sprite_id(ids_by_sprite, sprite, Map.get(attrs, "prefix", "hero-") <> name)
        :error -> ids_by_sprite
      end
    end)
  end

  defp collect_menu_icon_component_refs(content, %{"icons.svg" => _} = ids_by_sprite) do
    Enum.reduce(Regex.scan(@menu_icon_component_pattern, content), ids_by_sprite, fn [tag], ids_by_sprite ->
      attrs = literal_attrs(tag)

      ids_by_sprite =
        attrs
        |> Map.get("name")
        |> put_icons_id(ids_by_sprite, "hero-")

      attrs
      |> Map.get("sprite")
      |> put_icons_id(ids_by_sprite, "")
    end)
  end

  defp collect_menu_icon_component_refs(_, ids_by_sprite), do: ids_by_sprite

  defp collect_hero_value_refs(content, %{"icons.svg" => _} = ids_by_sprite) do
    Enum.reduce(Regex.scan(@hero_value_pattern, content), ids_by_sprite, fn
      [_ | captures], ids_by_sprite ->
        captures
        |> first_capture()
        |> put_icons_id(ids_by_sprite, "hero-")
    end)
  end

  defp collect_hero_value_refs(_, ids_by_sprite), do: ids_by_sprite

  defp list_strings(value) do
    for value <- List.wrap(value), value = to_string(value), value != "", do: value
  end

  defp first_capture(captures), do: Enum.find(captures, &(is_binary(&1) and &1 != ""))

  defp literal_attrs(tag) do
    Map.new(Regex.scan(@literal_attr_pattern, tag), fn [_, key, value] ->
      {key, value}
    end)
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)

  defp opts_map(opts) do
    raise ArgumentError, "invalid :svg_sprites opts #{inspect(opts)}; expected a map or keyword list"
  end

  defp sprite_entry_name(prefix, name, suffix) do
    prefix <> (name |> Path.basename() |> Path.rootname()) <> suffix <> ".svg"
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

  defp source_spec?(opts) do
    Enum.any?([:src, :path, :dir], &Keyword.has_key?(opts, &1)) or
      Enum.any?(~w(src path dir), &Keyword.has_key?(opts, &1))
  end

  defp source_root(source) do
    cond do
      File.dir?(source) -> source
      Path.extname(source) == ".svg" -> Path.dirname(source)
      true -> source
    end
  end

  defp source_config(assets_dir, opts) do
    sprite = opts |> fetch_required!(:file) |> sprite_name()
    mode = opts |> fetch_optional(:mode, default_mode(sprite)) |> sprite_mode!()
    prefix = opts |> fetch_optional(:prefix, "") |> to_string()
    suffix = opts |> fetch_optional(:suffix, "") |> to_string()
    source = opts |> fetch_src!() |> expand_project_path(assets_dir)
    root = source_root(source)
    watch_dir = if File.dir?(source), do: source, else: Path.dirname(source)

    {sprite, mode, source, root, watch_dir, prefix, suffix, opts}
  end

  defp sprite_mode!(mode) do
    case mode |> to_string() |> String.downcase() do
      mode when mode in ["symbol", "stack"] ->
        mode

      mode ->
        raise ArgumentError,
              "invalid SVG sprite mode #{inspect(mode)}; expected :symbol, \"symbol\", :stack, or \"stack\""
    end
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
    source
    |> Path.join(ensure_svg_ext(name))
    |> Path.expand()
  end

  defp used_source_files(source, used_ids, prefix, suffix) do
    if File.dir?(source) do
      Enum.flat_map(used_ids || [], &used_source_file(source, &1, prefix, suffix))
    else
      used_source_file(source, Path.rootname(sprite_entry_name(prefix, Path.basename(source), suffix)), used_ids)
    end
  end

  defp used_source_file(source, id, prefix, suffix) do
    with name when is_binary(name) <- source_name(id, prefix, suffix),
         path = source_path(source, name),
         true <- File.regular?(path) do
      [{path, name}]
    else
      _ -> []
    end
  end

  defp used_source_file(source, id, used_ids) do
    if is_struct(used_ids, MapSet) and MapSet.member?(used_ids, id) and File.regular?(source),
      do: [{Path.expand(source), Path.basename(source)}],
      else: []
  end

  defp used_sprite_ids(assets_dir, specs) do
    sprites =
      Enum.reduce(specs, MapSet.new(), fn
        {sprite, _, _, _, _, _, _, opts}, sprites ->
          if fetch_optional(opts, :names, nil) || fetch_optional(opts, :files, nil),
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
    ids_by_sprite = collect_icon_component_refs(content, ids_by_sprite)
    ids_by_sprite = collect_menu_icon_component_refs(content, ids_by_sprite)

    collect_hero_value_refs(content, ids_by_sprite)
  end

  defp put_icons_id(nil, ids_by_sprite, _), do: ids_by_sprite
  defp put_icons_id("", ids_by_sprite, _), do: ids_by_sprite
  defp put_icons_id(id, ids_by_sprite, prefix), do: put_sprite_id(ids_by_sprite, "icons.svg", prefix <> id)

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

  defp reduce_source_entry(_, "." <> _, acc, _), do: acc
  defp reduce_source_entry(_, "node_modules", acc, _), do: acc

  defp reduce_source_entry(dir, entry, acc, fun) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) -> reduce_source_files(path, acc, fun)
      File.regular?(path) and Path.extname(path) in @source_exts -> fun.(path, acc)
      true -> acc
    end
  end

  defp reduce_source_files(dir, acc, fun) do
    dir = Path.expand(dir)

    case File.ls(dir) do
      {:ok, entries} -> Enum.reduce(entries, acc, &reduce_source_entry(dir, &1, &2, fun))
      {:error, _} -> acc
    end
  end
end
