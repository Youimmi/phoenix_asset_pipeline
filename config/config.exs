# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dart_sass, :version, "1.57.1"
config :esbuild, :version, "0.17.3"
config :phoenix, :json_library, Jason
config :phoenix_asset_pipeline, :assets_path, "priv"
config :phoenix_asset_pipeline, :server, false
