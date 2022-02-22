defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc false

  import Phoenix.HTML.Tag
  alias Phoenix.LiveView
  alias PhoenixAssetPipeline.Compilers.{Esbuild, Sass}
  alias PhoenixAssetPipeline.{Config, Obfuscator, Utils}
  alias Plug.Conn

  @assets_url Application.compile_env(:phoenix_asset_pipeline, :assets_url)
  @port Application.compile_env(:asset_pipeline, :port, 4001)

  defmacro __using__(_) do
    quote do
      import PhoenixAssetPipeline.Helpers

      if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
        root = File.cwd!()

        paths = [
          Path.join([root, Config.css_path(), "**/*.{css,sass,scss}"]),
          Path.join([root, Config.img_path(), "**/*"]),
          Path.join([root, Config.js_path(), "**/*.{cjs,js,mjs,ts}"])
        ]

        for path <- Path.wildcard(paths) do
          @external_resource path
        end
      else
        def __mix_recompile__?, do: true
      end
    end
  end

  defmacro class(name) when is_binary(name) do
    classes = String.split(name, " ", trim: true)

    classes =
      case Config.obfuscate_class_names?() do
        true ->
          Enum.reduce(classes, "", fn class_name, classes ->
            classes <> " " <> Obfuscator.obfuscate(class_name)
          end)

        _ ->
          Enum.join(classes, " ")
      end
      |> String.trim()

    [class: classes]
  end

  defmacro class(_), do: []

  defmacro style_tag(path, opts \\ []) when is_binary(path) and is_list(opts) do
    {css, integrity} = Sass.new(path)
    content_tag(:style, {:safe, css}, put_integrity(integrity, opts))
  end

  defmacro image_tag(hostname, path, opts \\ []) when is_binary(path) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, Path.rootname(path))

    file_path = Path.join([File.cwd!(), Config.img_path(), path])
    content = File.read!(file_path)
    digest = Utils.digest(content)
    extname = Path.extname(file_path)

    quote bind_quoted: [
            digest: digest,
            extname: extname,
            hostname: hostname,
            name: name,
            opts: put_integrity(Utils.integrity(content), opts),
            path: path
          ] do
      opts =
        base_url(hostname, "img")
        |> src(name, digest, extname)
        |> put_src(opts)

      img_tag(Path.join(Config.img_path(), path), opts)
    end
  end

  defmacro script_tag(hostname, path, opts \\ []) when is_binary(path) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, Path.rootname(path))

    {content, integrity} = Esbuild.new(path)
    digest = Utils.digest(content)

    # dets_file = Utils.dets_file(__MODULE__) |> String.to_charlist()
    # {:ok, table} = :dets.open_file(dets_file, type: :set)
    # :dets.insert_new(table, {path, digest, name})
    # :dets.close(dets_file)

    quote bind_quoted: [
            content: content,
            digest: digest,
            hostname: hostname,
            name: name,
            opts: put_integrity(integrity, opts)
          ] do
      opts =
        base_url(hostname, "js")
        |> src(name, digest, ".js")
        |> put_src(opts)

      content_tag(:script, {:safe, content}, opts)
    end
  end

  if Code.ensure_compiled(LiveView) do
    def assign_assets_url(socket, %{"assets_url" => assets_url}) do
      LiveView.assign_new(socket, :assets_url, fn -> assets_url end)
    end

    def assign_assets_url(socket, _), do: socket
  end

  def base_url(hostname, _ \\ nil)

  def base_url(hostname, _) when is_binary(hostname) do
    Utils.normalize(hostname)
  end

  def base_url(%Conn{} = conn, path) do
    base_url(@assets_url || "#{conn.scheme}://#{conn.host}:#{@port}")
    |> URI.merge(path)
  end

  def put_src(url, opts) when is_binary(url) and is_list(opts) do
    Keyword.put_new(opts, :src, url)
  end

  def src(url, name, digest, extname) do
    "#{url}/#{name}-#{digest}#{extname}"
  end

  defp put_integrity(hash, opts) when is_binary(hash) and is_list(opts) do
    Keyword.put_new(opts, :integrity, "sha512-" <> hash)
  end

  defp put_integrity(_, opts), do: opts
end
