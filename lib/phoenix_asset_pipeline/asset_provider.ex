defmodule PhoenixAssetPipeline.AssetProvider do
  @moduledoc false

  alias PhoenixAssetPipeline.Pipelines.CoffeeScript

  def coffeescript_new(path), do: CoffeeScript.new(path)

  defmodule Precompiler do
    @moduledoc """
    Usage:

    1. Add module:

    ```
    defmodule MyAppWeb.AssetProvider do
      use PhoenixAssetPipeline.AssetProvider.Precompiler, coffeescript: ["app", "admin"]
    end
    ```

    2. Specify module in config/prod.exs:

    ```
    config :phoenix_asset_pipeline, :asset_provider, MyAppWeb.AssetProvider
    ```
    """

    defmacro __using__(opts) do
      coffeescripts = opts[:coffeescript] || []

      for path <- coffeescripts do
        {js, digest, integrity} = CoffeeScript.new(path)

        quote do
          def coffeescript_new(unquote(path)) do
            {unquote(js), unquote(digest), unquote(integrity)}
          end
        end
      end

      quote do
        def coffeescript_new(path), do: CoffeeScript.new(path)
      end
    end
  end
end
