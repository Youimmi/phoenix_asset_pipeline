defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc false

  import Phoenix.HTML.Tag
  import PhoenixAssetPipeline.Config
  alias Phoenix.LiveView
  alias PhoenixAssetPipeline.Compilers.{Esbuild, Sass}
  alias PhoenixAssetPipeline.{Obfuscator, Utils}
  alias Plug.Conn

  @port Application.compile_env(:asset_pipeline, :port, 4001)

  defmacro __using__(_opts) do
    quote do
      import PhoenixAssetPipeline.Helpers

      if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
        for path <-
              [File.cwd!(), Utils.assets_path(), "**/*.{sass,scss}"]
              |> Path.join()
              |> Path.wildcard() do
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
      case obfuscate_class_names?() do
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
    content_tag(:style, {:safe, css}, put_integrity(opts, integrity))
  end

  if Code.ensure_compiled(LiveView) do
    def assign_assets_url(socket, %{"assets_url" => assets_url}) do
      LiveView.assign_new(socket, :assets_url, fn -> assets_url end)
    end

    def assign_assets_url(socket, _session), do: socket
  end

  def base_url(hostname) when is_binary(hostname), do: normalize_url(hostname)

  def base_url(hostname) do
    Application.get_env(:phoenix_asset_pipeline, :assets_url) || hostname
  end

  def image_tag(%Conn{} = conn, path, opts) do
    image_tag(default_hostname(conn) <> "/img/", path, opts)
  end

  def image_tag(assets_url, path, opts) when is_binary(assets_url) do
    img_tag(build_url(assets_url, "img/" <> path), opts)
  end

  defmacro script_tag(hostname, path, opts \\ []) when is_binary(path) and is_list(opts) do
    {name, opts} = Keyword.pop(opts, :name, path)
    {js, integrity} = Esbuild.new(path)

    digest =
      :erlang.md5(path)
      |> Base.encode16(case: :lower)

    dets_file = Utils.dets_file(__MODULE__) |> String.to_charlist()
    {:ok, table} = :dets.open_file(dets_file, type: :set)
    :dets.insert_new(table, {path, digest, name})
    :dets.close(dets_file)

    quote bind_quoted: [
            digest: digest,
            hostname: hostname,
            js: js,
            name: name,
            opts: put_integrity(opts, integrity)
          ] do
      content_tag(:script, {:safe, js}, put_src(opts, base_url(hostname), name, digest))
    end
  end

  def put_src(opts, %Conn{} = conn, name, digest) do
    put_src(opts, default_hostname(conn) <> "/js/", name, digest)
  end

  def put_src(opts, assets_url, name, digest)
      when is_list(opts) and
             is_binary(assets_url) and
             is_binary(name) and
             is_binary(digest) do
    Keyword.put_new(opts, :src, build_url(assets_url, name <> "-" <> digest <> ".js"))
  end

  defp build_url(hostname, path) do
    URI.merge(hostname, path) |> URI.to_string()
  end

  defp default_hostname(%Conn{} = conn) do
    "#{conn.scheme}://#{conn.host}:#{@port}"
  end

  defp normalize_url(hostname) do
    Regex.replace(~r/(\/)*$/, hostname, "") <> "/"
  end

  defp put_integrity(opts, hash) when is_list(opts) and is_binary(hash) do
    Keyword.put_new(opts, :integrity, sri_hash_algoritm() <> "-" <> hash)
  end

  defp put_integrity(opts, _), do: opts
end
