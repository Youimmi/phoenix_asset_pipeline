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

  @encodings [
    {"br", %{quality: 11}},
    {"deflate", %{window_bits: 15}},
    {"gzip", %{window_bits: 31}},
    {"zstd", %{compressionLevel: 22}}
  ]
  @encoded_data_key_count length(@encodings) + 1
  @class_cache_file "classes.term"
  @class_cache_version 1
  @encoded_asset_cache_file "encoded_assets.term"
  @encoded_asset_cache_version 1
  @integrity_algorithm :sha512
  @run_lock {__MODULE__, :run}

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
    {template_classes, template_signature} = template_snapshot(modules)

    build_manifest(modules, files, static_signature, template_classes, template_signature)
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
  def run do
    :global.trans(
      @run_lock,
      fn -> run_manifest(static_dir()) end,
      [node()],
      :infinity
    )
  end

  @doc false
  def source_snapshot(static_dir \\ static_dir()) do
    static_files = static_source_files(static_dir)

    files =
      static_files
      |> Enum.concat(Assets.build())
      |> unique_files()

    {files, static_signature(static_files)}
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

  defp build_manifest(modules, files, static_signature, template_classes, template_signature) do
    {images, scripts, styles, static_files} =
      Enum.reduce(files, {[], [], [], []}, fn
        {"assets/css/" <> path, content}, {images, scripts, styles, static_files} ->
          css =
            content
            |> trim_comments()
            |> Native.minify_css()

          class_names = Native.extract_class_names_from_css(css)

          {images, scripts, [{path, css, class_names} | styles], static_files}

        {"assets/js/" <> path, content}, {images, scripts, styles, static_files} ->
          {images, [{path, content} | scripts], styles, static_files}

        {"assets/img/" <> path, content}, {images, scripts, styles, static_files} ->
          {[{path, content} | images], scripts, styles, static_files}

        {"assets/svg/" <> path, content}, {images, scripts, styles, static_files} ->
          {[{path, content} | images], scripts, styles, static_files}

        asset, {images, scripts, styles, static_files} ->
          {images, scripts, styles, [asset | static_files]}
      end)

    class_counts =
      styles
      |> Enum.flat_map(&elem(&1, 2))
      |> Enum.concat(template_classes)
      |> Enum.frequencies()
      |> Enum.sort_by(&{-elem(&1, 1), elem(&1, 0)})

    classes = cached_classes(class_counts)

    class_descriptors = resolved_class_descriptors(modules, classes)

    encoded_asset_cache = read_encoded_asset_cache()

    [
      {{images, image_sources}, {image_cache, image_cache_changed?}},
      {{scripts, script_tags}, {script_cache, script_cache_changed?}},
      style_tags,
      {static_files, {static_cache, static_cache_changed?}}
    ] =
      [
        fn ->
          Enum.reduce(images, {{%{}, %{}}, {%{}, false}}, fn {path, js}, {{images, image_sources}, cache} ->
            extname = Path.extname(path)
            digest = digest(js)
            digested_path = digested_path(digest, extname)
            {data, cache} = cached_encoded_data(encoded_asset_cache, cache, digest, js)

            {
              {
                Map.put(images, digested_path, %{
                  content_type: MIME.from_path(path),
                  data: data,
                  digest: digest
                }),
                Map.put(image_sources, path, %{digest: digest, path: "/" <> digested_path})
              },
              cache
            }
          end)
        end,
        fn ->
          Enum.reduce(scripts, {{%{}, %{}}, {%{}, false}}, fn {path, js}, {{scripts, script_tags}, cache} ->
            digest = digest(js)
            digested_path = digested_path(digest, ".js")
            {data, cache} = cached_encoded_data(encoded_asset_cache, cache, digest, js)
            {integrity, cache} = cached_integrity(encoded_asset_cache, cache, digest, js)

            {
              {
                Map.put(scripts, digested_path, %{
                  content_type: MIME.from_path(digested_path),
                  data: data,
                  digest: digest
                }),
                Map.put(script_tags, path, %{digest: digest, integrity: integrity, path: "/" <> digested_path})
              },
              cache
            }
          end)
        end,
        fn ->
          Map.new(styles, fn {path, css, class_names} ->
            css = rewrite_classes(css, class_names, classes)
            {path, %{content: css, digest: digest(css), integrity: integrity(css)}}
          end)
        end,
        fn ->
          Enum.reduce(static_files, {%{}, {%{}, false}}, fn {path, content}, {static_files, cache} ->
            digest = digest(content)
            {data, cache} = cached_static_data(encoded_asset_cache, cache, digest, content)

            {
              Map.put(static_files, path, %{
                content_type: MIME.from_path(path),
                data: data,
                digest: digest
              }),
              cache
            }
          end)
        end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(:infinity)

    save_encoded_asset_cache(
      image_cache,
      script_cache,
      static_cache,
      encoded_asset_cache,
      image_cache_changed? or script_cache_changed? or static_cache_changed?
    )

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
    |> Enum.flat_map(&application_modules/1)
    |> Enum.uniq()
  end

  defp application_modules(app) do
    app
    |> Application.spec(:modules)
    |> List.wrap()
  end

  defp maybe_add_watcher(children, true), do: children ++ [PhoenixAssetPipeline.Watcher]
  defp maybe_add_watcher(children, _), do: children

  defp asset_digest(static_signature, classes) do
    {static_signature, Enum.sort(classes)}
    |> :erlang.term_to_binary()
    |> digest()
    |> String.slice(0, 8)
  end

  defp class(class_name), do: "." <> css_escape(class_name)

  defp class_replacements(class_names, classes) do
    Enum.reduce(class_names, %{}, fn class_name, replacements ->
      case Map.get(classes, class_name) do
        nil -> replacements
        short_name -> Map.put_new(replacements, class(class_name), class(short_name))
      end
    end)
  end

  defp build_classes(class_counts) do
    class_counts
    |> Enum.reduce(%{}, &(&1 |> elem(0) |> obfuscate_class(&2) |> elem(1)))
    |> Map.new(&{elem(&1, 1), elem(&1, 0)})
  end

  defp cached_classes(class_counts) do
    signature = class_signature(class_counts)

    case read_class_cache() do
      %{signature: ^signature, classes: classes} when is_map(classes) ->
        classes

      _ ->
        classes = build_classes(class_counts)
        save_class_cache(signature, classes)
        classes
    end
  end

  defp class_cache_path do
    Path.join(Config.manifest_cache_dir(), @class_cache_file)
  end

  defp class_signature(class_counts) do
    class_counts
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp cached(cache, {next_cache, changed?}, key, fun) do
    case Map.fetch(cache, key) do
      {:ok, value} -> {value, {Map.put(next_cache, key, value), changed?}}
      :error -> put_cached({next_cache, true}, key, fun.())
    end
  end

  defp cached_encoded_data(cache, next_cache, digest, content) do
    cached(cache, next_cache, {:encoded, digest}, fn -> encode(content) end)
  end

  defp cached_integrity(cache, next_cache, digest, content) do
    cached(cache, next_cache, {:integrity, @integrity_algorithm, digest}, fn -> integrity(content) end)
  end

  defp cached_static_data(cache, next_cache, digest, content) do
    cached(cache, next_cache, {:static, digest}, fn -> encode_static(content) end)
  end

  defp compress("br", content, %{quality: quality}) do
    content
    |> Native.compress(quality)
    |> IO.iodata_to_binary()
  end

  defp compress("zstd", content, opts) do
    content
    |> :zstd.compress(opts)
    |> IO.iodata_to_binary()
  end

  defp compress(_, content, %{window_bits: window_bits}) do
    zstream = :zlib.open()

    try do
      :zlib.deflateInit(zstream, :best_compression, :deflated, window_bits, 9, :default)
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

  defp digested_path(digest, extname), do: digest <> extname

  defp encode(content) do
    encode_with_size = &{&1, byte_size(&1)}

    data =
      @encodings
      |> Task.async_stream(
        fn {encoding, opts} -> {encoding, encode_with_size.(compress(encoding, content, opts))} end,
        max_concurrency: System.schedulers_online(),
        ordered: false,
        timeout: :infinity
      )
      |> Enum.reduce(%{"raw" => encode_with_size.(content)}, &put_encoded_data!/2)

    if map_size(data) == @encoded_data_key_count,
      do: data,
      else: raise("could not encode asset with all configured encodings")
  end

  defp put_encoded_data!({:ok, {encoding, encoded}}, data), do: Map.put(data, encoding, encoded)

  defp put_encoded_data!({:exit, reason}, _) do
    raise "could not encode asset with all configured encodings: #{inspect(reason)}"
  end

  defp encode_static(content) do
    Map.new(encode(content), fn {encoding, {encoded, byte_size}} ->
      {encoding, {encoded, byte_size, etag(encoded)}}
    end)
  end

  defp encoded_asset_cache_path do
    Path.join(Config.manifest_cache_dir(), @encoded_asset_cache_file)
  end

  defp etag(content), do: ~s("#{digest(content)}")

  defp current_static_signature do
    static_dir()
    |> static_source_files()
    |> static_signature()
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

    to_string(@integrity_algorithm) <> "-" <> hash
  end

  defp put_cached({cache, changed?}, key, value), do: {value, {Map.put(cache, key, value), changed?}}

  defp read_class_cache do
    Cache.read_term(class_cache_path(), :error, fn
      %{version: @class_cache_version, signature: signature, classes: classes}
      when is_binary(signature) and is_map(classes) ->
        {:ok, %{classes: classes, signature: signature}}

      _ ->
        :error
    end)
  end

  defp read_encoded_asset_cache do
    Cache.read_term(encoded_asset_cache_path(), %{}, fn
      %{version: @encoded_asset_cache_version, assets: cache} when is_map(cache) -> {:ok, cache}
      _ -> :error
    end)
  end

  defp save_encoded_asset_cache(image_cache, script_cache, static_cache, old_cache, changed?) do
    if changed? or map_size(image_cache) + map_size(script_cache) + map_size(static_cache) != map_size(old_cache) do
      cache =
        image_cache
        |> Map.merge(script_cache)
        |> Map.merge(static_cache)

      Cache.write_term!(encoded_asset_cache_path(), %{assets: cache, version: @encoded_asset_cache_version})
    else
      :ok
    end
  end

  defp save_class_cache(signature, classes) do
    Cache.write_term!(class_cache_path(), %{classes: classes, signature: signature, version: @class_cache_version})
  end

  defp obfuscate_class(_, _, _ \\ 0)

  defp obfuscate_class("phx-" <> _ = class_name, short_names, _) do
    case phx_variant_parts(class_name) do
      {variant_class, utility_class} ->
        obfuscate_phx_variant_class(class_name, variant_class, utility_class, short_names)

      :error ->
        {class_name, Map.put(short_names, class_name, class_name)}
    end
  end

  defp obfuscate_class(class_name, short_names, count) do
    short_name =
      class_name
      |> AnyAscii.transliterate()
      |> prefix_char()
      |> add_postfix(count)

    case Map.get(short_names, short_name) do
      nil -> {short_name, Map.put(short_names, short_name, class_name)}
      ^class_name -> {short_name, short_names}
      _ -> obfuscate_class(class_name, short_names, count + 1)
    end
  end

  defp obfuscate_phx_variant_class(class_name, variant_class, utility_class, short_names) do
    {variant_short_name, short_names} = obfuscate_class(variant_class, short_names)
    {utility_short_name, short_names} = obfuscate_class(utility_class, short_names)
    short_name = variant_short_name <> ":" <> utility_short_name

    {short_name, Map.put(short_names, short_name, class_name)}
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
    case String.split(class_name, ":", parts: 2) do
      [variant_class, utility_class] when utility_class != "" -> {variant_class, utility_class}
      _ -> :error
    end
  end

  defp put_resolved_class_descriptors(mod, descriptors, classes) do
    if Code.ensure_loaded?(mod) and function_exported?(mod, :__class_descriptors__, 0) do
      module_name = Atom.to_string(mod)

      Enum.reduce(mod.__class_descriptors__(), descriptors, fn {id, descriptor_hash, descriptor}, descriptors ->
        Map.put(
          descriptors,
          {module_name, id, descriptor_hash},
          PhoenixAssetPipeline.Helpers.build_class_descriptor(descriptor, classes)
        )
      end)
    else
      descriptors
    end
  end

  defp resolved_class_descriptors(modules, classes) do
    Enum.reduce(modules, %{}, &put_resolved_class_descriptors(&1, &2, classes))
  end

  defp rewrite_classes(css, class_names, classes) do
    replacements = class_replacements(class_names, classes)

    if map_size(replacements) == 0 do
      css
    else
      pattern =
        replacements
        |> Map.keys()
        |> Enum.sort_by(&byte_size/1, :desc)
        |> Enum.map_join("|", &Regex.escape/1)

      regex = Regex.compile!(pattern)

      Regex.replace(regex, css, &Map.fetch!(replacements, &1))
    end
  end

  defp put_manifest(manifest) do
    :ok = Manifest.put(manifest)
    :ok = Manifest.save_cached(manifest)
  end

  defp run_manifest(static_dir) do
    modules = application_modules()
    static_files = static_source_files(static_dir)
    static_signature = static_signature(static_files)
    {template_classes, template_signature} = template_snapshot(modules)
    manifest_signature = signature(static_signature, template_signature)

    if Manifest.get(:signature) == manifest_signature do
      :ok
    else
      files =
        static_files
        |> Enum.concat(Assets.build())
        |> unique_files()

      modules
      |> build_manifest(files, static_signature, template_classes, template_signature)
      |> put_manifest()
    end
  end

  defp signature(static_signature, template_signature) do
    {static_signature, template_signature}
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp static_file(path, static_dir) do
    {Path.relative_to(path, static_dir), File.read!(path)}
  end

  defp static_entry(_, "." <> _), do: []

  defp static_entry(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) -> static_paths_in(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  defp static_signature(files) do
    files
    |> Enum.map(fn {path, content} -> {:static, path, digest(content)} end)
    |> Enum.concat(Assets.signature_terms())
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp static_paths(static_dir) do
    static_dir
    |> Path.expand()
    |> static_paths_in()
    |> Enum.sort()
  end

  defp static_paths_in(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &static_entry(dir, &1))
      {:error, _} -> []
    end
  end

  defp static_source_files(static_dir) do
    static_dir
    |> static_paths()
    |> Enum.map(&static_file(&1, static_dir))
  end

  defp supervisor_name(opts) do
    case Keyword.get(opts, :name) do
      nil -> []
      name -> [name: name]
    end
  end

  defp unique_files(files) do
    files
    |> Enum.reduce(%{}, fn {path, content}, acc -> Map.put(acc, path, content) end)
    |> Enum.sort()
  end

  defp template_signature(modules) do
    modules
    |> template_signature_terms()
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp template_signature_terms(modules) do
    modules
    |> Enum.reduce([], &put_template_signature_term/2)
    |> Enum.sort()
  end

  defp template_snapshot(modules) do
    {classes, terms} =
      Enum.reduce(modules, {[], []}, fn mod, {classes, terms} ->
        case template_module(mod) do
          {[], []} ->
            {classes, terms}

          {class_names, descriptors} ->
            {class_names ++ classes, [{mod, Enum.sort(class_names), descriptors} | terms]}
        end
      end)

    signature =
      terms
      |> Enum.sort()
      |> :erlang.term_to_binary()
      |> digest()

    {classes, signature}
  end

  defp put_template_signature_term(mod, terms) do
    case template_module(mod) do
      {[], []} -> terms
      {class_names, descriptors} -> [{mod, Enum.sort(class_names), descriptors} | terms]
    end
  end

  defp template_module(mod) do
    if Code.ensure_loaded?(mod) do
      {
        exported_value(mod, :class_names),
        exported_value(mod, :__class_descriptors__)
      }
    else
      {[], []}
    end
  end

  defp exported_value(mod, fun) do
    if function_exported?(mod, fun, 0),
      do: apply(mod, fun, []),
      else: []
  end

  defp trim_comments("/*! tailwindcss" <> _ = css) do
    css
    |> String.replace(~r{^/\*!.*?\*/\s*}s, "")
    |> trim_comments()
  end

  defp trim_comments(css), do: String.trim(css)
end
