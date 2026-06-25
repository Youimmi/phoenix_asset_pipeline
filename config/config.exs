import Config

env_config = Path.expand("#{config_env()}.exs", __DIR__)

if File.regular?(env_config) do
  import_config "#{config_env()}.exs"
end
