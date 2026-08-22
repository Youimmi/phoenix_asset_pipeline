defmodule PhoenixAssetPipeline.Manifest do
  @moduledoc """
  Runtime storage for the asset manifest.

  Without a precompiled manifest, indexed generations are stored in ETS behind
  this GenServer. In production, a generated
  `PhoenixAssetPipeline.Manifest.Precompiled` module provides one immutable
  manifest literal.
  """
  use GenServer

  alias PhoenixAssetPipeline.Config

  @precompiled? Config.manifest_mode() == :precompiled
  @precompiled_module Module.concat(__MODULE__, Precompiled)
  @manifest_cache_file "asset_manifest.term"
  @snapshot_missing :__phoenix_asset_pipeline_manifest_snapshot_missing__

  if not @precompiled? do
    @snapshot_key {__MODULE__, :snapshot}
    @storage_missing :__phoenix_asset_pipeline_manifest_storage_missing__
  end

  if @precompiled? do
    @compile {:no_warn_undefined, {@precompiled_module, :manifest, 0}}

    @doc false
    def start_link(_) do
      ensure_precompiled!()
      :ignore
    end

    @impl true
    def init(_), do: {:ok, nil}

    @doc """
    Reads a manifest value by key.
    """
    def get(term, default \\ nil)

    def get(:manifest, _default), do: @precompiled_module.manifest()

    def get(term, default) do
      :maps.get(term, @precompiled_module.manifest(), default)
    end

    @doc """
    Reads a nested manifest value by section and key.
    """
    def find(term, key) do
      case :maps.get(term, @precompiled_module.manifest(), nil) do
        section when is_map(section) -> Map.get(section, key)
        _ -> nil
      end
    end

    @doc false
    def put(manifest) when is_map(manifest), do: raise("the precompiled asset manifest is immutable")

    @doc false
    def put_compile_manifest(manifest) when is_map(manifest), do: put(manifest)

    defp ensure_precompiled! do
      if precompiled_module_loaded?() do
        :ok
      else
        raise """
        missing precompiled asset manifest module #{inspect(@precompiled_module)}

        Run `MIX_ENV=prod mix compile` before building the release.
        """
      end
    end

    defp precompiled_module_loaded? do
      Code.ensure_loaded?(@precompiled_module) and function_exported?(@precompiled_module, :manifest, 0)
    end

    @doc false
    def precompiled_loaded?, do: precompiled_module_loaded?()
  else
    @current_generation_key :__phoenix_asset_pipeline_manifest_current_generation__

    @doc false
    def start_link(_) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_) do
      _ = :ets.new(__MODULE__, [:named_table, :protected, read_concurrency: true])

      state = %{
        generation: nil,
        generation_refs: %{},
        holders: %{},
        retired: MapSet.new()
      }

      {:ok, load_initial_manifest(state)}
    end

    @doc """
    Reads a manifest value by key.
    """
    def get(term, default \\ nil)

    def get(:manifest, default), do: read_manifest(default)

    def get(term, default) do
      case snapshot() do
        @snapshot_missing -> current_get(term, default)
        {:generation, generation} -> generation_get(generation, term, default)
        {:literal, manifest} -> Map.get(manifest, term, default)
        nil -> default
      end
    end

    @doc """
    Reads a nested manifest value by section and key.
    """
    def find(term, key) do
      case snapshot() do
        @snapshot_missing -> current_find(term, key)
        {:generation, generation} -> generation_find(generation, term, key)
        {:literal, manifest} -> map_find(manifest, term, key)
        nil -> nil
      end
    end

    @doc """
    Replaces the stored manifest.
    """
    def put(manifest) when is_map(manifest) do
      GenServer.call(__MODULE__, {:put, manifest})
    end

    @doc false
    def put_compile_manifest(manifest) when is_map(manifest) do
      if Process.whereis(__MODULE__) do
        try do
          put(manifest)
        catch
          :exit, _ -> :ok
        end
      else
        :ok
      end
    end

    @impl true
    def handle_call({:put, manifest}, _, state) do
      {:reply, :ok, replace_manifest(state, manifest)}
    end

    def handle_call(:acquire_snapshot, _, %{generation: nil} = state) do
      {:reply, nil, state}
    end

    def handle_call(:acquire_snapshot, {pid, _}, state) do
      generation = state.generation
      {:reply, {:generation, generation}, acquire_generation(state, pid, generation)}
    end

    def handle_call({:release_snapshot, generation}, {pid, _}, state) do
      {:reply, :ok, release_generation(state, pid, generation)}
    end

    @impl true
    def handle_info({:DOWN, ref, :process, pid, _}, state) do
      {:noreply, release_holder(state, pid, ref)}
    end

    @cold_cache_key {__MODULE__, :cold_cache}

    @doc false
    def cached_loaded? do
      case read_cached_manifest() do
        :error ->
          false

        manifest ->
          :persistent_term.put(@cold_cache_key, manifest)
          true
      end
    end

    defp load_initial_manifest(state) do
      replace_manifest(state, cold_manifest())
    end

    defp read_cached_manifest do
      PhoenixAssetPipeline.Cache.read_term(cache_path(), :error, fn
        manifest when is_map(manifest) ->
          if valid?(manifest), do: {:ok, manifest}, else: :error

        _ ->
          :error
      end)
    end

    defp read_cached_manifest! do
      case read_cached_manifest() do
        :error -> raise "missing or invalid cached asset manifest #{cache_path()}; run `mix compile`"
        manifest -> manifest
      end
    end

    defp cold_manifest do
      case :persistent_term.get(@cold_cache_key, @storage_missing) do
        @storage_missing ->
          manifest = read_cached_manifest!()
          :persistent_term.put(@cold_cache_key, manifest)
          manifest

        manifest ->
          manifest
      end
    end

    defp cold_find(term, key), do: map_find(cold_manifest(), term, key)
    defp cold_get(term, default), do: Map.get(cold_manifest(), term, default)
    defp cold_manifest_value(_default), do: cold_manifest()
    defp cold_snapshot, do: {:literal, cold_manifest()}

    defp acquire_generation(state, pid, generation) do
      {monitor, generations} =
        case Map.get(state.holders, pid) do
          nil -> {Process.monitor(pid), %{}}
          holder -> holder
        end

      holder = {monitor, Map.update(generations, generation, 1, &(&1 + 1))}

      %{
        state
        | generation_refs: Map.update(state.generation_refs, generation, 1, &(&1 + 1)),
          holders: Map.put(state.holders, pid, holder)
      }
    end

    defp capture_snapshot do
      if Process.whereis(__MODULE__) do
        try do
          GenServer.call(__MODULE__, :acquire_snapshot)
        catch
          :exit, _ -> cold_snapshot()
        end
      else
        cold_snapshot()
      end
    end

    defp cleanup_retired(state) do
      retired =
        Enum.reduce(state.retired, state.retired, fn generation, retired ->
          if Map.get(state.generation_refs, generation, 0) == 0 do
            delete_generation(generation)
            MapSet.delete(retired, generation)
          else
            retired
          end
        end)

      %{state | retired: retired}
    end

    defp current_find(term, key) do
      case current_generation() do
        @storage_missing ->
          cold_find(term, key)

        generation ->
          value = generation_find(generation, term, key)

          if current_generation() == generation,
            do: value,
            else: current_find(term, key)
      end
    end

    defp current_generation do
      lookup_element(@current_generation_key, @storage_missing)
    end

    defp current_get(term, default) do
      case current_generation() do
        @storage_missing ->
          cold_get(term, default)

        generation ->
          value = generation_get(generation, term, default)

          if current_generation() == generation,
            do: value,
            else: current_get(term, default)
      end
    end

    defp current_manifest(default) do
      case current_generation() do
        @storage_missing ->
          cold_manifest_value(default)

        generation ->
          manifest = generation_manifest(generation)

          if current_generation() == generation,
            do: manifest,
            else: current_manifest(default)
      end
    end

    defp decrement_count(counts, key, amount) do
      case Map.fetch!(counts, key) - amount do
        0 -> Map.delete(counts, key)
        count -> Map.put(counts, key, count)
      end
    end

    defp delete_generation(generation) do
      :ets.match_delete(__MODULE__, {{generation, :_}, :_})
      :ets.match_delete(__MODULE__, {{generation, :_, :_}, :_})
    end

    defp generation_find(generation, term, key) do
      case lookup_element({generation, term, key}, @storage_missing) do
        @storage_missing ->
          case lookup_element({generation, term}, @storage_missing) do
            {:value, section} when is_map(section) -> Map.get(section, key)
            _ -> nil
          end

        value ->
          value
      end
    end

    defp generation_get(generation, term, default) do
      case lookup_element({generation, term}, @storage_missing) do
        :map -> generation_section(generation, term)
        {:value, value} -> value
        @storage_missing -> default
      end
    end

    defp generation_manifest(generation) do
      manifest =
        __MODULE__
        |> :ets.match_object({{generation, :_}, :_})
        |> Map.new(fn
          {{^generation, term}, :map} -> {term, %{}}
          {{^generation, term}, {:value, value}} -> {term, value}
        end)

      __MODULE__
      |> :ets.match_object({{generation, :_, :_}, :_})
      |> Enum.reduce(manifest, fn {{^generation, term, key}, value}, manifest ->
        Map.put(manifest, term, Map.put(Map.fetch!(manifest, term), key, value))
      end)
    rescue
      ArgumentError -> %{}
    end

    defp generation_objects(manifest, generation) do
      Enum.reduce(manifest, [], fn {term, value}, objects ->
        if is_map(value) and (indexed_section?(term) or map_size(value) > 16) do
          objects =
            Enum.reduce(value, objects, fn {key, entry}, objects ->
              [{{generation, term, key}, entry} | objects]
            end)

          [{{generation, term}, :map} | objects]
        else
          [{{generation, term}, {:value, value}} | objects]
        end
      end)
    end

    defp indexed_section?(term) do
      term in [
        :class_descriptors,
        :classes,
        :image_sources,
        :images,
        :script_tags,
        :scripts,
        :static_files,
        :style_tags
      ]
    end

    defp generation_section(generation, term) do
      __MODULE__
      |> :ets.match_object({{generation, term, :_}, :_})
      |> Map.new(fn {{^generation, ^term, key}, value} -> {key, value} end)
    rescue
      ArgumentError -> %{}
    end

    defp lookup_element(key, default) do
      :ets.lookup_element(__MODULE__, key, 2, default)
    rescue
      ArgumentError -> default
    end

    defp map_find(manifest, term, key) do
      case Map.get(manifest, term) do
        section when is_map(section) -> Map.get(section, key)
        _ -> nil
      end
    end

    defp read_manifest(default) do
      case snapshot() do
        @snapshot_missing -> current_manifest(default)
        {:generation, generation} -> generation_manifest(generation)
        {:literal, manifest} -> manifest
        nil -> default
      end
    end

    defp release_generation(state, pid, generation) do
      case Map.get(state.holders, pid) do
        {monitor, generations} ->
          case Map.get(generations, generation, 0) do
            0 -> state
            _ -> update_released_generation(state, pid, monitor, generations, generation)
          end

        nil ->
          state
      end
    end

    defp release_holder(state, pid, ref) do
      case Map.get(state.holders, pid) do
        {^ref, generations} ->
          generation_refs =
            Enum.reduce(generations, state.generation_refs, fn {generation, count}, refs ->
              decrement_count(refs, generation, count)
            end)

          state
          |> Map.put(:generation_refs, generation_refs)
          |> Map.put(:holders, Map.delete(state.holders, pid))
          |> cleanup_retired()

        _ ->
          state
      end
    end

    defp release_snapshot({:generation, generation}) do
      if Process.whereis(__MODULE__) do
        try do
          GenServer.call(__MODULE__, {:release_snapshot, generation})
        catch
          :exit, _ -> :ok
        end
      else
        :ok
      end
    end

    defp release_snapshot(_), do: :ok

    defp replace_manifest(state, manifest) do
      generation = System.unique_integer([:monotonic, :positive])
      true = :ets.insert(__MODULE__, generation_objects(manifest, generation))
      true = :ets.insert(__MODULE__, {@current_generation_key, generation})

      retired =
        case state.generation do
          nil -> state.retired
          previous -> MapSet.put(state.retired, previous)
        end

      cleanup_retired(%{state | generation: generation, retired: retired})
    end

    defp snapshot, do: Process.get(@snapshot_key, @snapshot_missing)

    defp update_released_generation(state, pid, monitor, generations, generation) do
      generations = decrement_count(generations, generation, 1)
      generation_refs = decrement_count(state.generation_refs, generation, 1)

      holders =
        if map_size(generations) == 0 do
          Process.demonitor(monitor, [:flush])
          Map.delete(state.holders, pid)
        else
          Map.put(state.holders, pid, {monitor, generations})
        end

      cleanup_retired(%{state | generation_refs: generation_refs, holders: holders})
    end
  end

  if @precompiled? do
    @doc false
    def put_snapshot, do: @snapshot_missing

    @doc false
    def put_snapshot(_), do: @snapshot_missing

    @doc false
    def restore_snapshot(_), do: :ok
  else
    @doc """
    Captures the current manifest generation for process-local consistent reads.
    """
    def put_snapshot do
      previous = Process.get(@snapshot_key, @snapshot_missing)
      Process.put(@snapshot_key, capture_snapshot())
      previous
    end

    @doc """
    Temporarily overrides the process-local manifest snapshot.
    """
    def put_snapshot(manifest) do
      previous = Process.get(@snapshot_key, @snapshot_missing)
      Process.put(@snapshot_key, if(is_map(manifest), do: {:literal, manifest}))
      previous
    end

    @doc """
    Restores a manifest snapshot returned by `put_snapshot/0` or `put_snapshot/1`.
    """
    def restore_snapshot(previous) do
      current = Process.get(@snapshot_key, @snapshot_missing)

      if previous == @snapshot_missing,
        do: Process.delete(@snapshot_key),
        else: Process.put(@snapshot_key, previous)

      release_snapshot(current)
      :ok
    end
  end

  @doc false
  def valid?(%{
        class_descriptors: class_descriptors,
        classes: classes,
        csp_directives: csp_directives,
        digest: digest,
        early_hints_preloads: early_hints_preloads,
        image_sources: image_sources,
        images: images,
        scripts: scripts,
        script_tags: script_tags,
        signature: signature,
        static_files: static_files,
        static_signature: static_signature,
        style_tags: style_tags
      }) do
    manifest_metadata_valid?(digest, signature, static_signature, early_hints_preloads) and
      manifest_classes_valid?(classes, class_descriptors) and
      manifest_assets_valid?(images, image_sources, scripts, script_tags, style_tags, static_files, csp_directives)
  end

  def valid?(_), do: false

  @doc """
  Writes the manifest as a generated BEAM module for production releases.
  """
  def save_precompiled!(manifest, path \\ precompiled_beam_path()) when is_map(manifest) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    PhoenixAssetPipeline.Cache.write_atomic!(path, precompiled_beam!(manifest))
    register_precompiled_module!(path)

    path
  end

  if @precompiled? do
    def save_cached(_), do: raise("cached manifests are disabled in :precompiled mode")
  else
    def save_cached(manifest) when is_map(manifest) do
      PhoenixAssetPipeline.Cache.write_term!(cache_path(), manifest)
      :persistent_term.put({__MODULE__, :cold_cache}, manifest)

      :ok
    end
  end

  @doc """
  Returns the cache file path used in `:cached` manifest mode.
  """
  def cache_path do
    Path.join(Config.manifest_cache_dir(), @manifest_cache_file)
  end

  defp precompiled_beam_path do
    __MODULE__
    |> :code.which()
    |> List.to_string()
    |> Path.dirname()
    |> Path.join(to_string(@precompiled_module) <> ".beam")
  end

  defp register_precompiled_module!(beam_path) do
    app_file =
      beam_path
      |> Path.dirname()
      |> Path.join("phoenix_asset_pipeline.app")

    if File.regular?(app_file) do
      {:ok, [{:application, :phoenix_asset_pipeline, properties}]} =
        app_file
        |> String.to_charlist()
        |> :file.consult()

      modules =
        properties
        |> Keyword.get(:modules, [])
        |> then(&[@precompiled_module | &1])
        |> Enum.uniq()
        |> Enum.sort()

      properties = Keyword.put(properties, :modules, modules)
      application = {:application, :phoenix_asset_pipeline, properties}

      PhoenixAssetPipeline.Cache.write_atomic!(
        app_file,
        IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [application]))
      )
    end
  end

  defp manifest_metadata_valid?(digest, signature, static_signature, early_hints_preloads) do
    is_binary(digest) and
      is_binary(signature) and
      is_binary(static_signature) and
      binaries_valid?(early_hints_preloads)
  end

  defp manifest_classes_valid?(classes, class_descriptors) do
    classes_valid?(classes) and class_descriptors_valid?(class_descriptors)
  end

  defp manifest_assets_valid?(images, image_sources, scripts, script_tags, style_tags, static_files, csp_directives) do
    encoded_assets_valid?(images) and
      image_sources_valid?(image_sources) and
      encoded_assets_valid?(scripts) and
      script_tags_valid?(script_tags) and
      style_tags_valid?(style_tags) and
      static_files_valid?(static_files) and
      csp_directives_valid?(csp_directives)
  end

  defp classes_valid?(classes) when is_map(classes) do
    Enum.all?(classes, fn
      {class_name, short_name} when is_binary(class_name) and is_binary(short_name) -> true
      _ -> false
    end)
  end

  defp classes_valid?(_), do: false

  defp class_descriptors_valid?(descriptors) when is_map(descriptors) do
    Enum.all?(descriptors, fn
      {{:string, hash}, {:precomputed, strings}} when is_binary(hash) and is_tuple(strings) ->
        size = tuple_size(strings)
        size > 0 and tuple_binaries_valid?(strings, 0, size)

      {{:attr, hash}, {:precomputed, lists}} when is_binary(hash) and is_tuple(lists) ->
        size = tuple_size(lists)
        size > 0 and tuple_binary_lists_valid?(lists, 0, size)

      {{kind, hash}, {:compact, entries}} when kind in [:string, :attr] and is_binary(hash) and is_list(entries) ->
        class_descriptor_entries_valid?(entries)

      _ ->
        false
    end)
  end

  defp class_descriptors_valid?(_), do: false

  defp class_descriptor_entries_valid?([{class_name, condition} | entries])
       when is_binary(class_name) and is_integer(condition) do
    class_descriptor_entries_valid?(entries)
  end

  defp class_descriptor_entries_valid?([]), do: true
  defp class_descriptor_entries_valid?(_), do: false

  defp tuple_binaries_valid?(_, size, size), do: true

  defp tuple_binaries_valid?(tuple, index, size) when is_binary(elem(tuple, index)) do
    tuple_binaries_valid?(tuple, index + 1, size)
  end

  defp tuple_binaries_valid?(_, _, _), do: false

  defp tuple_binary_lists_valid?(_, size, size), do: true

  defp tuple_binary_lists_valid?(tuple, index, size) do
    case elem(tuple, index) do
      values when is_list(values) -> binaries_valid?(values) and tuple_binary_lists_valid?(tuple, index + 1, size)
      _ -> false
    end
  end

  defp encoded_assets_valid?(assets) when is_map(assets) do
    Enum.all?(assets, fn
      {_, %{content_type: content_type, data: data, digest: digest}}
      when is_binary(content_type) and is_map(data) and is_binary(digest) ->
        encoded_asset_data_valid?(data)

      _ ->
        false
    end)
  end

  defp encoded_assets_valid?(_), do: false

  defp encoded_asset_data_valid?(%{"raw" => raw} = data) do
    encoded_asset_entry_valid?(raw) and
      Enum.all?(data, fn
        {encoding, entry} when encoding in ["raw", "br", "deflate", "gzip", "zstd"] ->
          encoded_asset_entry_valid?(entry)

        _ ->
          false
      end)
  end

  defp encoded_asset_data_valid?(_), do: false

  defp encoded_asset_entry_valid?({content, stored_size})
       when is_binary(content) and is_integer(stored_size) and stored_size == byte_size(content), do: true

  defp encoded_asset_entry_valid?(_), do: false

  defp image_sources_valid?(sources) when is_map(sources) do
    Enum.all?(sources, fn
      {source_path, %{digest: digest, path: path, placeholder_class: class} = source} ->
        is_binary(source_path) and is_binary(digest) and is_binary(path) and is_binary(class) and
          map_size(source) == 3

      {source_path, %{digest: digest, path: path} = source} ->
        is_binary(source_path) and is_binary(digest) and is_binary(path) and map_size(source) == 2

      _ ->
        false
    end)
  end

  defp image_sources_valid?(_), do: false

  defp script_tags_valid?(tags) when is_map(tags) do
    Enum.all?(tags, fn
      {_, %{integrity: integrity, path: path}} when is_binary(integrity) and is_binary(path) -> true
      _ -> false
    end)
  end

  defp script_tags_valid?(_), do: false

  defp style_tags_valid?(tags) when is_map(tags) do
    Enum.all?(tags, fn
      {_, %{content: content, digest: digest, integrity: integrity}}
      when is_binary(content) and is_binary(digest) and is_binary(integrity) ->
        true

      _ ->
        false
    end)
  end

  defp style_tags_valid?(_), do: false

  defp static_files_valid?(static_files) when is_map(static_files) do
    Enum.all?(static_files, fn
      {_, %{data: data}} when is_map(data) -> encoded_static_data_valid?(data)
      _ -> false
    end)
  end

  defp static_files_valid?(_), do: false

  defp encoded_static_data_valid?(%{"raw" => raw} = data) do
    encoded_static_entry_valid?(raw) and
      Enum.all?(data, fn
        {encoding, entry} when encoding in ["raw", "br", "deflate", "gzip", "zstd"] ->
          encoded_static_entry_valid?(entry)

        _ ->
          false
      end)
  end

  defp encoded_static_data_valid?(_), do: false

  defp encoded_static_entry_valid?({content, stored_size, etag})
       when is_binary(content) and is_integer(stored_size) and stored_size == byte_size(content) and is_binary(etag),
       do: true

  defp encoded_static_entry_valid?(_), do: false

  defp csp_directives_valid?(%{"script-src" => script_src, "style-src" => style_src} = directives)
       when is_list(script_src) and is_list(style_src) do
    Enum.all?(directives, fn
      {directive, values} when is_binary(directive) and is_list(values) -> binaries_valid?(values)
      _ -> false
    end)
  end

  defp csp_directives_valid?(_), do: false

  defp binaries_valid?([value | values]) when is_binary(value), do: binaries_valid?(values)
  defp binaries_valid?([]), do: true
  defp binaries_valid?(_), do: false

  @dialyzer {:nowarn_function, precompiled_beam!: 1}
  defp precompiled_beam!(manifest) do
    module = @precompiled_module
    manifest_literal = :erl_parse.abstract(manifest)
    anno = 0

    forms = [
      {:attribute, anno, :module, module},
      {:attribute, anno, :export, [manifest: 0]},
      {:function, anno, :manifest, 0, [{:clause, anno, [], [], [manifest_literal]}]}
    ]

    case :compile.forms(forms, [:binary, :return_errors, :return_warnings, :no_debug_info]) do
      {:ok, ^module, binary} ->
        binary

      {:ok, ^module, binary, []} ->
        binary

      {:ok, ^module, _, warnings} ->
        raise "precompiled asset manifest compiled with warnings: #{inspect(warnings)}"

      {:error, errors, warnings} ->
        raise "could not compile precompiled asset manifest: #{inspect(errors: errors, warnings: warnings)}"
    end
  end
end
