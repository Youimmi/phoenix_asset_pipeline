defmodule PhoenixAssetPipeline.HTML.ModuleClasses do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.ClassNames
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files

  @mapping_file "module_class_mappings.term"
  @scan_file "module_class_scan.term"
  @missing :__phoenix_asset_pipeline_module_classes_missing__

  def ensure_prepared! do
    path = mapping_path()
    key = persistent_key(path)

    case :persistent_term.get(key, @missing) do
      @missing ->
        :global.trans(
          {{__MODULE__, path}, self()},
          fn -> prepare_missing_locked(path, key) end,
          [node()],
          :infinity
        )

      _ ->
        :current
    end
  end

  def fixed_mappings!(class_names) when is_list(class_names) do
    class_names = Enum.uniq(class_names)
    mappings = Map.take(current_mappings(), class_names)

    if map_size(mappings) == length(class_names) do
      mappings
    else
      prepare!(:stable)
      mappings = current_mappings()
      Map.new(class_names, fn class_name -> {class_name, Map.fetch!(mappings, class_name)} end)
    end
  end

  def mapping_path do
    Path.join([Config.manifest_cache_dir(), project_app(), @mapping_file])
  end

  def prepare!(mode \\ :deterministic) when mode in [:deterministic, :stable] do
    path = mapping_path()

    :global.trans(
      {{__MODULE__, path}, self()},
      fn -> prepare_locked(path, mode) end,
      [node()],
      :infinity
    )
  end

  defp allocate_class(class_name, {mappings, _, _} = allocation) do
    case mappings do
      %{^class_name => _} -> allocation
      _ -> class_name |> class_base() |> ClassNames.allocate(class_name, allocation) |> elem(1)
    end
  end

  defp allocate_mappings(counts, seed) do
    counts
    |> Enum.sort_by(fn {class_name, count} -> {-count, class_name} end)
    |> Enum.reduce(ClassNames.new(seed), fn {class_name, _}, state ->
      allocate_class(class_name, state)
    end)
    |> elem(0)
  end

  defp build_mappings(counts, previous, :stable) do
    seed = Map.filter(previous, fn {class_name, _} -> Map.has_key?(counts, class_name) end)
    allocate_mappings(counts, seed)
  end

  defp build_mappings(counts, _, :deterministic) do
    allocate_mappings(counts, %{})
  end

  defp class_base("phx-" <> _ = class_name) do
    case ClassNames.variant(class_name) do
      {variant, utility} -> variant <> ":" <> ClassNames.prefix(utility)
      :error -> class_name
    end
  end

  defp class_base(class_name), do: ClassNames.prefix(class_name)

  defp class_call_args({:class, _, args}, _) when is_list(args), do: args

  defp class_call_args({{:., _, [{:__aliases__, _, parts}, :class]}, _, args}, aliases) when is_list(args) do
    if expand_alias(aliases, parts) == [:PhoenixAssetPipeline, :HTML, :Macros], do: args
  end

  defp class_call_args(_, _), do: nil

  defp class_entry_counts({:{}, _, [truthy, falsy, condition]}, counts) do
    cond do
      not (ClassNames.literal?(truthy) and ClassNames.literal?(falsy)) -> counts
      condition == true -> class_group_counts(truthy, counts)
      condition in [false, nil] -> class_group_counts(falsy, counts)
      match?({_, _, _}, condition) -> class_group_counts(falsy, class_group_counts(truthy, counts))
      true -> counts
    end
  end

  defp class_entry_counts({classes, condition}, counts) do
    if condition == true or match?({_, _, _}, condition),
      do: literal_counts(classes, counts),
      else: counts
  end

  defp class_entry_counts(classes, counts), do: literal_counts(classes, counts)

  defp class_group_counts(classes, counts) when is_binary(classes) do
    classes
    |> ClassNames.split()
    |> elem(0)
    |> Enum.reduce(counts, &Map.update(&2, &1, 1, fn count -> count + 1 end))
  end

  defp class_group_counts([class | classes], counts) do
    class_group_counts(classes, class_group_counts(class, counts))
  end

  defp class_group_counts(_, counts), do: counts

  defp current_mappings do
    key = persistent_key(mapping_path())

    case :persistent_term.get(key, @missing) do
      @missing -> load_mapping_cache(key)
      mappings -> mappings
    end
  end

  defp decode_mapping_cache({fingerprint, mappings}) when is_map(mappings) do
    if fingerprint == mapping_fingerprint() and valid_mappings?(mappings), do: {:ok, mappings}, else: :error
  end

  defp decode_mapping_cache(_), do: :error

  defp decode_scan_cache(files) when is_map(files), do: {:ok, files}
  defp decode_scan_cache(_), do: :error

  defp expand_alias(aliases, [first | rest]), do: Map.get(aliases, first, [first]) ++ rest

  defp file_counts(path, stat, cached_files, now) do
    signature = {stat.size, stat.mtime, stat.ctime, stat.inode, stat.major_device}

    case cached_files do
      %{^path => {^signature, counts}} when is_map(counts) ->
        {{signature, counts}, counts}

      _ ->
        {counts, _} = path |> File.read!() |> Code.string_to_quoted!(file: path) |> scan_ast({%{}, %{}})
        settled? = stat.inode != 0 and max(stat.mtime, stat.ctime) < now
        {{if(settled?, do: signature, else: :unsettled), counts}, counts}
    end
  end

  defp literal_counts(classes, counts) do
    if ClassNames.literal?(classes), do: class_group_counts(classes, counts), else: counts
  end

  defp load_mapping_cache(key) do
    mappings = Cache.read_term(mapping_path(), %{}, &decode_mapping_cache/1)
    :persistent_term.put(key, mappings)
    mappings
  end

  defp mapping_fingerprint, do: Digest.term({__MODULE__.module_info(:md5), ClassNames.module_info(:md5)})

  defp persistent_key(path), do: {__MODULE__, path, mapping_fingerprint()}

  defp prepare_locked(path, mode) do
    scan_path = Path.join(Path.dirname(path), @scan_file)
    old_files = Cache.read_term(scan_path, %{}, &decode_scan_cache/1)
    old_mappings = Cache.read_term(path, %{}, &decode_mapping_cache/1)

    {files, counts} = scan_sources(old_files)
    mappings = build_mappings(counts, old_mappings, mode)
    scan_changed? = old_files != files or not File.regular?(scan_path)
    mappings_changed? = old_mappings != mappings or not File.regular?(path)

    if scan_changed?, do: Cache.write_term!(scan_path, files)
    if mappings_changed?, do: Cache.write_term!(path, {mapping_fingerprint(), mappings})

    key = persistent_key(path)

    if :persistent_term.get(key, @missing) != mappings do
      :persistent_term.put(key, mappings)
    end

    if scan_changed? or mappings_changed?, do: :updated, else: :current
  end

  defp prepare_missing_locked(path, key) do
    if File.regular?(path) do
      _ = load_mapping_cache(key)
      :current
    else
      prepare_locked(path, :stable)
    end
  end

  defp project_app, do: to_string(Config.mix_project(& &1[:app]) || Config.otp_app())

  defp put_alias(aliases, directive, parts, opts) do
    name =
      case opts do
        [[_ | _] = options] ->
          case options[:as] do
            {:__aliases__, _, [as]} -> as
            _ -> nil
          end

        _ ->
          nil
      end

    cond do
      name -> Map.put(aliases, name, expand_alias(aliases, parts))
      directive == :alias -> Map.put(aliases, List.last(parts), expand_alias(aliases, parts))
      true -> aliases
    end
  end

  defp scan_ast({form, _, _}, acc) when form in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp, :quote] do
    acc
  end

  defp scan_ast({:defmodule, _, [_, [do: body]]}, {_, aliases} = acc) do
    {counts, _} = scan_ast(body, acc)
    {counts, aliases}
  end

  defp scan_ast({directive, _, [{:__aliases__, _, parts} | opts]}, {counts, aliases})
       when directive in [:alias, :require] do
    {counts, put_alias(aliases, directive, parts, opts)}
  end

  defp scan_ast({:alias, _, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children}]}, {counts, aliases}) do
    {counts,
     Enum.reduce(children, aliases, fn
       {:__aliases__, _, parts}, aliases -> put_alias(aliases, :alias, base ++ parts, [])
       part, aliases when is_atom(part) -> put_alias(aliases, :alias, base ++ [part], [])
       _, aliases -> aliases
     end)}
  end

  defp scan_ast({:fn, _, clauses}, {counts, aliases}) do
    {Enum.reduce(clauses, counts, &(&1 |> scan_ast({&2, aliases}) |> elem(0))), aliases}
  end

  defp scan_ast({callee, meta, [_ | _] = args} = ast, {counts, aliases} = acc) do
    case {class_call_args(ast, aliases), List.last(args)} do
      {[classes | _], _} ->
        {scan_class_entries(classes, counts), aliases}

      {_, [{:do, _} | _] = blocks} ->
        {counts, _} = scan_ast([callee, meta | Enum.drop(args, -1)], acc)
        {Enum.reduce(blocks, counts, &(&1 |> elem(1) |> scan_ast({&2, aliases}) |> elem(0))), aliases}

      _ ->
        ast |> Tuple.to_list() |> scan_ast(acc)
    end
  end

  defp scan_ast(ast, {counts, aliases} = acc) when is_tuple(ast) do
    case class_call_args(ast, aliases) do
      [classes | _] -> {scan_class_entries(classes, counts), aliases}
      _ -> ast |> Tuple.to_list() |> scan_ast(acc)
    end
  end

  defp scan_ast([node | nodes], acc), do: scan_ast(nodes, scan_ast(node, acc))
  defp scan_ast(_, acc), do: acc

  defp scan_class_entries(classes, counts) when is_list(classes) do
    Enum.reduce(classes, counts, &class_entry_counts/2)
  end

  defp scan_class_entries(classes, counts), do: class_entry_counts(classes, counts)

  defp scan_source(path, stat, {files, counts} = acc, cached_files, now) do
    if Path.extname(path) == ".ex" and not is_map_key(files, path) do
      {record, file_counts} = file_counts(path, stat, cached_files, now)
      {Map.put(files, path, record), Map.merge(counts, file_counts, fn _, left, right -> left + right end)}
    else
      acc
    end
  end

  defp scan_sources(cached_files) do
    now = System.os_time(:second)

    (Config.mix_project(& &1[:elixirc_paths]) || ["lib"])
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.reduce(
      {%{}, %{}},
      &Files.reduce_regular_files(&1, &2, fn path, stat, acc -> scan_source(path, stat, acc, cached_files, now) end)
    )
  end

  defp valid_mappings?(mappings) do
    Enum.all?(mappings, fn {class_name, short_name} ->
      is_binary(class_name) and is_binary(short_name)
    end) and map_size(ClassNames.reverse!(mappings)) == map_size(mappings)
  rescue
    _ -> false
  end
end
