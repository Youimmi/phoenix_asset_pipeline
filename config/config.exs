# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :dart_sass, :version, "1.49.8"

config :esbuild, :version, "0.14.23"

config :phoenix, :json_library, Jason

config :phoenix_asset_pipeline, :assets_path, "priv/css"
config :phoenix_asset_pipeline, :obfuscate_class_names, false
config :phoenix_asset_pipeline, :subresource_integrity_length, 256
