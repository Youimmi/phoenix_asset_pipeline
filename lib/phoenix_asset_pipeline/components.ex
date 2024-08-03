# defmodule PhoenixAssetPipeline.Components do
#   @moduledoc false
#   # use Phoenix.Component

#   # import PhoenixAssetPipeline.Helpers
#   # require PhoenixAssetPipeline.Helpers

#   # alias PhoenixAssetPipeline.Compiler.Esbuild
#   # alias PhoenixAssetPipeline.Compiler.Sass

#   # require Esbuild
#   # require Sass

#   # attr :asset_path, :string

#   # def img(assigns) do
#   #   ~H"""
#   #   <img src="" />
#   #   """
#   # end

#   # attr :asset_path, :string, required: true
#   # attr :rest, :global, include: ~w(async crossorigin defer nomodule phx_track_static)

#   # def script(%{asset_path: path} = assigns) do
#   #   {js, integrity} = Esbuild.compile(path)

#   #   assigns =
#   #     Map.delete(assigns, :asset_path)
#   #     |> assign(content: js, integrity: integrity, src: path <> ".js")

#   #   ~H"""
#   #   <script integrity={@integrity} src={@src} {@rest}>
#   #     <%= @content %>
#   #   </script>
#   #   """
#   # end

#   # attr :asset_path, :string, required: true
#   # attr :rest, :global

#   # def style(%{asset_path: path} = assigns) do
#   #   {css, integrity} = Sass.compile(path)

#   #   assigns =
#   #     Map.delete(assigns, :asset_path)
#   #     |> assign(content: css, integrity: integrity)

#   #   ~H"""
#   #   <style integrity={@integrity} {@rest}>
#   #     <%= @content %>
#   #   </style>
#   #   """
#   # end

#   # attr :asset_path, :string, required: true
#   # attr :rest, :global

#   # def style(assigns) do
#   #   ~H"""
#   #    <%= style_tag(@asset_path, @rest) %>
#   #   """
#   # end
# end
