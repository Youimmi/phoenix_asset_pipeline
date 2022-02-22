defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  import PhoenixAssetPipeline.Utils, only: [normalize: 1]

  @assets_path Application.compile_env(:phoenix_asset_pipeline, :assets_path, "assets")

  def assets_path, do: normalize(@assets_path)
  def css_path, do: Path.join(assets_path(), "css")
  def img_path, do: Path.join(assets_path(), "img")
  def js_path, do: Path.join(assets_path(), "js")

  def sass_extension do
    case Application.get_env(:phoenix_asset_pipeline, :sass_extension, "sass") do
      extname when extname in ["sass", "scss"] ->
        "." <> extname

      _ ->
        raise ArgumentError, """
        Invalid :sass_extension key value.
        Make sure the value in your config/config.exs file is "sass" or "scss"
        """
    end
  end

  def obfuscate_class_names? do
    case Application.get_env(:phoenix_asset_pipeline, :obfuscate_class_names, true) do
      bool when is_boolean(bool) ->
        bool

      _ ->
        raise ArgumentError, """
        Invalid :obfuscate_class_names key value.
        Make sure the value in your config/config.exs file is boolean:
        """
    end
  end
end
