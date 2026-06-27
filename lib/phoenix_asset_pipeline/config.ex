defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  @assets_dir Application.compile_env(:phoenix_asset_pipeline, :assets_dir, "assets")
  @otp_app Application.compile_env(:phoenix_asset_pipeline, :otp_app, nil)
  @static_dir Application.compile_env(:phoenix_asset_pipeline, :static_dir, "priv/static")

  def assets_dir, do: Path.expand(@assets_dir)

  def build_path, do: Path.expand(mix_project_build_path() || Path.join(["_build", Atom.to_string(mix_env())]))

  def colocated_dir do
    Path.join([build_path(), "phoenix-colocated", Atom.to_string(otp_app())])
  end

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

  def manifest_cache_dir do
    build_path()
    |> Path.join("phoenix_asset_pipeline")
    |> Path.expand()
  end

  def otp_app, do: @otp_app || endpoint_otp_app(endpoint()) || :phoenix_asset_pipeline
  def precompiled_manifest?, do: Application.get_env(:phoenix_asset_pipeline, :precompiled_manifest, false)
  def project_dir, do: Path.dirname(assets_dir())
  def static_dir, do: Path.expand(@static_dir)

  def watcher? do
    endpoint = endpoint()

    is_atom(endpoint) and
      endpoint
      |> endpoint_config()
      |> Keyword.get(:code_reloader, false)
  end

  defp endpoint_config(endpoint) do
    Application.get_env(otp_app(), endpoint, [])
  end

  defp endpoint_config_otp_app(endpoint) do
    if Code.ensure_loaded?(endpoint) and function_exported?(endpoint, :config, 1) do
      case endpoint.config(:otp_app) do
        otp_app when is_atom(otp_app) -> otp_app
        _ -> nil
      end
    end
  rescue
    _ -> nil
  end

  defp endpoint_otp_app(endpoint) when is_atom(endpoint) and not is_nil(endpoint) do
    endpoint_config_otp_app(endpoint) || inferred_endpoint_otp_app(endpoint)
  end

  defp endpoint_otp_app(_), do: nil

  defp inferred_endpoint_otp_app(endpoint) do
    case Module.split(endpoint) do
      [root | _] ->
        root
        |> String.trim_trailing("Web")
        |> Macro.underscore()
        |> String.to_atom()

      _ ->
        nil
    end
  end

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      Mix.env()
    else
      :prod
    end
  rescue
    _ -> :prod
  end

  defp mix_project_build_path do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      Mix.Project.build_path()
    end
  rescue
    _ -> nil
  end
end
