defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  @already_compressed_extensions :phoenix_asset_pipeline
                                 |> Application.compile_env(
                                   :already_compressed_extensions,
                                   ~w(
                                     .7z .aac .apk .avif .avi .br .bz2 .cab .dmg .docx .eot .epub .flac .gif .gz
                                     .heic .heif .ico .jar .jpeg .jpg .m4a .m4v .mov .mp3 .mp4 .ogg .ogv .opus .otf
                                     .pdf .png .pptx .rar .tgz .ttf .webm .webp .woff .woff2 .xlsx .xz .zip .zst
                                   )
                                 )
                                 |> Map.new(fn extension when is_binary(extension) ->
                                   {String.downcase(extension), true}
                                 end)
  @assets_dir Application.compile_env(:phoenix_asset_pipeline, :assets_dir, "assets")
  @generated Application.compile_env(:phoenix_asset_pipeline, :generated, %{})
  @image_densities Application.compile_env(:phoenix_asset_pipeline, :image_densities, [1, 2])
  @image_max_pixels Application.compile_env(:phoenix_asset_pipeline, :image_max_pixels, 40_000_000)
  @otp_app Application.compile_env!(:phoenix_asset_pipeline, :otp_app)
  @precompiled_manifest Application.compile_env(:phoenix_asset_pipeline, :precompiled_manifest, false)
  @public_css_variables :phoenix_asset_pipeline
                        |> Application.compile_env(:public_css_variables, [])
                        |> MapSet.new()
  @static_dir Application.compile_env(:phoenix_asset_pipeline, :static_dir, "priv/static")
  @svg_sprites Application.compile_env(:phoenix_asset_pipeline, :svg_sprites, [])
  @endpoint_key {__MODULE__, :endpoint}
  @endpoint_missing :__phoenix_asset_pipeline_endpoint_missing__

  if not is_boolean(@precompiled_manifest) do
    raise ArgumentError, ":precompiled_manifest for :phoenix_asset_pipeline must be a boolean"
  end

  if not (is_list(@image_densities) and @image_densities != [] and
            Enum.all?(@image_densities, &(is_integer(&1) and &1 > 0)) and
            @image_densities == Enum.sort(Enum.uniq(@image_densities)) and 1 in @image_densities) do
    raise ArgumentError,
          ":image_densities for :phoenix_asset_pipeline must be an ascending unique list of positive integers containing 1"
  end

  if not (is_integer(@image_max_pixels) and @image_max_pixels > 0) do
    raise ArgumentError, ":image_max_pixels for :phoenix_asset_pipeline must be a positive integer"
  end

  if not Enum.all?(@public_css_variables, &match?(<<"--", _, _::binary>>, &1)) do
    raise ArgumentError, ":public_css_variables for :phoenix_asset_pipeline must contain custom property names"
  end

  def already_compressed_extensions, do: @already_compressed_extensions

  def application_ebin_dir do
    case :code.lib_dir(@otp_app) do
      path when is_list(path) -> path |> List.to_string() |> Path.join("ebin")
      _ -> nil
    end
  end

  def assets_dir, do: Path.expand(@assets_dir)
  def build_path, do: Path.expand(mix_project(&Mix.Project.build_path/1) || Path.join("_build", to_string(mix_env())))

  def colocated_dir, do: Path.join([build_path(), "phoenix-colocated", to_string(@otp_app)])

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

  def generated, do: @generated
  def image_densities, do: @image_densities
  def image_max_pixels, do: @image_max_pixels

  def js_drop do
    :phoenix_asset_pipeline
    |> Application.get_env(:js_drop, [])
    |> Enum.map(fn value when is_atom(value) or is_binary(value) -> to_string(value) end)
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

  def manifest_cache_dir, do: Path.join(build_path(), "phoenix_asset_pipeline")

  # Applies `fun` to the current Mix project config; `nil` outside a Mix project.
  def mix_project(fun) when is_function(fun, 1) do
    if Code.ensure_loaded?(Mix.Project) do
      config = Mix.Project.config()
      if config[:app], do: fun.(config)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  def otp_app, do: @otp_app
  def precompiled_manifest?, do: @precompiled_manifest
  def project_dir(assets_dir \\ @assets_dir), do: assets_dir |> Path.expand() |> Path.dirname()
  def public_css_variables, do: @public_css_variables
  def static_dir, do: Path.expand(@static_dir)
  def svg_sprites, do: @svg_sprites

  def watcher? do
    endpoint = endpoint()

    is_atom(endpoint) and
      @otp_app
      |> Application.get_env(endpoint, [])
      |> Keyword.get(:code_reloader, false)
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
end
