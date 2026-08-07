defmodule PhoenixAssetPipeline.HTML.Engine do
  @moduledoc """
  Phoenix template engine that compiles HEEx through PhoenixAssetPipeline.

  Configure it with:

      config :phoenix,
        template_engines: [heex: PhoenixAssetPipeline.HTML.Engine]
  """

  @behaviour Phoenix.Template.Engine

  alias PhoenixAssetPipeline.HTML.ClassAttrs
  alias PhoenixAssetPipeline.HTML.Minifier

  @impl true
  def compile(path, _) do
    quote do
      require unquote(__MODULE__)

      unquote(__MODULE__).compile(unquote(path))
    end
  end

  defmacro compile(path) do
    options = [
      caller: __CALLER__,
      engine: Phoenix.LiveView.Engine,
      file: path,
      line: 1,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      trim: true
    ]

    path
    |> File.read!()
    |> ClassAttrs.compile(options)
    |> Minifier.minify_rendered_static()
  end
end
