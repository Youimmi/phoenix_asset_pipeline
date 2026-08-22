import Config

manifest_mode =
  case config_env() do
    :dev -> :cached
    :test -> :cached
    :prod -> :precompiled
  end

config :phoenix_asset_pipeline,
  bun_version: "1.4.0",
  image_densities: [1, 2],
  image_max_pixels: 40_000_000,
  image_stylesheet: "app.css",
  manifest_mode: manifest_mode,
  otp_app: :phoenix_asset_pipeline
