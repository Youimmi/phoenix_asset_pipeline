defmodule PhoenixAssetPipeline.ViewHelpers do
  @moduledoc """
  A helpers for serving static assets.

  Provides helpers for views

    * image_tag/2

    * style_tag/1

    * script_tag/2

  for phoenix_asset_pipeline assets

  ## Integrate in Phoenix
  The simplest way to add the helpers to Phoenix is a `import PhoenixAssetPipeline.ViewHelpers`
  either in your `my_app_web.ex` under views to have it available under every views,
  or under for example `App.LayoutView` to have it available in your layout.

    defmodule MyAppWeb do
      def view do
        quote do
          use Phoenix.View,
            root: "lib/my_app_web/templates",
            namespace: MyAppWeb

          # Import convenience functions from controllers
          import Phoenix.Controller, only: [get_flash: 1, get_flash: 2, view_module: 1]

          # Include shared imports and aliases for views
          unquote(view_helpers())
        end
      end

      defp view_helpers do
        quote do
          # Use all HTML functionality (forms, tags, etc)
          use Phoenix.HTML

          import PhoenixAssetPipeline.ViewHelpers
        end
      end
    end
  """

  import Phoenix.HTML.Tag, only: [content_tag: 3, img_tag: 1]
  alias PhoenixAssetPipeline.Pipelines.Sass

  def image_tag(conn, path) do
    img_tag("#{conn.scheme}://#{conn.host}:4001/img/#{path}")
  end

  def style_tag(path, html_opts \\ []) do
    content_tag(:style, {:safe, Sass.new(path)}, html_opts)
  end

  def script_tag(conn, path, html_opts \\ []) do
    asset_provider =
      case Application.fetch_env(:phoenix_asset_pipeline, :asset_provider) do
        {:ok, value} -> value
        :error -> PhoenixAssetPipeline.AssetProvider
      end

    {_, digest, integrity} = apply(asset_provider, :coffeescript_new, [path])

    opts =
      html_opts
      |> Keyword.put_new(:integrity, "sha384-" <> integrity)
      |> Keyword.put_new(:src, "#{conn.scheme}://#{conn.host}:4001/js/#{path}-#{digest}.js")

    content_tag(:script, "", opts)
  end
end
