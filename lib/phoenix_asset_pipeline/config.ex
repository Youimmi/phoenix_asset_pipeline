defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  @otp_app Application.compile_env(:phoenix_asset_pipeline, :otp_app, :phoenix_asset_pipeline)
  @static_dir Application.compile_env(:phoenix_asset_pipeline, :static_dir, "priv/static")

  def endpoint, do: Application.get_env(:phoenix_asset_pipeline, :endpoint)

  def endpoint! do
    endpoint() ||
      raise "missing :endpoint config for :phoenix_asset_pipeline"
  end

  def live_reload_event do
    Application.get_env(:phoenix_asset_pipeline, :live_reload_event, "assets_change")
  end

  def live_reload_payload do
    Application.get_env(:phoenix_asset_pipeline, :live_reload_payload, %{asset_type: "page"})
  end

  def live_reload_topic do
    Application.get_env(:phoenix_asset_pipeline, :live_reload_topic, "phoenix:live_reload")
  end

  def otp_app, do: @otp_app
  def static_dir, do: Path.expand(@static_dir)
end
