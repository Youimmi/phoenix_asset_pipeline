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
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Native

  @minimum_compression_size 1_024
  @class_cache_file "classes.term"
  @encoded_asset_cache_file "encoded_assets.term"
  @precompiled? Config.manifest_mode() == :precompiled
  @encoding_profile if @precompiled?,
                      do: {
                        :production,
                        [
                          {"br", {:brotli, 11}},
                          {"deflate", {:zlib, 15, 9}},
                          {"gzip", {:zlib, 31, 9}},
                          {"zstd", {:zstd, 22}}
                        ],
                        @minimum_compression_size,
                        Config.already_compressed_extensions()
                      },
                      else: {
                        :development,
                        [],
                        @minimum_compression_size,
                        Config.already_compressed_extensions()
                      }
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
    static_dir
    |> source_snapshot()
    |> build_from_source_snapshot()
  end

  @doc false
  def build_from_source_snapshot({files, static_signature}) do
    modules = application_modules()
    {template_records, template_signature} = template_snapshot(modules)

    build_manifest(files, static_signature, template_records, template_signature)
  end

  @doc false
  def build_if_stale(static_dir \\ static_dir()) do
    modules = application_modules()
    static_files = static_source_files(static_dir)
    assets = Assets.snapshot()
    asset_signature_terms = Assets.signature_terms(assets)
    static_signature = static_signature_from_terms(static_files, asset_signature_terms)
    {template_records, template_signature} = template_snapshot(modules)
    manifest_signature = signature(static_signature, template_signature)

    if Manifest.get(:signature) == manifest_signature do
      :current
    else
      {built_assets, built_asset_signature_terms} = build_consistent_assets(assets, asset_signature_terms)

      static_signature =
        if built_asset_signature_terms == asset_signature_terms,
          do: static_signature,
          else: static_signature_from_terms(static_files, built_asset_signature_terms)

      files = unique_files(static_files, built_assets)

      {:ok, build_manifest(files, static_signature, template_records, template_signature)}
    end
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
  def current?, do: Manifest.get(:signature) == current_signature()

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
        fn -> run_manifest(static_dir()) end,
        [node()],
        :infinity
      )
    end
  end

  @doc false
  def source_snapshot(static_dir \\ static_dir()) do
    static_files = static_source_files(static_dir)
    assets = Assets.snapshot()
    asset_signature_terms = Assets.signature_terms(assets)
    {built_assets, asset_signature_terms} = build_consistent_assets(assets, asset_signature_terms)

    files = unique_files(static_files, built_assets)

    {files, static_signature_from_terms(static_files, asset_signature_terms)}
  end

  @doc false
  def start_link(opts \\ []) do
    children = maybe_add_watcher([Manifest], Keyword.get(opts, :watcher, Config.watcher?()))

    Supervisor.start_link(children, [strategy: :one_for_one] ++ supervisor_name(opts))
  end

  @doc """
  Returns the configured static directory as an absolute path.
  """
  def static_dir, do: Config.static_dir()

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
          scripts = [{path, digest} | scripts]
          contents = put_asset_content(contents, digest, content, compressible?(path, content), false, true)
          {images, scripts, styles, static_files, contents}

        {"assets/img/" <> path, content, digest, {:image_placeholder, _} = metadata},
        {images, scripts, styles, static_files, contents} ->
          images = [{path, digest, MIME.from_path(path), metadata} | images]
          contents = put_asset_content(contents, digest, content, compressible?(path, content), false, false)
          {images, scripts, styles, static_files, contents}

        {"assets/img/" <> path, content, digest}, {images, scripts, styles, static_files, contents} ->
          images = [{path, digest, MIME.from_path(path), nil} | images]
          contents = put_asset_content(contents, digest, content, compressible?(path, content), false, false)
          {images, scripts, styles, static_files, contents}

        {"assets/svg/" <> path, content, digest}, {images, scripts, styles, static_files, contents} ->
          images = [{path, digest, MIME.from_path(path), nil} | images]
          contents = put_asset_content(contents, digest, content, compressible?(path, content), false, false)
          {images, scripts, styles, static_files, contents}

        {path, content, digest}, {images, scripts, styles, static_files, contents} ->
          static_files = [{path, digest, MIME.from_path(path)} | static_files]
          contents = put_asset_content(contents, digest, content, compressible?(path, content), true, false)
          {images, scripts, styles, static_files, contents}
      end)

    {class_counts, fixed_classes} = class_counts(styles, template_records, images)

    classes = cached_classes(class_counts, fixed_classes)

    class_descriptors = PhoenixAssetPipeline.Helpers.build_class_descriptors(template_records, classes)

    encoding_profile = encoding_profile()
    old_encoded_assets = read_encoded_asset_cache(encoding_profile)
    {encoded_assets, encoded_cache_changed?} = encoded_assets(contents, old_encoded_assets, elem(encoding_profile, 1))
    {images, image_sources, placeholder_css} = build_image_assets(images, encoded_assets, classes)
    {scripts, script_tags} = build_script_assets(scripts, encoded_assets)
    style_tags = build_style_tags(styles, classes, placeholder_css)
    static_files = build_static_assets(static_files, encoded_assets)

    save_encoded_asset_cache(encoded_assets, old_encoded_assets, encoding_profile, encoded_cache_changed?)

    %{
      class_descriptors: class_descriptors,
      classes: classes,
      csp_directives: csp_directives(script_tags, style_tags),
      digest: asset_digest(static_signature, classes),
      early_hints_preloads: early_hints_preloads(script_tags),
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

  defp add_postfix(char, 0), do: char
  defp add_postfix(char, count), do: "#{char}#{count}"

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

  defp maybe_add_watcher(children, true), do: children ++ [PhoenixAssetPipeline.Watcher]
  defp maybe_add_watcher(children, _), do: children

  defp asset_digest(static_signature, classes) do
    {static_signature, classes}
    |> digest_term()
    |> binary_part(0, 12)
    |> Base.encode16(case: :lower)
  end

  defp build_consistent_assets(assets, signature_terms) do
    built_assets = Assets.build(assets)
    next_assets = Assets.snapshot()
    next_signature_terms = Assets.signature_terms(next_assets)

    if next_signature_terms == signature_terms,
      do: {built_assets, signature_terms},
      else: build_consistent_assets(next_assets, next_signature_terms)
  end

  defp class(class_name), do: "." <> css_escape(class_name)

  defp build_classes(class_counts, fixed_classes) do
    short_names = reverse_fixed_classes!(fixed_classes)

    class_counts
    |> Enum.reduce(short_names, fn {class_name, _}, short_names ->
      if Map.has_key?(fixed_classes, class_name),
        do: short_names,
        else: class_name |> obfuscate_class(short_names, fixed_classes, 0) |> elem(1)
    end)
    |> Map.new(&{elem(&1, 1), elem(&1, 0)})
  end

  defp build_style_tags(styles, classes, placeholder_css) do
    image_stylesheet = Config.image_stylesheet()

    variable_replacements =
      styles
      |> Enum.reduce(%{}, fn {_, _, _, _, _, variable_counts}, counts ->
        count_css_variables(variable_counts, counts)
      end)
      |> css_variable_replacements()
      |> Map.to_list()

    tags =
      Map.new(styles, fn {path, css, marker_classes, _, marker_prefix, _} ->
        css = rewrite_css(css, marker_prefix, marker_classes, classes, variable_replacements)

        css =
          if placeholder_css != [] and path == image_stylesheet,
            do: IO.iodata_to_binary([css | placeholder_css]),
            else: css

        {path, %{content: css, digest: digest(css), integrity: integrity(css)}}
      end)

    if placeholder_css != [] and not Map.has_key?(tags, image_stylesheet) do
      raise ArgumentError, "missing configured image stylesheet assets/css/#{image_stylesheet}"
    end

    tags
  end

  defp build_image_assets(entries, encoded_assets, classes) do
    {images, sources, placeholder_css} =
      Enum.reduce(entries, {%{}, %{}, %{}}, fn
        {path, digest, content_type, metadata}, {images, sources, placeholder_css} ->
          {data, _, _, _} = Map.fetch!(encoded_assets, digest)
          digested_path = digested_path(digest, Path.extname(path))

          image = %{content_type: content_type, data: data, digest: digest}
          {source, placeholder_css} = image_source(digest, digested_path, metadata, classes, placeholder_css)

          {Map.put(images, digested_path, image), Map.put(sources, path, source), placeholder_css}
      end)

    {images, sources, placeholder_css |> Map.values() |> Enum.sort()}
  end

  defp image_source(digest, digested_path, {:image_placeholder, placeholder}, classes, placeholder_css) do
    class_name = Map.fetch!(classes, placeholder_class(placeholder))

    {
      %{digest: digest, path: "/" <> digested_path, placeholder_class: class_name},
      Map.put_new(placeholder_css, class_name, [
        "[data-p]",
        class(class_name),
        "{background-image:url(",
        placeholder,
        ");background-position:center;background-size:cover}"
      ])
    }
  end

  defp image_source(digest, digested_path, nil, _, placeholder_css) do
    {%{digest: digest, path: "/" <> digested_path}, placeholder_css}
  end

  defp placeholder_class(placeholder), do: "image-placeholder-" <> digest(placeholder)

  defp build_script_assets(entries, encoded_assets) do
    Enum.reduce(entries, {%{}, %{}}, fn {path, digest}, {scripts, tags} ->
      {data, _, integrity, _} = Map.fetch!(encoded_assets, digest)
      digested_path = digested_path(digest, ".js")

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

            data = static_asset_data(data, etags)

            file = %{content_type: content_type, data: data, digest: digest}
            {Map.put(files, path, file), Map.put(data_by_digest, digest, data)}
        end
      end)

    files
  end

  defp put_asset_content(contents, digest, content, compress?, static?, integrity?) do
    case Map.fetch(contents, digest) do
      {:ok, {stored_content, stored_compress?, stored_static?, stored_integrity?}} ->
        value =
          {stored_content, stored_compress? or compress?, stored_static? or static?, stored_integrity? or integrity?}

        Map.put(contents, digest, value)

      :error ->
        Map.put(contents, digest, {content, compress?, static?, integrity?})
    end
  end

  defp static_asset_data(data, etags) do
    Map.new(data, fn {encoding, {content, size}} ->
      {encoding, {content, size, Map.fetch!(etags, encoding)}}
    end)
  end

  defp compressible?(path, content) when byte_size(content) >= @minimum_compression_size do
    extension = path |> Path.extname() |> String.downcase()
    not is_map_key(Config.already_compressed_extensions(), extension)
  end

  defp compressible?(_, _), do: false

  defp encoding_profile, do: @encoding_profile

  defp cached_classes(class_counts, fixed_classes) do
    signature = class_signature(class_counts, fixed_classes)

    case read_class_cache() do
      {^signature, classes} when is_map(classes) ->
        classes

      _ ->
        classes = build_classes(class_counts, fixed_classes)
        save_class_cache(signature, classes)
        classes
    end
  end

  defp class_cache_path do
    Path.join(Config.manifest_cache_dir(), @class_cache_file)
  end

  defp class_signature(class_counts, fixed_classes) do
    digest_term({class_counts, fixed_classes})
  end

  defp compress(_, content, {:brotli, quality}), do: Native.compress(content, quality)

  defp compress(_, content, {:zstd, level}) do
    content
    |> :zstd.compress(%{compressionLevel: level})
    |> IO.iodata_to_binary()
  end

  defp compress(_, content, {:zlib, window_bits, level}) do
    zstream = :zlib.open()

    try do
      :zlib.deflateInit(zstream, level, :deflated, window_bits, 9, :default)
      data = :zlib.deflate(zstream, content, :finish)
      IO.iodata_to_binary(data)
    after
      try do
        :zlib.deflateEnd(zstream)
      catch
        _, _ -> :ok
      end

      :zlib.close(zstream)
    end
  end

  defp digest(content) do
    content
    |> :erlang.md5()
    |> Base.encode16(case: :lower)
  end

  defp digest_term(term) do
    term
    |> :erlang.term_to_iovec([:deterministic])
    |> :erlang.md5()
  end

  defp early_hints_preloads(script_tags) do
    for {_, %{path: path}} <- script_tags do
      path <> ">; rel=preload; as=script; crossorigin"
    end
  end

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

  defp count_css_variables([{variable, count} | variables], counts) do
    count_css_variables(variables, Map.update(counts, variable, count, &(&1 + count)))
  end

  defp count_css_variables([], counts), do: counts

  defp css_variable_replacements(counts) do
    {short_names, variables} =
      Enum.reduce(counts, {%{}, []}, fn {<<"--", name::binary>> = variable, count}, {short_names, variables} ->
        variables =
          case variable do
            "--tw-" <> _ -> [{variable, name, count} | variables]
            _ -> variables
          end

        {Map.put(short_names, name, name), variables}
      end)

    variables
    |> Enum.sort_by(fn {variable, _, count} -> {-byte_size(variable) * count, variable} end)
    |> Enum.reduce({short_names, %{}}, fn {variable, name, _}, {short_names, replacements} ->
      {short_name, short_names} = obfuscate_class(name, short_names)
      replacement = "--" <> short_name

      put_css_variable_replacement(short_names, replacements, variable, replacement)
    end)
    |> elem(1)
  end

  defp digested_path(digest, extname), do: digest <> extname

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

  defp cached_encoded_asset(assets, digest) do
    case Map.fetch(assets, digest) do
      {:ok, asset} ->
        if valid_encoded_asset?(asset), do: {:ok, asset}, else: :error

      _ ->
        :error
    end
  end

  defp valid_encoded_asset?({data, etags, integrity, compressed?}) when is_map(data) and is_boolean(compressed?) do
    (is_nil(etags) or is_map(etags)) and
      (is_nil(integrity) or is_binary(integrity)) and
      encoded_data_valid?(data) and etags_valid?(etags)
  end

  defp valid_encoded_asset?(_), do: false

  defp encoded_data_valid?(data) when is_map(data) do
    Enum.all?(data, fn
      {encoding, {content, stored_size}}
      when encoding in ["br", "deflate", "gzip", "zstd"] and is_binary(content) and
             is_integer(stored_size) ->
        stored_size == byte_size(content)

      _ ->
        false
    end)
  end

  defp etags_valid?(nil), do: true

  defp etags_valid?(etags) do
    Enum.all?(etags, fn {encoding, value} ->
      encoding in ["raw", "br", "deflate", "gzip", "zstd"] and is_binary(value)
    end)
  end

  defp compress_encoded_assets(assets, [], _, changed?), do: {assets, changed?}
  defp compress_encoded_assets(assets, _, [], changed?), do: {assets, changed?}

  defp compress_encoded_assets(assets, jobs, encodings, _) do
    assets =
      jobs
      |> Task.async_stream(
        fn {digest, content} -> {digest, compress_job(content, encodings)} end,
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

  defp compress_job(content, encodings) do
    Enum.reduce(encodings, %{}, fn {encoding, opts}, encoded_assets ->
      encoded = compress(encoding, content, opts)

      if byte_size(encoded) < byte_size(content),
        do: Map.put(encoded_assets, encoding, {encoded, byte_size(encoded)}),
        else: encoded_assets
    end)
  end

  defp finalize_encoded_asset({digest, {content, _, static?, integrity?}}, {assets, changed?}) do
    {data, etags, asset_integrity, compressed?} = Map.fetch!(assets, digest)

    {etags, changed?} =
      if static? and not etags_cover_data?(etags, data) do
        {build_etags(data, digest), true}
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

  defp etags_cover_data?(etags, data) when is_map(etags) do
    map_size(etags) >= map_size(data) and
      Enum.all?(data, fn {encoding, _} -> is_binary(Map.get(etags, encoding)) end)
  end

  defp etags_cover_data?(_, _), do: false

  defp build_etags(data, digest) do
    Map.new(data, fn
      {"raw", _} -> {"raw", <<?\", digest::binary, ?\">>}
      {encoding, {content, _}} -> {encoding, etag(content)}
    end)
  end

  defp encoded_asset_cache_path do
    Path.join(Config.manifest_cache_dir(), @encoded_asset_cache_file)
  end

  defp etag(content), do: ~s("#{digest(content)}")

  defp current_static_signature do
    assets = Assets.snapshot()

    static_dir()
    |> static_source_files()
    |> static_signature(assets)
  end

  defp current_signature do
    modules = application_modules()

    signature(current_static_signature(), template_signature(modules))
  end

  defp integrity(content) do
    hash =
      @integrity_algorithm
      |> :crypto.hash(content)
      |> Base.encode64()

    @integrity_prefix <> hash
  end

  defp read_class_cache do
    Cache.read_term(class_cache_path(), :error, fn
      {signature, classes} when is_binary(signature) and is_map(classes) ->
        {:ok, {signature, classes}}

      _ ->
        :error
    end)
  end

  defp read_encoded_asset_cache(profile) do
    Cache.read_term(encoded_asset_cache_path(), %{}, fn
      {^profile, cache} when is_map(cache) -> {:ok, cache}
      _ -> :error
    end)
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

  defp save_class_cache(signature, classes) do
    Cache.write_term!(class_cache_path(), {signature, classes})
  end

  defp obfuscate_class(class_name, short_names, count \\ 0) do
    obfuscate_class(class_name, short_names, nil, count)
  end

  defp obfuscate_class(class_name, short_names, fixed_classes, count) do
    case fixed_classes do
      %{^class_name => short_name} -> {short_name, short_names}
      _ -> obfuscate_unreserved_class(class_name, short_names, fixed_classes, count)
    end
  end

  defp obfuscate_unreserved_class("phx-" <> _ = class_name, short_names, fixed_classes, _) do
    case phx_variant_parts(class_name) do
      {variant_class, utility_class} ->
        obfuscate_phx_variant_class(
          class_name,
          variant_class,
          utility_class,
          short_names,
          fixed_classes
        )

      :error ->
        case short_names do
          %{^class_name => ^class_name} ->
            {class_name, short_names}

          %{^class_name => other} ->
            raise "class name #{inspect(class_name)} is reserved by #{inspect(other)}"

          _ ->
            {class_name, Map.put(short_names, class_name, class_name)}
        end
    end
  end

  defp obfuscate_unreserved_class(class_name, short_names, fixed_classes, count) do
    short_name =
      class_name
      |> AnyAscii.transliterate()
      |> prefix_char()
      |> add_postfix(count)

    case Map.get(short_names, short_name) do
      nil -> {short_name, Map.put(short_names, short_name, class_name)}
      ^class_name -> {short_name, short_names}
      _ -> obfuscate_class(class_name, short_names, fixed_classes, count + 1)
    end
  end

  defp obfuscate_phx_variant_class(class_name, variant_class, utility_class, short_names, fixed_classes) do
    {variant_short_name, short_names} = obfuscate_class(variant_class, short_names, fixed_classes, 0)

    {utility_short_name, short_names} =
      obfuscate_phx_utility(utility_class, short_names, fixed_classes)

    short_name = variant_short_name <> ":" <> utility_short_name

    put_obfuscated_class(short_name, class_name, short_names, 0)
  end

  defp obfuscate_phx_utility(utility_class, short_names, fixed_classes) do
    if fixed_classes != nil and Map.has_key?(fixed_classes, utility_class) do
      short_name = utility_class |> AnyAscii.transliterate() |> prefix_char()
      {short_name, short_names}
    else
      obfuscate_class(utility_class, short_names, fixed_classes, 0)
    end
  end

  defp put_obfuscated_class(short_name, class_name, short_names, count) do
    candidate = add_postfix(short_name, count)

    case Map.get(short_names, candidate) do
      nil -> {candidate, Map.put(short_names, candidate, class_name)}
      ^class_name -> {candidate, short_names}
      _ -> put_obfuscated_class(short_name, class_name, short_names, count + 1)
    end
  end

  defp prefix_char([char | _]) when char in ?a..?z do
    <<char::utf8>>
  end

  defp prefix_char([char | _]) when char in ?A..?Z do
    String.downcase(<<char::utf8>>)
  end

  defp prefix_char([_ | chars]), do: prefix_char(chars)
  defp prefix_char(_), do: "c"

  defp phx_variant_parts(class_name) do
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

  defp class_counts(styles, template_records, images) do
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

    counts =
      Enum.reduce(images, counts, fn
        {_, _, _, {:image_placeholder, placeholder}}, counts ->
          Map.update(counts, placeholder_class(placeholder), 1, &(&1 + 1))

        _, counts ->
          counts
      end)

    {Enum.sort_by(counts, &{-elem(&1, 1), elem(&1, 0)}), fixed_classes}
  end

  defp count_class_names([class_name | class_names], counts) do
    count_class_names(class_names, Map.update(counts, class_name, 1, &(&1 + 1)))
  end

  defp count_class_names([], counts), do: counts

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

  defp reverse_fixed_classes!(fixed_classes) do
    Enum.reduce(fixed_classes, %{}, fn {class_name, short_name}, short_names ->
      case short_names do
        %{^short_name => ^class_name} ->
          short_names

        %{^short_name => other} ->
          raise "fixed class name #{inspect(short_name)} is shared by #{inspect(other)} and #{inspect(class_name)}"

        _ ->
          Map.put(short_names, short_name, class_name)
      end
    end)
  end

  defp count_css_classes([class_name | class_names], [count | class_counts], counts) do
    count_css_classes(class_names, class_counts, Map.update(counts, class_name, count, &(&1 + count)))
  end

  defp count_css_classes([], [], counts), do: counts

  defp rewrite_css(css, _, [], _, []), do: css

  defp rewrite_css(css, marker_prefix, marker_classes, classes, variable_replacements) do
    class_replacements =
      Enum.map(marker_classes, fn class_name ->
        class(Map.fetch!(classes, class_name))
      end)

    Native.finalize_css(css, marker_prefix, class_replacements, variable_replacements)
  end

  defp put_css_variable_replacement(short_names, replacements, variable, replacement)
       when byte_size(replacement) < byte_size(variable) do
    {short_names, Map.put(replacements, variable, replacement)}
  end

  defp put_css_variable_replacement(short_names, replacements, _, _), do: {short_names, replacements}

  if !@precompiled? do
    defp put_manifest(manifest) do
      :ok = Manifest.put(manifest)
      :ok = Manifest.save_cached(manifest)
    end

    defp run_manifest(static_dir) do
      case build_if_stale(static_dir) do
        :current -> :ok
        {:ok, manifest} -> put_manifest(manifest)
      end
    end
  end

  defp signature(static_signature, template_signature) do
    digest_term({static_signature, template_signature})
  end

  defp static_file(path, static_dir) do
    content = File.read!(path)
    {Path.relative_to(path, static_dir), content, digest(content)}
  end

  defp static_entry(dir, "." <> _ = entry, root) when dir != root or entry != ".well-known", do: []

  defp static_entry(dir, entry, root) do
    path = Path.join(dir, entry)

    case File.stat(path) do
      {:ok, %{type: :directory}} -> static_files_in(path, root)
      {:ok, %{type: :regular}} -> [static_file(path, root)]
      {:ok, _} -> []
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "stat static file", path: path
    end
  end

  defp static_signature(files, assets) do
    static_signature_from_terms(files, Assets.signature_terms(assets))
  end

  defp static_signature_from_terms(files, asset_terms) do
    static_terms = Enum.map(files, fn {path, _, digest} -> {:static, path, digest} end)
    digest_term({static_terms, asset_terms, encoding_profile()})
  end

  defp static_files_in(dir, root) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &static_entry(dir, &1, root))
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "list static files", path: dir
    end
  end

  defp static_source_files(static_dir) do
    root = Path.expand(static_dir)

    root
    |> static_files_in(root)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp supervisor_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
  end

  defp unique_files(static_files, built_assets) do
    files = Enum.reduce(static_files, %{}, &put_unique_file/2)

    built_assets
    |> Enum.reduce(files, &put_unique_file/2)
    |> Enum.map(fn
      {path, {content, digest, metadata}} -> {path, content, digest, metadata}
      {path, {content, digest}} -> {path, content, digest}
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp put_unique_file({path, content, {:image_placeholder, placeholder} = metadata}, files)
       when is_binary(placeholder) do
    Map.put(files, path, {content, digest(content), metadata})
  end

  defp put_unique_file({path, content, digest}, files), do: Map.put(files, path, {content, digest})

  defp put_unique_file({"assets/css/" <> _ = path, content}, files), do: Map.put(files, path, {content, nil})
  defp put_unique_file({path, content}, files), do: Map.put(files, path, {content, digest(content)})

  defp template_signature(modules) do
    modules
    |> template_records()
    |> template_records_signature()
  end

  defp template_snapshot(modules) do
    records = template_records(modules)
    {records, template_records_signature(records)}
  end

  defp template_records(modules) do
    modules
    |> Enum.reduce([], &put_template_record/2)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp put_template_record(mod, records) do
    case template_module(mod) do
      {[], [], []} ->
        records

      {class_names, descriptors, fixed_class_mappings} ->
        [{mod, Enum.sort(class_names), descriptors, fixed_class_mappings} | records]
    end
  end

  defp template_records_signature(records) do
    records
    |> Enum.map(fn {mod, class_names, descriptors, fixed_class_mappings} ->
      {mod, class_names, Enum.map(descriptors, &elem(&1, 0)), fixed_class_mappings}
    end)
    |> digest_term()
  end

  defp template_module(mod) do
    if Code.ensure_loaded?(mod) do
      {
        exported_value(mod, :class_names),
        exported_value(mod, :__class_descriptors__),
        fixed_class_mappings(mod)
      }
    else
      {[], [], []}
    end
  end

  defp exported_value(mod, fun) do
    if function_exported?(mod, fun, 0),
      do: apply(mod, fun, []),
      else: []
  end

  defp persisted_values(mod, key) do
    for {^key, values} <- mod.__info__(:attributes), value <- values, do: value
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

  defp trim_comments("/*! tailwindcss" <> _ = css) do
    css
    |> String.replace(~r{^/\*!.*?\*/\s*}s, "")
    |> trim_comments()
  end

  defp trim_comments(css), do: String.trim(css)
end
