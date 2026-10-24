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
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files
  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Native
  alias PhoenixAssetPipeline.StaticAsset

  @class_cache_file "classes.term"
  @encoded_asset_cache_file "encoded_assets.term"
  @precompiled? Config.precompiled_manifest?()
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

  @doc """
  Builds one static file from iodata, including the current encoding profile and ETags.

  Does not read or write the on-disk manifest or asset caches.
  """
  def build_static_file(path, content) do
    StaticAsset.build(path, content)
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

  defp asset_digest(static_signature, classes) do
    {static_signature, classes}
    |> Digest.term()
    |> Base.encode16(case: :lower)
  end

  defp build_classes(class_counts, fixed_classes) do
    allocation = {fixed_classes, reverse_fixed_classes!(fixed_classes), %{}}

    class_counts
    |> Enum.reduce(allocation, fn {class_name, _}, allocation ->
      class_name |> obfuscate_class(allocation, fixed_classes) |> elem(1)
    end)
    |> elem(0)
  end

  defp build_consistent_assets(assets, signature_terms) do
    built_assets = Assets.build(assets)
    next_assets = Assets.snapshot()
    next_signature_terms = Assets.signature_terms(next_assets)

    if next_signature_terms == signature_terms,
      do: {built_assets, signature_terms},
      else: build_consistent_assets(next_assets, next_signature_terms)
  end

  defp build_image_assets(entries, encoded_assets) do
    Enum.reduce(entries, {%{}, %{}}, fn {path, digest, content_type}, {images, sources} ->
      {data, _, _, _} = Map.fetch!(encoded_assets, digest)
      digested_path = digested_path(digest, Path.extname(path))

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
          scripts = [{path, digest} | scripts]

          contents =
            put_asset_content(contents, digest, content, StaticAsset.compressible?(path, content), false, true)

          {images, scripts, styles, static_files, contents}

        {"assets/img/" <> path, content, digest}, {images, scripts, styles, static_files, contents} ->
          images = [{path, digest, MIME.from_path(path)} | images]

          contents =
            put_asset_content(contents, digest, content, StaticAsset.compressible?(path, content), false, false)

          {images, scripts, styles, static_files, contents}

        {"assets/svg/" <> path, content, digest}, {images, scripts, styles, static_files, contents} ->
          images = [{path, digest, MIME.from_path(path)} | images]

          contents =
            put_asset_content(contents, digest, content, StaticAsset.compressible?(path, content), false, false)

          {images, scripts, styles, static_files, contents}

        {path, content, digest}, {images, scripts, styles, static_files, contents} ->
          static_files = [{path, digest, MIME.from_path(path)} | static_files]

          contents =
            put_asset_content(contents, digest, content, StaticAsset.compressible?(path, content), true, false)

          {images, scripts, styles, static_files, contents}
      end)

    {class_counts, fixed_classes} = class_counts(styles, template_records)

    classes = cached_classes(class_counts, fixed_classes)

    class_descriptors = PhoenixAssetPipeline.Helpers.build_class_descriptors(template_records, classes)

    encoding_profile = encoding_profile()
    old_encoded_assets = read_encoded_asset_cache(encoding_profile)
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
      css = rewrite_css(css, marker_prefix, marker_classes, classes, variable_replacements)
      {path, %{content: css, digest: Digest.hex(css), integrity: integrity(css)}}
    end)
  end

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

  defp cached_encoded_asset(assets, digest) do
    case Map.fetch(assets, digest) do
      {:ok, asset} ->
        if valid_encoded_asset?(asset), do: {:ok, asset}, else: :error

      _ ->
        :error
    end
  end

  defp class(class_name), do: "." <> css_escape(class_name)

  defp class_cache_path do
    Path.join(Config.manifest_cache_dir(), @class_cache_file)
  end

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

  defp class_signature(class_counts, fixed_classes) do
    Digest.term({class_counts, fixed_classes})
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

  defp count_css_variables([{variable, count} | variables], counts) do
    count_css_variables(variables, Map.update(counts, variable, count, &(&1 + count)))
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
    |> Enum.reduce({{%{}, short_names, %{}}, %{}}, fn {variable, name, _}, {allocation, replacements} ->
      {short_name, allocation} = obfuscate_class(name, allocation)
      replacement = "--" <> short_name

      put_css_variable_replacement(allocation, replacements, variable, replacement)
    end)
    |> elem(1)
  end

  defp current_signature do
    modules = application_modules()

    signature(current_static_signature(), template_signature(modules))
  end

  defp current_static_signature do
    assets = Assets.snapshot()

    static_dir()
    |> static_source_files()
    |> static_signature(assets)
  end

  defp digested_path(digest, extname), do: digest <> extname

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
      when encoding in ["br", "deflate", "gzip", "zstd"] and is_binary(content) and
             is_integer(stored_size) ->
        stored_size == byte_size(content)

      _ ->
        false
    end)
  end

  defp encoding_profile, do: StaticAsset.profile()

  defp etags_cover_data?(etags, data) when is_map(etags) do
    map_size(etags) >= map_size(data) and
      Enum.all?(data, fn {encoding, _} -> is_binary(Map.get(etags, encoding)) end)
  end

  defp etags_cover_data?(_, _), do: false

  defp etags_valid?(nil), do: true

  defp etags_valid?(etags) do
    Enum.all?(etags, fn {encoding, value} ->
      encoding in ["raw", "br", "deflate", "gzip", "zstd"] and is_binary(value)
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

  defp integrity(content) do
    hash =
      @integrity_algorithm
      |> :crypto.hash(content)
      |> Base.encode64()

    @integrity_prefix <> hash
  end

  defp maybe_add_watcher(children, true), do: children ++ [{PhoenixAssetPipeline.Watcher, &run/0}]
  defp maybe_add_watcher(children, _), do: children

  defp obfuscate_class(class_name, {classes, _, _} = allocation, fixed_classes \\ nil) do
    case classes do
      %{^class_name => short_name} -> {short_name, allocation}
      _ -> obfuscate_unreserved_class(class_name, allocation, fixed_classes)
    end
  end

  defp obfuscate_phx_utility(utility_class, allocation, fixed_classes) do
    if fixed_classes != nil and Map.has_key?(fixed_classes, utility_class) do
      short_name = utility_class |> AnyAscii.transliterate() |> prefix_char()
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

    put_obfuscated_class(short_name, class_name, allocation)
  end

  defp obfuscate_unreserved_class(
         "phx-" <> _ = class_name,
         {classes, short_names, next_suffixes} = allocation,
         fixed_classes
       ) do
    case phx_variant_parts(class_name) do
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
          %{^class_name => ^class_name} ->
            {class_name, allocation}

          %{^class_name => other} ->
            raise "class name #{inspect(class_name)} is reserved by #{inspect(other)}"

          _ ->
            {class_name,
             {Map.put(classes, class_name, class_name), Map.put(short_names, class_name, class_name), next_suffixes}}
        end
    end
  end

  defp obfuscate_unreserved_class(class_name, allocation, _) do
    short_name =
      class_name
      |> AnyAscii.transliterate()
      |> prefix_char()

    put_obfuscated_class(short_name, class_name, allocation)
  end

  defp persisted_values(mod, key) do
    for {^key, values} <- mod.__info__(:attributes), value <- values, do: value
  end

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

  defp prefix_char([char | _]) when char in ?a..?z do
    <<char::utf8>>
  end

  defp prefix_char([char | _]) when char in ?A..?Z do
    String.downcase(<<char::utf8>>)
  end

  defp prefix_char([_ | chars]), do: prefix_char(chars)
  defp prefix_char(_), do: "c"

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

  defp put_css_variable_replacement(allocation, replacements, variable, replacement)
       when byte_size(replacement) < byte_size(variable) do
    {allocation, Map.put(replacements, variable, replacement)}
  end

  defp put_css_variable_replacement(allocation, replacements, _, _), do: {allocation, replacements}

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

  if !@precompiled? do
    defp put_manifest(manifest) do
      :ok = Manifest.put(manifest)
      :ok = Manifest.save_cached(manifest)
    end
  end

  defp put_obfuscated_class(short_name, class_name, {_, _, next_suffixes} = allocation) do
    put_obfuscated_class(short_name, class_name, allocation, Map.get(next_suffixes, short_name, 0))
  end

  defp put_obfuscated_class(short_name, class_name, {classes, short_names, next_suffixes} = allocation, count) do
    candidate = add_postfix(short_name, count)

    if Map.has_key?(short_names, candidate) do
      put_obfuscated_class(short_name, class_name, allocation, count + 1)
    else
      {candidate,
       {Map.put(classes, class_name, candidate), Map.put(short_names, candidate, class_name),
        Map.put(next_suffixes, short_name, count + 1)}}
    end
  end

  defp put_template_record(mod, records) do
    case template_module(mod) do
      {[], [], []} ->
        records

      {class_names, descriptors, fixed_class_mappings} ->
        [{mod, Enum.sort(class_names), descriptors, fixed_class_mappings} | records]
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

  defp rewrite_css(css, _, [], _, []), do: css

  defp rewrite_css(css, marker_prefix, marker_classes, classes, variable_replacements) do
    class_replacements =
      Enum.map(marker_classes, fn class_name ->
        class(Map.fetch!(classes, class_name))
      end)

    Native.finalize_css(css, marker_prefix, class_replacements, variable_replacements)
  end

  if !@precompiled? do
    defp run_manifest(static_dir) do
      case build_if_stale(static_dir) do
        :current -> :ok
        {:ok, manifest} -> put_manifest(manifest)
      end
    end
  end

  defp save_class_cache(signature, classes) do
    Cache.write_term!(class_cache_path(), {signature, classes})
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

  defp static_file(path, static_dir) do
    content = File.read!(path)
    {Files.relative_path(path, static_dir), content, Digest.hex(content)}
  end

  defp static_signature(files, assets) do
    static_signature_from_terms(files, Assets.signature_terms(assets))
  end

  defp static_signature_from_terms(files, asset_terms) do
    static_terms = Enum.map(files, fn {path, _, digest} -> {:static, path, digest} end)

    generated =
      Map.new(Config.generated(), fn {path, {module, _, _} = generator} ->
        {path, {generator, module.module_info(:md5)}}
      end)

    Digest.term({static_terms, asset_terms, encoding_profile(), generated})
  end

  defp static_source_files(static_dir) do
    root = Path.expand(static_dir)

    root
    |> Files.regular_files(:static)
    |> Enum.map(&static_file(&1, root))
  end

  defp supervisor_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
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

  defp template_records(modules) do
    modules
    |> Enum.reduce([], &put_template_record/2)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp template_records_signature(records) do
    records
    |> Enum.map(fn {mod, class_names, descriptors, fixed_class_mappings} ->
      {mod, class_names, Enum.map(descriptors, &elem(&1, 0)), fixed_class_mappings}
    end)
    |> Digest.term()
  end

  defp template_signature(modules) do
    modules
    |> template_records()
    |> template_records_signature()
  end

  defp template_snapshot(modules) do
    records = template_records(modules)
    {records, template_records_signature(records)}
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
