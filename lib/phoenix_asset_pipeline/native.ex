defmodule PhoenixAssetPipeline.Native do
  @moduledoc false
  use Rustler, crate: :phoenix_asset_pipeline, otp_app: :phoenix_asset_pipeline

  def compress(_, _), do: :erlang.nif_error(:nif_not_loaded)

  def finalize_css(css, marker_prefix, class_replacements, variable_replacements) when is_binary(css) do
    css
    |> finalize_css_nif(marker_prefix, class_replacements, variable_replacements)
    |> unwrap_css_result()
  end

  def prepare_css(css) when is_binary(css) do
    css
    |> prepare_css_nif()
    |> unwrap_css_result()
  end

  def finalize_css_nif(_, _, _, _), do: :erlang.nif_error(:nif_not_loaded)

  def prepare_css_nif(_), do: :erlang.nif_error(:nif_not_loaded)

  defp unwrap_css_result({:ok, value}), do: value
  defp unwrap_css_result({:error, reason}), do: raise(ArgumentError, reason)
end
