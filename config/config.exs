import Config

manifest_mode =
  case config_env() do
    :dev -> :cached
    :test -> :cached
    :prod -> :precompiled
  end

config :phoenix_asset_pipeline,
  bun_version: "1.3.14",
  manifest_mode: manifest_mode,
  otp_app: :phoenix_asset_pipeline
