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
  @integrity_algorithm :sha512
  @run_lock {__MODULE__, :run}

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
  Returns the absolute path to a packaged script under `priv/scripts`.
  """
  def priv_script!(name) when is_binary(name) do
    path = Path.join([priv_dir!(), "scripts", name])

    if File.regular?(path),
      do: path,
      else: raise("could not find phoenix_asset_pipeline priv script: #{path}")
  end

  @doc """
  Rebuilds and stores the manifest unless the current manifest is already fresh.
  """
  def run do
    :global.trans(
      @run_lock,
      fn -> if current?(), do: :ok, else: put_manifest(build()) end,
      [node()],
      :infinity
    )
  end

  @doc """
  Builds a manifest from `static_dir`.

  The returned manifest is a plain map suitable for
  `PhoenixAssetPipeline.Manifest.put/1`,
  `PhoenixAssetPipeline.Manifest.save_cached/1`, or
  `PhoenixAssetPipeline.Manifest.save_precompiled!/1`.
  """
  def build(static_dir \\ static_dir()) do
    modules = application_modules()
    {files, static_signature} = static_snapshot(static_dir)
    {template_classes, template_signature} = template_snapshot(modules)

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

    classes =
      styles
      |> Enum.flat_map(&elem(&1, 2))
      |> Enum.concat(template_classes)
      |> Enum.frequencies()
      |> Enum.sort_by(&{-elem(&1, 1), elem(&1, 0)})
      |> Enum.reduce(%{}, &(&1 |> elem(0) |> obfuscate_class(&2) |> elem(1)))
      |> Map.new(&{elem(&1, 1), elem(&1, 0)})

    class_descriptors = resolved_class_descriptors(modules, classes)

    [{images, image_sources}, {scripts, script_tags}, style_tags, static_files] =
      [
        fn ->
          Enum.reduce(images, {%{}, %{}}, fn {path, js}, {images, image_sources} ->
            extname = Path.extname(path)
            digest = digest(js)
            digested_path = digested_path(path, digest, extname)

            {
              Map.put(images, digested_path, %{
                content_type: MIME.from_path(path),
                data: encode(js),
                digest: digest
              }),
              Map.put(image_sources, path, %{digest: digest, path: "/" <> digested_path})
            }
          end)
        end,
        fn ->
          Enum.reduce(scripts, {%{}, %{}}, fn {path, js}, {scripts, script_tags} ->
            digest = digest(js)
            digested_path = digested_path(path, digest, ".js")

            {
              Map.put(scripts, digested_path, %{
                content_type: MIME.from_path(digested_path),
                data: encode(js),
                digest: digest
              }),
              Map.put(script_tags, path, %{digest: digest, integrity: integrity(js), path: "/" <> digested_path})
            }
          end)
        end,
        fn ->
          Map.new(styles, fn {path, css, class_names} ->
            css = Enum.reduce(class_names, css, &replace_class(&2, &1, classes))
            {path, %{content: css, digest: digest(css), integrity: integrity(css)}}
          end)
        end,
        fn ->
          Map.new(static_files, fn {path, content} ->
            digest = digest(content)

            {
              path,
              %{
                content_type: MIME.from_path(path),
                data: encode_static(content),
                digest: digest
              }
            }
          end)
        end
      ]
      |> Enum.map(&Task.async/1)
      |> Task.await_many(:infinity)

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

  defp asset_digest(static_signature, classes) do
    {static_signature, Enum.sort(classes)}
    |> :erlang.term_to_binary()
    |> digest()
    |> String.slice(0, 8)
  end

  defp class(class_name), do: "." <> css_escape(class_name)

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

  defp digested_path(_, digest, extname), do: digest <> extname

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

  defp etag(content), do: ~s("#{digest(content)}")

  defp current_static_signature do
    static_dir = static_dir()

    static_dir
    |> static_paths()
    |> Enum.sort()
    |> Enum.map(&static_file(&1, static_dir))
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

  defp replace_class(css, class_name, classes) do
    case Map.get(classes, class_name) do
      nil -> css
      short_name -> String.replace(css, class(class_name), class(short_name), global: false)
    end
  end

  defp resolved_class_descriptors(modules, classes) do
    Enum.reduce(modules, %{}, &put_resolved_class_descriptors(&1, &2, classes))
  end

  defp put_manifest(manifest) do
    :ok = Manifest.put(manifest)
    :ok = Manifest.save_cached(manifest)
  end

  defp signature(static_signature, template_signature) do
    {static_signature, template_signature}
    |> :erlang.term_to_binary()
    |> digest()
  end

  @doc """
  Returns the configured static directory as an absolute path.
  """
  def static_dir, do: Config.static_dir()

  defp static_file(path, static_dir) do
    {Path.relative_to(path, static_dir), File.read!(path)}
  end

  defp static_signature(files) do
    files
    |> Enum.map(fn {path, content} -> {path, digest(content)} end)
    |> :erlang.term_to_binary()
    |> digest()
  end

  defp static_paths(static_dir) do
    for path <- Path.wildcard(Path.join(static_dir, "**/*")),
        File.regular?(path),
        Path.relative_to(path, static_dir) != Manifest.cache_relative_path(),
        do: path
  end

  defp static_snapshot(static_dir) do
    files =
      static_dir
      |> static_paths()
      |> Enum.sort()
      |> Enum.map(&static_file(&1, static_dir))

    {files, static_signature(files)}
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
