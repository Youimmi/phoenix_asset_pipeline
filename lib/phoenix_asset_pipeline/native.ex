defmodule PhoenixAssetPipeline.Native do
  @moduledoc false
  use Rustler, crate: :phoenix_asset_pipeline, otp_app: :phoenix_asset_pipeline

  def compress(_, _), do: :erlang.nif_error(:nif_not_loaded)

  def extract_class_names_from_css(_), do: :erlang.nif_error(:nif_not_loaded)

  def minify_css(_), do: :erlang.nif_error(:nif_not_loaded)
end
