defmodule PhoenixAssetPipeline.HTML.ModuleClasses do
  @moduledoc false

  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config

  @mapping_file "module_class_mappings.term"
  @scan_file "module_class_scan.term"
  @missing :__phoenix_asset_pipeline_module_classes_missing__

  @doc false
  def mapping_path do
    Path.join([Config.manifest_cache_dir(), project_app(), @mapping_file])
  end

  @doc false
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

  @doc false
  def prepare!(mode \\ :deterministic) when mode in [:deterministic, :stable] do
    path = mapping_path()

    :global.trans(
      {{__MODULE__, path}, self()},
      fn -> prepare_locked(path, mode) end,
      [node()],
      :infinity
    )
  end

  @doc false
  def fixed_mappings!(class_names) when is_list(class_names) do
    class_names = class_names |> Enum.uniq() |> Enum.sort()
    mappings = current_mappings()

    Map.new(class_names, fn class_name -> {class_name, Map.fetch!(mappings, class_name)} end)
  end

  defp add_class_count(class_name, counts) do
    Map.update(counts, class_name, 1, &(&1 + 1))
  end

  defp allocate_class(class_name, {mappings, short_names}) do
    case mappings do
      %{^class_name => _} -> {mappings, short_names}
      _ -> put_allocated_class(class_name, class_base(class_name), mappings, short_names, 0)
    end
  end

  defp build_mappings(counts, previous, :stable) do
    seed = Map.filter(previous, fn {class_name, _} -> Map.has_key?(counts, class_name) end)
    allocate_mappings(counts, seed)
  end

  defp build_mappings(counts, _, :deterministic) do
    allocate_mappings(counts, %{})
  end

  defp allocate_mappings(counts, seed) do
    short_names = reverse_mappings!(seed)

    counts
    |> Enum.sort_by(fn {class_name, count} -> {-count, class_name} end)
    |> Enum.reduce({seed, short_names}, fn {class_name, _}, state ->
      allocate_class(class_name, state)
    end)
    |> elem(0)
  end

  defp class_base("phx-" <> _ = class_name) do
    case split_variant(class_name) do
      {variant, utility} -> variant <> ":" <> prefix(utility)
      :error -> class_name
    end
  end

  defp class_base(class_name), do: prefix(class_name)

  defp class_call_args({:class, _, args}) when is_list(args), do: args

  defp class_call_args({{:., _, [{:__aliases__, _, [:PhoenixAssetPipeline, :HTML, :Macros]}, :class]}, _, args})
       when is_list(args), do: args

  defp class_call_args(_), do: nil

  defp class_entry_counts({:{}, _, [truthy, falsy, condition]}, counts) do
    choice_counts(truthy, falsy, condition, counts)
  end

  defp class_entry_counts({truthy, falsy, condition}, counts) do
    choice_counts(truthy, falsy, condition, counts)
  end

  defp class_entry_counts({classes, condition}, counts) do
    conditional_counts(classes, condition, counts)
  end

  defp class_entry_counts(classes, counts) do
    if literal_group?(classes), do: class_group_counts(classes, counts), else: counts
  end

  defp class_group_counts(classes, counts) when is_binary(classes) do
    class_group_counts(classes, 0, 0, byte_size(classes), counts)
  end

  defp class_group_counts([class | classes], counts) do
    class_group_counts(classes, class_group_counts(class, counts))
  end

  defp class_group_counts(_, counts), do: counts

  defp class_group_counts(classes, index, start, size, counts) when index < size do
    if class_whitespace?(:binary.at(classes, index)) do
      counts =
        if index == start,
          do: counts,
          else: add_class_count(binary_part(classes, start, index - start), counts)

      next = skip_class_whitespace(classes, index + 1, size)
      class_group_counts(classes, next, next, size, counts)
    else
      class_group_counts(classes, index + 1, start, size, counts)
    end
  end

  defp class_group_counts(_, size, size, size, counts), do: counts

  defp class_group_counts(classes, size, start, size, counts) do
    add_class_count(binary_part(classes, start, size - start), counts)
  end

  defp class_whitespace?(byte), do: byte in [?\s, ?\t, ?\n, ?\r, ?\f]

  defp skip_class_whitespace(classes, index, size) when index < size do
    if class_whitespace?(:binary.at(classes, index)),
      do: skip_class_whitespace(classes, index + 1, size),
      else: index
  end

  defp skip_class_whitespace(_, index, _), do: index

  defp choice_counts(truthy, falsy, condition, counts) do
    if literal_group?(truthy) and literal_group?(falsy),
      do: valid_choice_counts(truthy, falsy, condition, counts),
      else: counts
  end

  defp valid_choice_counts(truthy, _, true, counts), do: class_group_counts(truthy, counts)

  defp valid_choice_counts(_, falsy, condition, counts) when condition in [false, nil] do
    class_group_counts(falsy, counts)
  end

  defp valid_choice_counts(truthy, falsy, {_, _, _}, counts) do
    counts = class_group_counts(truthy, counts)
    class_group_counts(falsy, counts)
  end

  defp valid_choice_counts(_, _, _, counts), do: counts

  defp conditional_counts(classes, true, counts) do
    if literal_group?(classes), do: class_group_counts(classes, counts), else: counts
  end

  defp conditional_counts(classes, {_, _, _}, counts), do: conditional_counts(classes, true, counts)
  defp conditional_counts(_, _, counts), do: counts

  defp current_mappings do
    key = persistent_key(mapping_path())

    case :persistent_term.get(key, @missing) do
      @missing -> load_mapping_cache(key)
      mappings -> mappings
    end
  end

  defp decode_mapping_cache(mappings) when is_map(mappings) do
    if valid_mappings?(mappings), do: {:ok, mappings}, else: :error
  end

  defp decode_mapping_cache(_), do: :error

  defp decode_scan_cache(files) when is_map(files), do: {:ok, files}
  defp decode_scan_cache(_), do: :error

  defp file_counts(path, cached_files) do
    content = File.read!(path)
    signature = file_signature(content)

    case cached_files do
      %{^path => {^signature, counts}} when is_map(counts) ->
        {{signature, counts}, counts}

      _ ->
        counts = content |> Code.string_to_quoted!(file: path) |> scan_ast(%{})
        {{signature, counts}, counts}
    end
  end

  defp file_signature(content), do: :erlang.md5(content)

  defp literal_group?(value) when value in [false, nil], do: true
  defp literal_group?(value) when is_binary(value), do: true
  defp literal_group?(values) when is_list(values), do: Enum.all?(values, &literal_group?/1)
  defp literal_group?(_), do: false

  defp load_mapping_cache(key) do
    mappings = Cache.read_term(mapping_path(), %{}, &decode_mapping_cache/1)
    :persistent_term.put(key, mappings)
    mappings
  end

  defp persistent_key(path), do: {__MODULE__, path}

  defp project_app do
    app = if config = mix_project_config(), do: config[:app]

    to_string(app || Config.otp_app())
  end

  defp mix_project_config do
    if Code.ensure_loaded?(Mix.Project) do
      case Mix.Project.config() do
        [] -> nil
        config -> config
      end
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp prefix(class_name) do
    class_name
    |> AnyAscii.transliterate()
    |> prefix_char()
  end

  defp prefix_char([char | _]) when char in ?a..?z, do: <<char>>
  defp prefix_char([char | _]) when char in ?A..?Z, do: <<char + 32>>
  defp prefix_char([_ | rest]), do: prefix_char(rest)
  defp prefix_char(_), do: "c"

  defp prepare_locked(path, mode) do
    scan_path = Path.join(Path.dirname(path), @scan_file)
    old_files = Cache.read_term(scan_path, %{}, &decode_scan_cache/1)
    old_mappings = Cache.read_term(path, %{}, &decode_mapping_cache/1)

    {files, counts} = scan_sources(old_files)
    mappings = build_mappings(counts, old_mappings, mode)
    scan_changed? = old_files != files or not File.regular?(scan_path)
    mappings_changed? = old_mappings != mappings or not File.regular?(path)

    if scan_changed?, do: Cache.write_term!(scan_path, files)
    if mappings_changed?, do: Cache.write_term!(path, mappings)

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

  defp put_allocated_class(class_name, base, mappings, short_names, count) do
    short_name = if count == 0, do: base, else: base <> Integer.to_string(count)

    case short_names do
      %{^short_name => ^class_name} -> {Map.put(mappings, class_name, short_name), short_names}
      %{^short_name => _} -> put_allocated_class(class_name, base, mappings, short_names, count + 1)
      _ -> {Map.put(mappings, class_name, short_name), Map.put(short_names, short_name, class_name)}
    end
  end

  defp reverse_mappings!(mappings) do
    Enum.reduce(mappings, %{}, fn {class_name, short_name}, short_names ->
      case short_names do
        %{^short_name => other} when other != class_name ->
          raise "fixed class collision: #{inspect(short_name)} maps both #{inspect(other)} and #{inspect(class_name)}"

        _ ->
          Map.put(short_names, short_name, class_name)
      end
    end)
  end

  defp scan_ast({form, _, _}, counts) when form in [:def, :defp, :defmacro, :defmacrop, :defguard, :defguardp] do
    counts
  end

  defp scan_ast({:quote, _, _}, counts), do: counts

  defp scan_ast(ast, counts) when is_tuple(ast) do
    case class_call_args(ast) do
      [classes | _] -> scan_class_entries(classes, counts)
      _ -> ast |> Tuple.to_list() |> scan_ast(counts)
    end
  end

  defp scan_ast([node | nodes], counts), do: scan_ast(nodes, scan_ast(node, counts))
  defp scan_ast([], counts), do: counts
  defp scan_ast(_, counts), do: counts

  defp scan_class_entries(classes, counts) when is_list(classes) do
    Enum.reduce(classes, counts, &class_entry_counts/2)
  end

  defp scan_class_entries(classes, counts), do: class_entry_counts(classes, counts)

  defp scan_sources(cached_files) do
    Enum.reduce(source_files(), {%{}, %{}}, fn path, {files, counts} ->
      {record, file_counts} = file_counts(path, cached_files)
      files = Map.put(files, path, record)
      counts = Map.merge(counts, file_counts, fn _, left, right -> left + right end)
      {files, counts}
    end)
  end

  defp source_files do
    paths =
      if config = mix_project_config(),
        do: config[:elixirc_paths] || ["lib"],
        else: ["lib"]

    paths
    |> Enum.flat_map(&Path.wildcard(Path.join(Path.expand(&1), "**/*.ex")))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp split_variant(class_name) do
    case :binary.match(class_name, ":") do
      {index, 1} when index + 1 < byte_size(class_name) ->
        {
          binary_part(class_name, 0, index),
          binary_part(class_name, index + 1, byte_size(class_name) - index - 1)
        }

      _ ->
        :error
    end
  end

  defp valid_mappings?(mappings) do
    Enum.all?(mappings, fn {class_name, short_name} ->
      is_binary(class_name) and is_binary(short_name)
    end) and map_size(reverse_mappings!(mappings)) == map_size(mappings)
  rescue
    _ -> false
  end
end
