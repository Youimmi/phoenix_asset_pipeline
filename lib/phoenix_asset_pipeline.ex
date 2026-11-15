defmodule PhoenixAssetPipeline do
  @moduledoc """
  Builds and refreshes the PhoenixAssetPipeline manifest.

  The manifest is built from the configured static directory and contains
  digested scripts, inlineable styles, compressed static assets, image sources,
  class mappings, and template class descriptors.

  Applications usually interact with this module through Mix tasks, the
  `PhoenixAssetPipeline.Manifest` process, and the helpers imported by
  `PhoenixAssetPipeline.HTML.Macros`.
  """
  import Phoenix.HTML, only: [css_escape: 1]

  alias PhoenixAssetPipeline.Assets
  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.ClassNames
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files
  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Native
  alias PhoenixAssetPipeline.StaticAsset

  @class_cache_file "classes.term"
  @encoded_asset_cache_file "encoded_assets.term"
  @encodings StaticAsset.encoding_names()
  @implementation [
    __MODULE__,
    Assets,
    Assets.Bun,
    Assets.Sprites,
    ClassNames,
    Config,
    Native,
    PhoenixAssetPipeline.Helpers,
    StaticAsset
  ]
  @native_digest_cache_file "native_digests.term"
  @precompiled? Config.precompiled_manifest?()
  @static_digest_cache_file "static_digests.term"
  @integrity_algorithm :sha512
  @integrity_prefix "sha512-"

  @doc """
  Builds a manifest from `static_dir`.

  The returned manifest is a plain map suitable for
  `PhoenixAssetPipeline.Manifest.put/1`,
  `PhoenixAssetPipeline.Manifest.save_cached/1`, or
  `PhoenixAssetPipeline.Manifest.save_precompiled!/1`.
  """
  def build(static_dir \\ static_dir()) do
    assets = Assets.snapshot()
    build_assets_manifest(assets, Assets.signature_terms(assets), static_dir, template_snapshot())
  end

  @doc false
  def build_if_stale do
    assets = Assets.snapshot()
    asset_terms = Assets.signature_terms(assets)
    static_dir = static_dir()
    template = template_snapshot()

    if current?(asset_terms, static_dir, elem(template, 1)),
      do: :current,
      else: {:ok, build_assets_manifest(assets, asset_terms, static_dir, template)}
  end

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor
    }
  end

  @doc """
  Returns `true` when the stored manifest matches the current static and
  template signature.
  """
  def current? do
    current?(Assets.signature_terms(Assets.snapshot()), static_dir(), elem(template_snapshot(), 1))
  end

  @doc """
  Returns the package priv directory.
  """
  def priv_dir! do
    case :code.priv_dir(:phoenix_asset_pipeline) do
      path when is_list(path) -> List.to_string(path)
      {:error, reason} -> raise "could not find phoenix_asset_pipeline priv dir: #{inspect(reason)}"
    end
  end

  @doc """
  Rebuilds and stores the manifest unless the current manifest is already fresh.
  """
  if @precompiled? do
    def run, do: :ok
  else
    def run do
      :global.trans(
        {{__MODULE__, :run}, self()},
        fn ->
          case build_if_stale() do
            :current ->
              :ok

            {:ok, manifest} ->
              :ok = Manifest.put(manifest)
              Manifest.save_cached(manifest)
          end
        end,
        [node()],
        :infinity
      )
    end
  end

  @doc false
  def start_link(opts \\ []) do
    children =
      if Keyword.get(opts, :watcher, Config.watcher?()) == true,
        do: [Manifest, {PhoenixAssetPipeline.Watcher, &run/0}],
        else: [Manifest]

    Supervisor.start_link(children, [strategy: :one_for_one] ++ Keyword.take(opts, [:name]))
  end

  @doc """
  Returns the configured static directory as an absolute path.
  """
  def static_dir, do: Config.static_dir()

  defp application_modules do
    [Config.otp_app(), :phoenix_asset_pipeline]
    |> Enum.uniq()
    |> Enum.flat_map(&application_modules/1)
    |> Enum.uniq()
  end

  defp application_modules(app) do
    app_file =
      case :code.lib_dir(app) do
        path when is_list(path) -> Path.join([List.to_string(path), "ebin", Atom.to_string(app) <> ".app"])
        {:error, reason} -> raise "failed to locate #{inspect(app)} application: #{inspect(reason)}"
      end

    case :file.consult(String.to_charlist(app_file)) do
      {:ok, [{:application, ^app, properties}]} ->
        case :proplists.lookup(:modules, properties) do
          {:modules, modules} when is_list(modules) -> modules
          _ -> raise "missing modules in application file #{app_file}"
        end

      {:ok, application} ->
        raise "invalid application file #{app_file}: #{inspect(application)}"

      {:error, reason} ->
        raise "failed to read application file #{app_file}: #{inspect(reason)}"
    end
  end

  defp asset_digest(static_signature, classes) do
    {static_signature, classes}
    |> Digest.term()
    |> Base.encode16(case: :lower)
  end

  defp build_assets_manifest(assets, asset_terms, static_dir, {template_records, template_signature}) do
    {built_assets, built_asset_terms} = build_consistent_assets(assets, asset_terms)
    # Read static files after the slow asset build, so the manifest records their latest contents.
    static_files = static_source_files(static_dir)

    static_files
    |> unique_files(built_assets)
    |> build_manifest(static_signature(static_files, built_asset_terms), template_records, template_signature)
  end

  defp build_classes(class_counts, fixed_classes) do
    allocation = ClassNames.new(fixed_classes)

    class_counts
    |> Enum.reduce(allocation, fn {class_name, _}, allocation ->
      class_name |> obfuscate_class(allocation, fixed_classes) |> elem(1)
    end)
    |> elem(0)
  end

  defp build_consistent_assets(assets, signature_terms, attempts \\ 5)

  defp build_consistent_assets(_, _, 0), do: raise("assets changed repeatedly during build")

  defp build_consistent_assets(assets, signature_terms, attempts) do
    built_assets = Assets.build(assets)
    next_assets = Assets.snapshot()
    next_signature_terms = Assets.signature_terms(next_assets)

    if next_signature_terms == signature_terms,
      do: {built_assets, signature_terms},
      else: build_consistent_assets(next_assets, next_signature_terms, attempts - 1)
  end

  defp build_image_assets(entries, encoded_assets) do
    Enum.reduce(entries, {%{}, %{}}, fn {path, digest, content_type}, {images, sources} ->
      {data, _, _, _} = Map.fetch!(encoded_assets, digest)
      digested_path = digest <> Path.extname(path)

      images = Map.put(images, digested_path, %{content_type: content_type, data: data, digest: digest})
      {images, Map.put(sources, path, %{digest: digest, path: "/" <> digested_path})}
    end)
  end

  defp build_manifest(files, static_signature, template_records, template_signature) do
    {images, scripts, styles, static_files, contents} =
      Enum.reduce(files, {[], [], [], [], %{}}, fn
        {"assets/css/" <> path, content, _}, {images, scripts, styles, static_files, contents} ->
          {css, marker_classes, class_counts, marker_prefix, variable_counts} =
            content
            |> trim_comments()
            |> Native.prepare_css()

          styles = [{path, css, marker_classes, class_counts, marker_prefix, variable_counts} | styles]
          {images, scripts, styles, static_files, contents}

        {"assets/js/" <> path, content, digest}, {images, scripts, styles, static_files, contents} ->
          contents = put_asset_content(contents, path, content, digest, false, true)
          {images, [{path, digest} | scripts], styles, static_files, contents}

        {<<"assets/", kind::binary-size(3), ?/, path::binary>>, content, digest},
        {images, scripts, styles, static_files, contents}
        when kind in ["img", "svg"] ->
          contents = put_asset_content(contents, path, content, digest, false, false)
          {[{path, digest, MIME.from_path(path)} | images], scripts, styles, static_files, contents}

        {path, content, digest}, {images, scripts, styles, static_files, contents} ->
          contents = put_asset_content(contents, path, content, digest, true, false)
          {images, scripts, styles, [{path, digest, MIME.from_path(path)} | static_files], contents}
      end)

    {class_counts, fixed_classes} = class_counts(styles, template_records)

    classes = cached_classes(class_counts, fixed_classes)
    class_descriptors = PhoenixAssetPipeline.Helpers.build_class_descriptors(template_records, classes)
    encoding_profile = StaticAsset.profile()
    old_encoded_assets = Cache.read_map(encoded_asset_cache_path(), encoding_profile)
    {encoded_assets, encoded_cache_changed?} = encoded_assets(contents, old_encoded_assets, elem(encoding_profile, 1))
    {images, image_sources} = build_image_assets(images, encoded_assets)
    {scripts, script_tags} = build_script_assets(scripts, encoded_assets)
    style_tags = build_style_tags(styles, classes)
    static_files = build_static_assets(static_files, encoded_assets)

    save_encoded_asset_cache(encoded_assets, old_encoded_assets, encoding_profile, encoded_cache_changed?)

    %{
      class_descriptors: class_descriptors,
      classes: classes,
      csp_directives: csp_directives(script_tags, style_tags),
      digest: asset_digest(static_signature, classes),
      image_sources: image_sources,
      images: images,
      script_tags: script_tags,
      scripts: scripts,
      signature: signature(static_signature, template_signature),
      static_files: static_files,
      static_signature: static_signature,
      style_tags: style_tags
    }
  end

  defp build_script_assets(entries, encoded_assets) do
    Enum.reduce(entries, {%{}, %{}}, fn {path, digest}, {scripts, tags} ->
      {data, _, integrity, _} = Map.fetch!(encoded_assets, digest)
      digested_path = digest <> ".js"

      script = %{content_type: "text/javascript", data: data, digest: digest}
      tag = %{digest: digest, integrity: integrity, path: "/" <> digested_path}

      {Map.put(scripts, digested_path, script), Map.put(tags, path, tag)}
    end)
  end

  defp build_static_assets(entries, encoded_assets) do
    {files, _} =
      Enum.reduce(entries, {%{}, %{}}, fn {path, digest, content_type}, {files, data_by_digest} ->
        case Map.fetch(data_by_digest, digest) do
          {:ok, data} ->
            file = %{content_type: content_type, data: data, digest: digest}
            {Map.put(files, path, file), data_by_digest}

          :error ->
            {data, etags, _, _} = Map.fetch!(encoded_assets, digest)

            data = StaticAsset.data(data, etags)

            file = %{content_type: content_type, data: data, digest: digest}
            {Map.put(files, path, file), Map.put(data_by_digest, digest, data)}
        end
      end)

    files
  end

  defp build_style_tags(styles, classes) do
    variable_replacements =
      styles
      |> Enum.reduce(%{}, fn {_, _, _, _, _, variable_counts}, counts ->
        count_css_variables(variable_counts, counts)
      end)
      |> css_variable_replacements()
      |> Map.to_list()

    Map.new(styles, fn {path, css, marker_classes, _, marker_prefix, _} ->
      # `</style` would end the inline element; to CSS `<\/` is the same text.
      css =
        css
        |> rewrite_css(marker_prefix, marker_classes, classes, variable_replacements)
        |> :binary.replace("</", "<\\/", [:global])

      {path, %{content: css, digest: Digest.hex(css), integrity: integrity(css)}}
    end)
  end

  defp cached_classes(class_counts, fixed_classes) do
    path = Path.join(Config.manifest_cache_dir(), @class_cache_file)
    signature = Digest.term({__MODULE__.module_info(:md5), ClassNames.module_info(:md5), class_counts, fixed_classes})

    case Cache.read_term(path, :error, &{:ok, &1}) do
      {^signature, classes} when is_map(classes) ->
        classes

      _ ->
        classes = build_classes(class_counts, fixed_classes)
        Cache.write_term!(path, {signature, classes})
        classes
    end
  end

  defp cached_encoded_asset(assets, digest) do
    case Map.fetch(assets, digest) do
      {:ok, asset} ->
        if valid_encoded_asset?(asset), do: {:ok, asset}, else: :error

      _ ->
        :error
    end
  end

  defp class(class_name), do: "." <> css_escape(class_name)

  defp class_counts(styles, template_records) do
    counts =
      Enum.reduce(styles, %{}, fn style, counts ->
        count_css_classes(elem(style, 2), elem(style, 3), counts)
      end)

    {counts, fixed_classes} =
      Enum.reduce(
        template_records,
        {counts, %{}},
        fn {_, class_names, _, fixed_class_mappings}, {counts, fixed_classes} ->
          {
            count_class_names(class_names, counts),
            put_fixed_classes(fixed_class_mappings, fixed_classes)
          }
        end
      )

    {Enum.sort_by(counts, &{-elem(&1, 1), elem(&1, 0)}), fixed_classes}
  end

  defp compress_encoded_assets(assets, [], _, changed?), do: {assets, changed?}
  defp compress_encoded_assets(assets, _, [], changed?), do: {assets, changed?}

  defp compress_encoded_assets(assets, jobs, encodings, _) do
    assets =
      jobs
      |> Task.async_stream(
        fn {digest, content} -> {digest, StaticAsset.compress(content, encodings)} end,
        max_concurrency: 4,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(assets, fn {:ok, {digest, encoded}}, assets ->
        Map.update!(assets, digest, fn {data, _, integrity, _} ->
          {Map.merge(data, encoded), nil, integrity, true}
        end)
      end)

    {assets, true}
  end

  defp count_class_names([class_name | class_names], counts) do
    count_class_names(class_names, Map.update(counts, class_name, 1, &(&1 + 1)))
  end

  defp count_class_names([], counts), do: counts

  defp count_css_classes([class_name | class_names], [count | class_counts], counts) do
    count_css_classes(class_names, class_counts, Map.update(counts, class_name, count, &(&1 + count)))
  end

  defp count_css_classes([], [], counts), do: counts

  # A zero count reserves an opaque identifier across every stylesheet. A name no stylesheet
  # declares can only be set outside CSS, so it keeps its spelling too.
  defp count_css_variables([{variable, count, declared?} | variables], counts) do
    count_css_variables(
      variables,
      Map.update(counts, variable, {count, declared?}, fn {total, declared_before?} ->
        {if(total == 0 or count == 0, do: 0, else: total + count), declared? or declared_before?}
      end)
    )
  end

  defp count_css_variables([], counts), do: counts

  defp csp_directives(script_tags, style_tags) do
    %{
      "script-src" => csp_integrities(script_tags),
      "style-src" => csp_integrities(style_tags)
    }
  end

  defp csp_integrities(tags) do
    tags =
      for {_, %{integrity: integrity}} <- tags,
          do: "'#{integrity}'",
          uniq: true

    Enum.sort(tags)
  end

  defp css_variable_replacements(counts) do
    public = Config.public_css_variables()
    # Public names keep their spelling everywhere, so no internal property may be shortened to one.
    reserved = Map.new(public, fn "--" <> name -> {name, name} end)

    {short_names, variables} =
      Enum.reduce(counts, {reserved, []}, fn {<<"--", name::binary>> = variable, {count, declared?}},
                                             {short_names, variables} ->
        variables =
          if count > 0 and declared? and not MapSet.member?(public, variable),
            do: [{variable, name, count} | variables],
            else: variables

        {Map.put(short_names, name, name), variables}
      end)

    variables
    |> Enum.sort_by(fn {variable, _, count} -> {-byte_size(variable) * count, variable} end)
    |> Enum.reduce({{%{}, short_names, %{}}, %{}}, fn {variable, name, _}, {allocation, replacements} ->
      {short_name, allocation} = ClassNames.allocate(ClassNames.prefix(name), name, allocation)
      {allocation, Map.put(replacements, variable, "--" <> short_name)}
    end)
    |> elem(1)
  end

  defp current?(asset_terms, static_dir, template_signature) do
    static_signature = static_signature(static_digests(static_dir), asset_terms)
    Manifest.get(:signature) == signature(static_signature, template_signature)
  end

  defp encoded_asset_cache_path do
    Path.join(Config.manifest_cache_dir(), @encoded_asset_cache_file)
  end

  defp encoded_assets(contents, old_assets, encodings) do
    changed? = map_size(contents) != map_size(old_assets)
    compression_enabled? = encodings != []

    {assets, jobs, changed?} =
      Enum.reduce(contents, {%{}, [], changed?}, fn entry, acc ->
        seed_encoded_asset(entry, old_assets, acc, compression_enabled?)
      end)

    {assets, changed?} = compress_encoded_assets(assets, jobs, encodings, changed?)

    Enum.reduce(contents, {assets, changed?}, &finalize_encoded_asset/2)
  end

  defp encoded_data_valid?(data) when is_map(data) do
    Enum.all?(data, fn
      {encoding, {content, stored_size}}
      when encoding in @encodings and is_binary(content) and
             is_integer(stored_size) ->
        stored_size == byte_size(content)

      _ ->
        false
    end)
  end

  defp etags_cover_data?(etags, data) when is_map(etags) do
    map_size(etags) >= map_size(data) and
      Enum.all?(data, fn {encoding, _} -> is_binary(Map.get(etags, encoding)) end)
  end

  defp etags_cover_data?(_, _), do: false

  defp etags_valid?(nil), do: true

  defp etags_valid?(etags) do
    Enum.all?(etags, fn {encoding, value} ->
      (encoding == "raw" or encoding in @encodings) and is_binary(value)
    end)
  end

  defp exported_value(mod, fun) do
    if function_exported?(mod, fun, 0),
      do: apply(mod, fun, []),
      else: []
  end

  defp finalize_encoded_asset({digest, {content, _, static?, integrity?}}, {assets, changed?}) do
    {data, etags, asset_integrity, compressed?} = Map.fetch!(assets, digest)

    {etags, changed?} =
      if static? and not etags_cover_data?(etags, data) do
        {StaticAsset.etags(data, digest), true}
      else
        {etags, changed?}
      end

    {asset_integrity, changed?} =
      if integrity? and not is_binary(asset_integrity) do
        {integrity(content), true}
      else
        {asset_integrity, changed?}
      end

    asset = {data, etags, asset_integrity, compressed?}
    {Map.put(assets, digest, asset), changed?}
  end

  defp fixed_class_mappings(mod) do
    if function_exported?(mod, :__fixed_class_mappings__, 0) do
      case persisted_values(mod, :phoenix_asset_pipeline_fixed_class_mappings) do
        [] -> mod.__fixed_class_mappings__()
        values -> Enum.sort(values)
      end
    else
      []
    end
  end

  # The manifest also depends on the code that builds it, including the native library.
  defp implementation do
    native =
      priv_dir!()
      |> Path.join("native")
      |> Files.digests(@native_digest_cache_file)
      |> Enum.map(&elem(&1, 1))

    {Enum.map(@implementation, & &1.module_info(:md5)), native}
  end

  defp integrity(content) do
    hash =
      @integrity_algorithm
      |> :crypto.hash(content)
      |> Base.encode64()

    @integrity_prefix <> hash
  end

  defp obfuscate_class(class_name, {classes, _, _} = allocation, fixed_classes) do
    case classes do
      %{^class_name => short_name} -> {short_name, allocation}
      _ -> obfuscate_unreserved_class(class_name, allocation, fixed_classes)
    end
  end

  defp obfuscate_phx_utility(utility_class, allocation, fixed_classes) do
    if Map.has_key?(fixed_classes, utility_class) do
      short_name = ClassNames.prefix(utility_class)
      {short_name, allocation}
    else
      obfuscate_class(utility_class, allocation, fixed_classes)
    end
  end

  defp obfuscate_phx_variant_class(class_name, variant_class, utility_class, allocation, fixed_classes) do
    {variant_short_name, allocation} = obfuscate_class(variant_class, allocation, fixed_classes)

    {utility_short_name, allocation} =
      obfuscate_phx_utility(utility_class, allocation, fixed_classes)

    short_name = variant_short_name <> ":" <> utility_short_name

    ClassNames.allocate(short_name, class_name, allocation)
  end

  defp obfuscate_unreserved_class(
         "phx-" <> _ = class_name,
         {classes, short_names, next_suffixes} = allocation,
         fixed_classes
       ) do
    case ClassNames.variant(class_name) do
      {variant_class, utility_class} ->
        obfuscate_phx_variant_class(
          class_name,
          variant_class,
          utility_class,
          allocation,
          fixed_classes
        )

      :error ->
        case short_names do
          %{^class_name => other} ->
            raise "class name #{inspect(class_name)} is reserved by #{inspect(other)}"

          _ ->
            {class_name,
             {Map.put(classes, class_name, class_name), Map.put(short_names, class_name, class_name), next_suffixes}}
        end
    end
  end

  defp obfuscate_unreserved_class(class_name, allocation, _) do
    ClassNames.allocate(ClassNames.prefix(class_name), class_name, allocation)
  end

  defp persisted_values(mod, key) do
    for {^key, values} <- mod.__info__(:attributes), value <- values, do: value
  end

  defp put_asset_content(contents, path, content, digest, static?, integrity?) do
    compress? = StaticAsset.compressible?(path, content)

    Map.update(contents, digest, {content, compress?, static?, integrity?}, fn
      {content, stored_compress?, stored_static?, stored_integrity?} ->
        {content, stored_compress? or compress?, stored_static? or static?, stored_integrity? or integrity?}
    end)
  end

  defp put_fixed_classes([{class_name, short_name} | mappings], fixed_classes) do
    fixed_classes =
      case fixed_classes do
        %{^class_name => ^short_name} ->
          fixed_classes

        %{^class_name => other} ->
          raise "fixed class #{inspect(class_name)} maps both #{inspect(other)} and #{inspect(short_name)}"

        _ ->
          Map.put(fixed_classes, class_name, short_name)
      end

    put_fixed_classes(mappings, fixed_classes)
  end

  defp put_fixed_classes([], fixed_classes), do: fixed_classes

  defp put_template_record(mod, records) do
    if Code.ensure_loaded?(mod) do
      class_names = exported_value(mod, :class_names)
      descriptors = exported_value(mod, :__class_descriptors__)
      fixed_class_mappings = fixed_class_mappings(mod)

      if class_names == [] and descriptors == [] and fixed_class_mappings == [],
        do: records,
        else: [{mod, Enum.sort(class_names), descriptors, fixed_class_mappings} | records]
    else
      records
    end
  end

  defp put_unique_file(file, files) do
    {path, value} =
      case file do
        {path, content, digest} -> {path, {content, digest}}
        {"assets/css/" <> _ = path, content} -> {path, {content, nil}}
        {path, content} -> {path, {content, Digest.hex(content)}}
      end

    if is_map_key(files, path), do: raise(ArgumentError, "duplicate asset output path: #{inspect(path)}")
    Map.put(files, path, value)
  end

  defp rewrite_css(css, _, [], _, []), do: css

  defp rewrite_css(css, marker_prefix, marker_classes, classes, variable_replacements) do
    class_replacements =
      Enum.map(marker_classes, fn class_name ->
        class(Map.fetch!(classes, class_name))
      end)

    Native.finalize_css(css, marker_prefix, class_replacements, variable_replacements)
  end

  defp save_encoded_asset_cache(assets, old_assets, profile, changed?) do
    if changed? or map_size(assets) != map_size(old_assets) do
      cached_assets =
        Map.new(assets, fn {digest, {data, etags, integrity, compressed?}} ->
          {digest, {Map.delete(data, "raw"), etags, integrity, compressed?}}
        end)

      Cache.write_term!(encoded_asset_cache_path(), {profile, cached_assets})
    else
      :ok
    end
  end

  defp seed_encoded_asset(
         {digest, {content, compress?, _, _}},
         old_assets,
         {assets, jobs, changed?},
         compression_enabled?
       ) do
    compress? = compress? and compression_enabled?
    raw = {content, byte_size(content)}

    case cached_encoded_asset(old_assets, digest) do
      {:ok, {data, etags, integrity, compressed?}} when not compress? ->
        asset = {%{"raw" => raw}, etags, integrity, false}
        changed? = changed? or compressed? or map_size(data) > 0
        {Map.put(assets, digest, asset), jobs, changed?}

      {:ok, {data, etags, integrity, true}} ->
        asset = {Map.put(data, "raw", raw), etags, integrity, true}
        {Map.put(assets, digest, asset), jobs, changed?}

      {:ok, {_, _, integrity, false}} ->
        asset = {%{"raw" => raw}, nil, integrity, false}
        {Map.put(assets, digest, asset), [{digest, content} | jobs], true}

      :error when compress? ->
        asset = {%{"raw" => raw}, nil, nil, false}
        {Map.put(assets, digest, asset), [{digest, content} | jobs], true}

      :error ->
        asset = {%{"raw" => raw}, nil, nil, false}
        {Map.put(assets, digest, asset), jobs, true}
    end
  end

  defp signature(static_signature, template_signature) do
    Digest.term({static_signature, template_signature})
  end

  defp static_digests(static_dir) do
    root = Path.expand(static_dir)

    for {path, digest} <- Files.digests(root, @static_digest_cache_file, :static) do
      {Files.relative_path(path, root), Base.encode16(digest, case: :lower)}
    end
  end

  defp static_file(path, static_dir) do
    content = File.read!(path)
    {Files.relative_path(path, static_dir), content, Digest.hex(content)}
  end

  defp static_signature(files, asset_terms) do
    static_terms =
      Enum.map(files, fn
        {path, digest} -> {:static, path, digest}
        {path, _, digest} -> {:static, path, digest}
      end)

    generated =
      Map.new(Config.generated(), fn {path, {module, _, _} = generator} ->
        {path, {generator, module.module_info(:md5)}}
      end)

    Digest.term({static_terms, asset_terms, StaticAsset.profile(), generated, implementation()})
  end

  defp static_source_files(static_dir) do
    root = Path.expand(static_dir)

    root
    |> Files.regular_files(:static)
    |> Enum.map(&static_file(&1, root))
  end

  defp template_snapshot do
    records =
      application_modules()
      |> Enum.reduce([], &put_template_record/2)
      |> Enum.sort_by(&elem(&1, 0))

    signature =
      records
      |> Enum.map(fn {mod, class_names, descriptors, fixed_class_mappings} ->
        {mod, class_names, Enum.map(descriptors, &elem(&1, 0)), fixed_class_mappings}
      end)
      |> Digest.term()

    {records, signature}
  end

  defp trim_comments("/*! tailwindcss" <> _ = css) do
    css
    |> String.replace(~r{^/\*!.*?\*/\s*}s, "")
    |> trim_comments()
  end

  defp trim_comments(css), do: String.trim(css)

  defp unique_files(static_files, built_assets) do
    files = Enum.reduce(static_files, %{}, &put_unique_file/2)

    built_assets
    |> Enum.reduce(files, &put_unique_file/2)
    |> Enum.map(fn {path, {content, digest}} -> {path, content, digest} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp valid_encoded_asset?({data, etags, integrity, compressed?}) when is_map(data) and is_boolean(compressed?) do
    (is_nil(etags) or is_map(etags)) and
      (is_nil(integrity) or is_binary(integrity)) and
      encoded_data_valid?(data) and etags_valid?(etags)
  end

  defp valid_encoded_asset?(_), do: false
end
