defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc false

  import Phoenix.HTML.Tag

  alias Phoenix.LiveView
  alias PhoenixAssetPipeline.Compilers.{Esbuild, Sass}
  alias PhoenixAssetPipeline.{Config, Obfuscator, Storage, Utils}
  alias Plug.Conn

  defmacro __using__(_) do
    Utils.dets_file(__MODULE__)
    |> File.rm()

    quote do
      import PhoenixAssetPipeline.Helpers

      if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
        root = File.cwd!()

        glob = [
          Path.join([root, Config.css_path(), "**/*.{css,sass,scss}"]),
          Path.join([root, Config.img_path(), "**/*"]),
          Path.join([root, Config.js_path(), "**/*.{cjs,js,mjs,ts}"])
        ]

        for paths <- glob, path <- Path.wildcard(paths) do
          @external_resource path
        end
      else
        def __mix_recompile__?, do: true
      end
    end
  end

  defmacro class(name) when is_binary(name) do
    classes =
      Enum.reduce(String.split(name), "", fn class_name, classes ->
        classes <> " " <> Obfuscator.obfuscate(class_name)
      end)
      |> String.trim_leading()

    [class: classes]
  end

  defmacro class(_), do: []

  defmacro style_tag(path, opts \\ []) when is_binary(path) and is_list(opts) do
    {css, integrity} = Sass.new(path)
    content_tag(:style, {:safe, css}, put_integrity(integrity, opts))
  end

  defmacro image_tag(hostname, path, opts \\ []) when is_binary(path) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, Path.rootname(path))
    {digest, extname, fragment, integrity} = cache_image(path, name)

    {srcset, opts} =
      case Keyword.pop(opts, :srcset) do
        {nil, opts} -> {nil, opts}
        {srcset, opts} -> {srcset(srcset), opts}
      end

    quote bind_quoted: [
            digest: digest,
            extname: extname,
            fragment: fragment,
            hostname: hostname,
            name: name,
            opts: put_integrity(integrity, opts),
            srcset: srcset
          ] do
      opts =
        base_url(hostname)
        |> src(name, digest, extname)
        |> maybe_add_fragment(fragment)
        |> put_src(opts)
        |> put_srcset(hostname, srcset)

      tag(:img, opts)
    end
  end

  def cache_image(path, name) when is_binary(path) do
    %{fragment: fragment, path: file_path} = URI.parse(path)
    file_path = Path.join([File.cwd!(), Config.img_path(), file_path])
    extname = Path.extname(file_path)
    content = File.read!(file_path)
    digest = Utils.digest(content)
    integrity = Utils.integrity(content)

    cache(extname, Path.rootname(name || path), digest, content)

    {digest, extname, fragment, integrity}
  end

  defmacro script_tag(hostname, path, opts \\ []) when is_binary(path) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, Path.rootname(path))
    {content, integrity} = Esbuild.new(path)
    digest = Utils.digest(content)

    cache(".js", name, digest, content)

    quote bind_quoted: [
            digest: digest,
            hostname: hostname,
            name: name,
            opts: put_integrity(integrity, opts)
          ] do
      opts =
        base_url(hostname)
        |> src(name, digest, ".js")
        |> put_src(opts)

      content_tag(:script, nil, opts)
    end
  end

  if function_exported?(LiveView, :assign_new, 3) do
    def assign_assets_url(socket, %{"assets_url" => assets_url}) do
      LiveView.assign_new(socket, :assets_url, fn -> assets_url end)
    end

    def assign_assets_url(socket, _), do: socket
  end

  def base_url(hostname) when is_binary(hostname) do
    Utils.normalize(hostname)
  end

  def base_url(%Conn{} = conn) do
    assets_url = Application.get_env(:phoenix_asset_pipeline, :assets_url)
    port = Application.get_env(:phoenix_asset_pipeline, :port, 4001)

    base_url(assets_url || "#{conn.scheme}://#{conn.host}:#{port}")
  end

  def maybe_add_fragment(url, fragment) when is_binary(fragment) and byte_size(fragment) > 0 do
    url <> "#" <> fragment
  end

  def maybe_add_fragment(url, _), do: url

  def put_src(url, opts) when is_binary(url) and is_list(opts) do
    Keyword.put_new(opts, :src, url)
  end

  def put_srcset(opts, _, srcset) when is_binary(srcset) and byte_size(srcset) > 0 do
    Keyword.put_new(opts, :srcset, srcset)
  end

  def put_srcset(opts, hostname, srcset) when is_list(srcset) and length(srcset) > 0 do
    srcset =
      Enum.map_join(srcset, ", ", fn
        [extname, name, digest, fragment, descriptor, _] ->
          src =
            base_url(hostname)
            |> src(name, digest, extname)
            |> maybe_add_fragment(fragment)

          src <> " " <> descriptor
      end)

    put_srcset(opts, hostname, srcset)
  end

  def put_srcset(opts, _, _), do: opts

  def src(url, name, digest, extname) do
    "#{url}/#{name(name)}#{digest}#{extname}"
  end

  defp cache(extname, name, digest, content) do
    {:ok, br_data} = :brotli.encode(content)
    br_extname = extname <> ".br"
    dets_file = Utils.dets_file(__MODULE__)
    table = Utils.dets_table(dets_file)

    with false <- :dets.member(table, {extname, name, digest}) do
      :dets.insert(table, {{extname, name, digest}, content})
      :dets.insert(table, {{br_extname, name, digest}, br_data})
      :dets.close(dets_file)

      Storage.put({extname, name, digest}, content)
      Storage.put({br_extname, name, digest}, br_data)
    end
  end

  defp name(""), do: ""
  defp name(name) when is_binary(name), do: name <> "-"

  defp put_integrity(hash, opts) when is_binary(hash) and is_list(opts) do
    Keyword.put_new(opts, :integrity, "sha512-" <> hash)
  end

  defp put_integrity(_, opts), do: opts

  defp srcset(srcset) when is_map(srcset) or is_list(srcset) do
    Enum.map(srcset, &srcset_src(&1))
  end

  defp srcset(srcset), do: srcset

  defp srcset_src({{path, name}, descriptor}) when is_binary(path) do
    {digest, extname, fragment, integrity} = cache_image(path, name)
    [extname, name, digest, fragment, descriptor, integrity]
  end

  defp srcset_src({path, descriptor}) when is_binary(path) do
    {digest, extname, fragment, integrity} = cache_image(path, nil)
    [extname, Path.rootname(path), digest, fragment, descriptor, integrity]
  end
end
