defmodule PhoenixAssetPipeline.Assets.Sprites do
  @moduledoc false

  alias Phoenix.LiveView.TagEngine.Parser
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files
  alias PhoenixAssetPipeline.HTML.Entities

  @sprite_group_type :svg_sprite_group
  @sprite_source_type :svg_sprite_source

  def entries(source \\ snapshot())
  def entries(assets_dir) when is_binary(assets_dir), do: assets_dir |> snapshot() |> entries()
  def entries(entries) when is_list(entries), do: entries

  def signature(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, _, name, _, digest} ->
        {sprite, name, digest}
    end)
  end

  def snapshot(assets_dir \\ Config.assets_dir()) do
    snapshot(assets_dir, Config.svg_sprites())
  end

  @doc false
  def snapshot(assets_dir, config) when is_list(config) do
    assets_dir
    |> Path.expand()
    |> configured_entries(config)
  end

  def source_dirs(nil), do: []

  def source_dirs(entries) do
    entries
    |> Enum.flat_map(fn
      {@sprite_group_type, _, _, _, nil, _} -> []
      {@sprite_group_type, _, _, _, metadata_path, _} -> [Path.dirname(metadata_path)]
      {@sprite_source_type, _, _, _, root, _} -> [root]
    end)
    |> Enum.uniq()
  end

  def source_terms(nil), do: []

  def source_terms(entries) do
    Enum.map(entries, fn
      {@sprite_group_type, sprite, mode, namespace_ids?, _, metadata_digest} ->
        {@sprite_group_type, sprite, mode, namespace_ids?, metadata_digest}

      {@sprite_source_type, sprite, path, name, root, digest} ->
        relative = Files.relative_path(path, root)
        {@sprite_source_type, sprite, name, relative, digest}
    end)
  end

  defp assign_source_name(id, assigned, candidates, local_source) do
    case best_source_candidate(id, candidates) do
      nil ->
        _ = source_path(local_source, id)
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
    Enum.reduce(candidates, nil, fn {index, spec}, best ->
      case source_candidate(id, index, spec) do
        nil -> best
        candidate -> select_source_candidate(id, candidate, best)
      end
    end)
  end

  defp collect_ast({:@, _, [{kind, _, _}]}, ids) when kind in [:doc, :moduledoc, :typedoc], do: ids
  defp collect_ast({:quote, _, _}, ids), do: ids

  defp collect_ast({:sigil_H, _, [{:<<>>, _, [source]}, _]}, ids) when is_binary(source) do
    collect_heex(source, ids)
  end

  defp collect_ast({:svg_sprite_href, _, [value]}, ids) when is_binary(value), do: collect_sprite_href(value, ids)

  defp collect_ast({{:., _, [_, :svg_sprite_href]}, _, [value]}, ids) when is_binary(value) do
    collect_sprite_href(value, ids)
  end

  defp collect_ast({kind, _, [{:icon_name, _, _}, [do: value]]}, ids) when kind in [:def, :defp] and is_binary(value),
    do: put_icons_id(value, ids)

  defp collect_ast({:icon, value}, ids) when is_binary(value), do: put_icons_id(value, ids)
  defp collect_ast({_, _, args}, ids) when is_list(args), do: collect_ast(args, ids)
  defp collect_ast({left, right}, ids), do: collect_ast(right, collect_ast(left, ids))
  defp collect_ast([node | nodes], ids), do: collect_ast(nodes, collect_ast(node, ids))
  defp collect_ast(_, ids), do: ids

  defp collect_attribute({key, value, _}, {name, sprite, ids}) do
    {value, ids} =
      case value do
        {:expr, expression, _} ->
          ast = Code.string_to_quoted!(expression)
          {ast, collect_ast(ast, ids)}

        {:string, value, _} when key in ["name", "sprite", "icon"] ->
          {Entities.decode_attribute(value), ids}

        _ ->
          {nil, ids}
      end

    case {key, value} do
      {"name", value} when is_binary(value) -> {value, sprite, ids}
      {"sprite", value} when is_binary(value) -> {name, value, ids}
      {"icon", value} when is_binary(value) -> {name, sprite, put_icons_id(value, ids)}
      _ -> {name, sprite, ids}
    end
  end

  defp collect_heex(source, ids, file \\ "nofile") do
    source
    |> Parser.parse!(
      file: file,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      skip_macro_components: true,
      strip_eex_comments: true,
      prune_text_after_slots: false
    )
    |> Map.fetch!(:nodes)
    |> Enum.reduce(ids, &collect_heex_node/2)
  end

  defp collect_heex_node({:block, type, name, attrs, children, _, _}, ids) do
    Enum.reduce(children, collect_tag(type, name, attrs, ids), &collect_heex_node/2)
  end

  defp collect_heex_node({:self_close, type, name, attrs, _}, ids), do: collect_tag(type, name, attrs, ids)

  defp collect_heex_node({type, expression, _}, ids) when type in [:eex, :body_expr] do
    expression |> Code.string_to_quoted!() |> collect_ast(ids)
  end

  defp collect_heex_node({:eex_block, expression, clauses, _}, ids) do
    state = {ids, String.ends_with?(String.trim_trailing(expression), "->")}

    {clauses, {ids, _}} =
      Enum.map_reduce(clauses, state, fn {nodes, expression, _}, {ids, previous_clause?} ->
        clause? = String.ends_with?(String.trim_trailing(expression), "->")
        # The first case/cond clause has no preceding body; empty branches still need nil.
        body = if clause? and not previous_clause?, do: "\n", else: "\nnil\n"
        {[body, expression], {Enum.reduce(nodes, ids, &collect_heex_node/2), clause?}}
      end)

    [expression | clauses] |> IO.iodata_to_binary() |> Code.string_to_quoted!() |> collect_ast(ids)
  end

  defp collect_heex_node(_, ids), do: ids

  defp collect_source_file(path, ids) do
    case Path.extname(path) do
      ".ex" -> path |> File.read!() |> Code.string_to_quoted!(file: path) |> collect_ast(ids)
      ".heex" -> path |> File.read!() |> collect_heex(ids, path)
      _ -> ids
    end
  end

  defp collect_sprite_href(value, ids) do
    case :binary.split(value, "#", [:global]) do
      [sprite, id] when sprite != "" and id != "" -> put_sprite_id(ids, sprite, id)
      _ -> ids
    end
  end

  defp collect_tag(type, tag, attrs, ids) do
    {name, sprite, ids} = Enum.reduce(attrs, {nil, nil, ids}, &collect_attribute/2)

    case {type, tag} do
      {:local_component, "icon"} when is_binary(name) -> put_sprite_id(ids, sprite || "icons.svg", name)
      {:local_component, "menu_icon"} -> put_icons_id(sprite, put_icons_id(name, ids))
      _ -> ids
    end
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

  defp configured_source_file(source, :directory, name) do
    path = source_path(source, name)
    {path, name, file_digest!(path)}
  end

  defp configured_source_file(source, _, name) do
    path = Path.expand(source)
    {path, name, file_digest!(path)}
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

  defp optional_boolean!(opts, key) do
    case Map.fetch(opts, key) do
      :error -> nil
      {:ok, value} when is_boolean(value) -> value
      _ -> raise ArgumentError, "invalid #{inspect(key)} in :svg_sprites entry; expected a boolean"
    end
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))

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

  defp select_source_candidate(_, candidate, nil), do: candidate

  defp select_source_candidate(_, {score, _, _, _} = candidate, {best_score, _, _, _}) when score > best_score,
    do: candidate

  defp select_source_candidate(_, {score, _, _, _}, {best_score, _, _, _} = best) when score < best_score, do: best

  defp select_source_candidate(id, {_, _, _, source}, {_, _, _, other_source}) do
    raise ArgumentError,
          "ambiguous SVG sprite source for ##{id}: #{inspect(other_source)} and #{inspect(source)}"
  end

  defp source_candidate(id, index, {_, _, source, :directory, _, prefix, suffix, _, _, opts}) do
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

  defp source_candidate(id, index, {_, _, source, _, _, prefix, suffix, _, _, _}) do
    name = Path.basename(source)

    if id == Path.rootname(sprite_entry_name(prefix, name, suffix)),
      do: {byte_size(id) + 1, index, name, source}
  end

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

    if not (is_binary(prefix) and is_binary(suffix)) do
      raise ArgumentError, ":prefix and :suffix in :svg_sprites entries must be strings"
    end

    {sprite, mode, source, source_type, root, prefix, suffix, namespace_ids?, metadata, opts}
  end

  defp source_config(_, opts) do
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

  defp sprite_name(name) do
    name = to_string(name)

    if Path.extname(name) == ".svg", do: name, else: name <> ".svg"
  end

  defp used_sprite_ids(assets_dir, specs) do
    sprites =
      Enum.reduce(specs, MapSet.new(), fn
        {sprite, _, _, _, _, _, _, _, _, opts}, sprites ->
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
      |> Files.reduce_regular_files(ids_by_sprite, &collect_source_file/2)
    end
  end
end
