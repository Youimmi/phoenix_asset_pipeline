defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  @already_compressed_extensions :phoenix_asset_pipeline
                                 |> Application.compile_env(:already_compressed_extensions, ~w(.avif .png .webp))
                                 |> Map.new(fn extension when is_binary(extension) ->
                                   {String.downcase(extension), true}
                                 end)
  @assets_dir Application.compile_env(:phoenix_asset_pipeline, :assets_dir, "assets")
  @manifest_mode Application.compile_env(:phoenix_asset_pipeline, :manifest_mode, :cached)
  @otp_app Application.compile_env!(:phoenix_asset_pipeline, :otp_app)
  @static_dir Application.compile_env(:phoenix_asset_pipeline, :static_dir, "priv/static")
  @svg_sprites Application.compile_env(:phoenix_asset_pipeline, :svg_sprites, [])
  @endpoint_key {__MODULE__, :endpoint}
  @endpoint_missing :__phoenix_asset_pipeline_endpoint_missing__

  if @manifest_mode not in [:cached, :precompiled] do
    raise ArgumentError, ":manifest_mode for :phoenix_asset_pipeline must be :cached or :precompiled"
  end

  def already_compressed_extensions, do: @already_compressed_extensions

  def assets_dir, do: Path.expand(@assets_dir)

  def application_ebin_dir do
    case :code.lib_dir(otp_app()) do
      path when is_list(path) -> path |> List.to_string() |> Path.join("ebin")
      _ -> nil
    end
  end

  def build_path, do: Path.expand(mix_project_build_path() || Path.join(["_build", to_string(mix_env())]))

  def colocated_dir do
    Path.join([build_path(), "phoenix-colocated", to_string(otp_app())])
  end

  def endpoint do
    case :persistent_term.get(@endpoint_key, @endpoint_missing) do
      @endpoint_missing ->
        endpoint = Application.get_env(:phoenix_asset_pipeline, :endpoint)
        if is_atom(endpoint) and not is_nil(endpoint), do: :persistent_term.put(@endpoint_key, endpoint)
        endpoint

      endpoint ->
        endpoint
    end
  end

  def endpoint! do
    endpoint() ||
      raise "missing :endpoint config for :phoenix_asset_pipeline"
  end

  def js_drop do
    :phoenix_asset_pipeline
    |> Application.get_env(:js_drop, [])
    |> normalize_js_drop()
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

  def manifest_mode, do: @manifest_mode

  def manifest_cache_dir do
    build_path()
    |> Path.join("phoenix_asset_pipeline")
    |> Path.expand()
  end

  def otp_app, do: @otp_app
  def project_dir, do: Path.dirname(assets_dir())
  def static_dir, do: Path.expand(@static_dir)
  def svg_sprites, do: @svg_sprites

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

  defp mix_env do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0),
      do: Mix.env(),
      else: :prod
  rescue
    _ -> :prod
  catch
    :exit, _ -> :prod
  end

  defp mix_project_build_path do
    if Code.ensure_loaded?(Mix.Project) do
      config = Mix.Project.config()
      if config[:app], do: Mix.Project.build_path(config)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp normalize_js_drop(values) when is_list(values), do: Enum.map(values, &normalize_js_drop_value/1)

  defp normalize_js_drop_value(value) when is_atom(value), do: to_string(value)
  defp normalize_js_drop_value(value) when is_binary(value), do: value
end
