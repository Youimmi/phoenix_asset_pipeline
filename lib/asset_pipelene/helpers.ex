defmodule AssetPipeline.Helpers do
  import Phoenix.HTML.Tag
  alias AssetPipeline.Compilers.Sass
  alias Plug.Conn

  @assets_url Application.compile_env(:asset_pipeline, :assets_url)
  @port Application.compile_env(:asset_pipeline, :port, 4001)

  if Code.ensure_compiled(Phoenix.LiveView) do
    def assign_assets_url(socket, %{"assets_url" => assets_url}) do
      Phoenix.LiveView.assign_new(socket, :assets_url, fn -> assets_url end)
    end

    def assign_assets_url(socket, _session), do: socket
  end

  def base_url(conn) do
    @assets_url || "#{conn.scheme}://#{conn.host}:#{@port}"
  end

  def image_tag(_, _, _ \\ [])

  def image_tag(%Conn{} = conn, path, opts) do
    image_tag(base_url(conn), path, opts)
  end

  def image_tag(assets_url, path, opts) do
    img_tag("#{assets_url}/img/#{path}", opts)
  end

  def script_tag(_, _, _ \\ [])

  def script_tag(%Conn{} = conn, path, opts) do
    script_tag(base_url(conn), path, opts)
  end

  def script_tag(_assets_url, _path, _opts) do
  end

  def style_tag(path, opts \\ []) do
    content_tag(:style, {:safe, Sass.new(path)}, opts)
  end
end
