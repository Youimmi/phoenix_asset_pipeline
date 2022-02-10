defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc false

  import Phoenix.HTML.Tag
  import PhoenixAssetPipeline.Obfuscator
  alias PhoenixAssetPipeline.{Compilers.Sass, Utils}
  # alias Plug.Conn

  # @assets_url Application.compile_env(:phoenix_asset_pipeline, :assets_url)
  # @port Application.compile_env(:asset_pipeline, :port, 4001)

  # if Code.ensure_compiled(Phoenix.LiveView) do
  #   def assign_assets_url(socket, %{"assets_url" => assets_url}) do
  #     Phoenix.LiveView.assign_new(socket, :assets_url, fn -> assets_url end)
  #   end

  #   def assign_assets_url(socket, _session), do: socket
  # end

  # def base_url(conn) do
  #   @assets_url || "#{conn.scheme}://#{conn.host}:#{@port}"
  # end

  # def image_tag(_, _, _ \\ [])

  # def image_tag(%Conn{} = conn, path, opts) do
  #   image_tag(base_url(conn), path, opts)
  # end

  # def image_tag(assets_url, path, opts) do
  #   img_tag("#{assets_url}/img/#{path}", opts)
  # end

  # def script_tag(_, _, _ \\ [])

  # def script_tag(%Conn{} = conn, path, opts) do
  #   script_tag(base_url(conn), path, opts)
  # end

  # def script_tag(_assets_url, _path, _opts) do
  # end

  defmacro class(name) when is_binary(name) do
    classes =
      name
      |> String.split(" ", trim: true)
      |> Enum.reduce("", fn class_name, classes ->
        classes <> " " <> obfuscate(class_name)
      end)
      |> String.trim()

    [class: classes]
  end

  defmacro class(_), do: []

  defmacro style_tag(path, html_opts \\ []) do
    content_tag(:style, {:safe, Sass.new(path)}, html_opts)
  end

  defmacro __using__(_opts) do
    quote do
      import PhoenixAssetPipeline.Helpers

      unless Application.get_env(:phoenix_asset_pipeline, :release, false) do
        Module.register_attribute(__MODULE__, :external_resource, accomulate: true)

        for file <- Path.wildcard("../Mia/" <> Utils.assets_path() <> "/**/*.{sass, scss}") do
          Module.put_attribute(__MODULE__, :external_resource, file)
        end
      end
    end
  end
end
