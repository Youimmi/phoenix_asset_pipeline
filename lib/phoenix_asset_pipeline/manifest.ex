defmodule PhoenixAssetPipeline.Manifest do
  @moduledoc """
  Runtime storage for the asset manifest.

  Without a precompiled manifest, the manifest is stored in ETS behind this GenServer.
  In production, when `:precompiled_manifest` is enabled, a generated
  `PhoenixAssetPipeline.Manifest.Precompiled` module loads immutable manifest
  sections into `:persistent_term`.
  """
  use GenServer

  alias PhoenixAssetPipeline.Config

  @cache? Application.compile_env(:phoenix_asset_pipeline, :cache_manifest, false)
  @precompiled? Application.compile_env(:phoenix_asset_pipeline, :precompiled_manifest, false)
  @precompiled_module Module.concat(__MODULE__, Precompiled)
  @manifest_cache_file "asset_manifest.term"
  @snapshot_key {__MODULE__, :snapshot}
  @snapshot_missing :__phoenix_asset_pipeline_manifest_snapshot_missing__

  if @precompiled? do
    @persistent_missing :__phoenix_asset_pipeline_manifest_persistent_missing__

    @compile {:no_warn_undefined, {@precompiled_module, :manifest, 0}}

    @doc false
    def start_link(_) do
      ensure_precompiled!()
      load_precompiled_manifest!()
      :ignore
    end

    @impl true
    def init(_), do: {:ok, nil}

    @doc """
    Reads a manifest value by key.
    """
    def get(term, default \\ nil)

    def get(:manifest, default), do: persistent_get(:manifest, default)

    def get(term, default), do: persistent_get(term, default)

    @doc """
    Reads a nested manifest value by section and key.
    """
    def find(term, key) do
      case persistent_get(term, nil) do
        section when is_map(section) -> Map.get(section, key)
        _ -> nil
      end
    end

    @doc false
    def put(manifest) when is_map(manifest) do
      put_persistent_manifest(manifest)
      :ok
    end

    @doc false
    def put_compile_manifest(manifest) when is_map(manifest) do
      put_persistent_manifest(manifest)
      :ok
    end

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

    defp load_precompiled_manifest do
      if precompiled_module_loaded?() do
        load_precompiled_manifest!()
        true
      else
        false
      end
    end

    defp load_precompiled_manifest! do
      put_persistent_manifest(@precompiled_module.manifest())
    end

    defp precompiled_module_loaded? do
      Code.ensure_loaded?(@precompiled_module) and function_exported?(@precompiled_module, :manifest, 0)
    end

    defp persistent_get(term, default) do
      key = persistent_key(term)

      case :persistent_term.get(key, @persistent_missing) do
        @persistent_missing ->
          cond do
            persistent_loaded?() -> default
            load_precompiled_manifest() -> :persistent_term.get(key, default)
            true -> default
          end

        value ->
          value
      end
    end

    defp persistent_key(term), do: {__MODULE__, :manifest, term}

    defp persistent_loaded?, do: :persistent_term.get({__MODULE__, :manifest_loaded}, false)

    defp refresh_precompiled_manifest(manifest), do: put_persistent_manifest(manifest)

    defp put_persistent_manifest(manifest) do
      :persistent_term.put(persistent_key(:manifest), manifest)

      Enum.each(manifest, fn {term, value} ->
        :persistent_term.put(persistent_key(term), value)
      end)

      :persistent_term.put({__MODULE__, :manifest_loaded}, true)
    end
  else
    @stored_missing :__phoenix_asset_pipeline_manifest_stored_missing__
    @compile_manifest_missing :__phoenix_asset_pipeline_manifest_compile_missing__
    @compile_manifest_key {__MODULE__, :compile_manifest}

    @doc false
    def start_link(_) do
      GenServer.start_link(__MODULE__, [], name: __MODULE__)
    end

    @impl true
    def init(_) do
      table = :ets.new(__MODULE__, [:named_table, :public, read_concurrency: true])

      load_initial_manifest(table)

      {:ok, table}
    end

    @doc """
    Reads a manifest value by key.
    """
    def get(term, default \\ nil)

    def get(:manifest, default) do
      case snapshot() do
        @snapshot_missing -> stored_manifest(default)
        nil -> default
        manifest -> manifest
      end
    end

    def get(term, default) do
      case snapshot() do
        @snapshot_missing -> stored_get(term, default)
        nil -> default
        manifest -> Map.get(manifest, term, default)
      end
    end

    @doc """
    Reads a nested manifest value by section and key.
    """
    def find(term, key) do
      case snapshot() do
        @snapshot_missing -> stored_find(term, key)
        nil -> nil
        manifest -> manifest |> Map.get(term, %{}) |> Map.get(key)
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
      :persistent_term.put(@compile_manifest_key, manifest)
      :ok
    end

    @impl true
    def handle_call({:put, manifest}, _, table) do
      :ets.insert(table, {:manifest, manifest})
      {:reply, :ok, table}
    end

    if @cache? do
      require Logger

      defp load_initial_manifest(table) do
        case read_cached_manifest() do
          {:ok, manifest} -> :ets.insert(table, {:manifest, manifest})
          :error -> :ok
        end
      end

      defp cached_manifest(default) do
        case read_cached_manifest() do
          {:ok, manifest} ->
            put_compile_manifest(manifest)
            manifest

          :error ->
            :persistent_term.put(@compile_manifest_key, @compile_manifest_missing)
            default
        end
      end

      defp read_cached_manifest do
        path = cache_path()

        with {:ok, binary} <- File.read(path),
             {:ok, manifest} <- decode_cached_manifest(path, binary) do
          {:ok, manifest}
        else
          :error -> :error
          {:error, _} -> :error
        end
      end

      defp decode_cached_manifest(path, binary) do
        case :erlang.binary_to_term(binary, [:safe]) do
          manifest when is_map(manifest) ->
            if valid?(manifest), do: {:ok, manifest}, else: discard_cached_manifest(path)

          _ ->
            discard_cached_manifest(path)
        end
      rescue
        _ -> discard_cached_manifest(path)
      end

      defp discard_cached_manifest(path) do
        _ = File.rm(path)

        Logger.warning("discarded invalid PhoenixAssetPipeline manifest cache: #{path}")

        :error
      end
    else
      defp load_initial_manifest(table) do
        :ets.insert(table, {:manifest, PhoenixAssetPipeline.build()})
      end

      defp cached_manifest(default), do: default
    end

    defp snapshot, do: Process.get(@snapshot_key, @snapshot_missing)

    defp refresh_precompiled_manifest(_), do: :ok

    defp stored_find(term, key) do
      term
      |> stored_get(%{})
      |> Map.get(key)
    end

    defp stored_get(term, default) do
      %{}
      |> stored_manifest()
      |> Map.get(term, default)
    end

    defp stored_manifest(default) do
      __MODULE__
      |> :ets.whereis()
      |> ets_manifest(@stored_missing)
      |> case do
        @stored_missing -> compile_manifest(default)
        manifest -> manifest
      end
    end

    defp compile_manifest(default) do
      case :persistent_term.get(@compile_manifest_key, @stored_missing) do
        @stored_missing -> cached_manifest(default)
        @compile_manifest_missing -> default
        manifest -> manifest
      end
    end

    defp ets_manifest(:undefined, default), do: default

    defp ets_manifest(table, default) do
      case :ets.lookup(table, :manifest) do
        [{:manifest, manifest}] -> manifest
        [] -> default
      end
    end
  end

  @doc """
  Temporarily stores a process-local manifest snapshot.
  """
  def put_snapshot(manifest) do
    previous = Process.get(@snapshot_key, @snapshot_missing)

    Process.put(@snapshot_key, manifest)

    previous
  end

  @doc """
  Restores a manifest snapshot returned by `put_snapshot/1`.
  """
  def restore_snapshot(@snapshot_missing), do: Process.delete(@snapshot_key)

  def restore_snapshot(manifest), do: Process.put(@snapshot_key, manifest)

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

    File.write!(path, precompiled_beam!(manifest))
    register_precompiled_module!(path)
    refresh_precompiled_manifest(manifest)

    path
  end

  if @cache? do
    def save_cached(manifest) when is_map(manifest) do
      path = cache_path()

      PhoenixAssetPipeline.Cache.write_term!(path, manifest)
      put_compile_manifest(manifest)

      :ok
    end
  else
    def save_cached(_), do: :ok
  end

  @doc """
  Returns the cache file path used when `:cache_manifest` is enabled.
  """
  def cache_path do
    Path.join(Config.manifest_cache_dir(), @manifest_cache_file)
  end

  defp precompiled_beam_path do
    __MODULE__
    |> :code.which()
    |> List.to_string()
    |> Path.dirname()
    |> Path.join(Atom.to_string(@precompiled_module) <> ".beam")
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

      File.write!(app_file, IO.iodata_to_binary(:io_lib.format(~c"~tp.~n", [application])))
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
      {{module_name, id, hash}, {strings, lists}}
      when is_binary(module_name) and is_integer(id) and id >= 0 and is_binary(hash) and is_tuple(strings) and
             is_tuple(lists) and tuple_size(strings) == tuple_size(lists) ->
        size = tuple_size(strings)

        size > 0 and tuple_binaries_valid?(strings, 0, size) and tuple_binary_lists_valid?(lists, 0, size)

      _ ->
        false
    end)
  end

  defp class_descriptors_valid?(_), do: false

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

  defp encoded_asset_data_valid?(%{"raw" => raw, "br" => br, "deflate" => deflate, "gzip" => gzip, "zstd" => zstd}) do
    encoded_asset_entry_valid?(raw) and
      encoded_asset_entry_valid?(br) and
      encoded_asset_entry_valid?(deflate) and
      encoded_asset_entry_valid?(gzip) and
      encoded_asset_entry_valid?(zstd)
  end

  defp encoded_asset_data_valid?(_), do: false

  defp encoded_asset_entry_valid?({content, byte_size}) when is_binary(content) and is_integer(byte_size), do: true

  defp encoded_asset_entry_valid?(_), do: false

  defp image_sources_valid?(sources) when is_map(sources) do
    Enum.all?(sources, fn
      {_, %{path: path}} when is_binary(path) -> true
      _ -> false
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

  defp encoded_static_data_valid?(%{"raw" => raw, "br" => br, "deflate" => deflate, "gzip" => gzip, "zstd" => zstd}) do
    encoded_static_entry_valid?(raw) and
      encoded_static_entry_valid?(br) and
      encoded_static_entry_valid?(deflate) and
      encoded_static_entry_valid?(gzip) and
      encoded_static_entry_valid?(zstd)
  end

  defp encoded_static_data_valid?(_), do: false

  defp encoded_static_entry_valid?({content, byte_size, etag})
       when is_binary(content) and is_integer(byte_size) and is_binary(etag), do: true

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
