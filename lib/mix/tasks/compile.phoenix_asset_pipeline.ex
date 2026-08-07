defmodule Mix.Tasks.Compile.PhoenixAssetPipeline do
  @shortdoc "Builds the PhoenixAssetPipeline manifest"
  @moduledoc false
  use Mix.Task.Compiler

  alias PhoenixAssetPipeline.Config

  @manifest_target Config.manifest_mode()

  if @manifest_target not in [:cached, :precompiled] do
    raise ArgumentError,
          "invalid :manifest_mode for :phoenix_asset_pipeline; expected :cached or :precompiled"
  end

  @compiler_disabled_key {__MODULE__, :compiler_disabled}
  @missing :__phoenix_asset_pipeline_missing__

  @impl true
  def run(_) do
    if compiler_disabled?(), do: {:noop, []}, else: compile()
  end

  @doc false
  def save_manifest(manifest) when is_map(manifest) do
    save_manifest_once(manifest)
    :ok
  end

  if @manifest_target == :cached do
    defp save_manifest_once(manifest) do
      :ok = PhoenixAssetPipeline.Manifest.put_compile_manifest(manifest)
      :ok = PhoenixAssetPipeline.Manifest.save_cached(manifest)
      log_manifest(PhoenixAssetPipeline.Manifest.cache_path())
    end

    defp compile do
      if PhoenixAssetPipeline.Manifest.cached_loaded?() do
        compile_if_stale()
      else
        save_manifest_once(PhoenixAssetPipeline.build())
        {:ok, []}
      end
    end
  else
    defp save_manifest_once(manifest) do
      manifest
      |> PhoenixAssetPipeline.Manifest.save_precompiled!()
      |> log_manifest()
    end

    defp compile do
      if PhoenixAssetPipeline.Manifest.precompiled_loaded?() do
        compile_if_stale()
      else
        save_manifest_once(PhoenixAssetPipeline.build())
        {:ok, []}
      end
    end
  end

  defp compile_if_stale do
    case PhoenixAssetPipeline.build_if_stale() do
      :current ->
        {:noop, []}

      {:ok, manifest} ->
        save_manifest_once(manifest)
        {:ok, []}
    end
  end

  @doc false
  def with_compiler_disabled(fun) when is_function(fun, 0) do
    with_process_flag(@compiler_disabled_key, true, fun)
  end

  defp compiler_disabled?, do: process_or_persistent?(@compiler_disabled_key)

  defp process_or_persistent?(key) do
    Process.get(key, false) or :persistent_term.get(key, false)
  end

  defp log_manifest(path) do
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp with_process_flag(key, value, fun) do
    previous = Process.get(key, @missing)
    previous_persistent = :persistent_term.get(key, @missing)

    Process.put(key, value)
    :persistent_term.put(key, value)

    try do
      fun.()
    after
      restore_process_flag(key, previous)
      restore_persistent_flag(key, previous_persistent)
    end
  end

  defp restore_persistent_flag(key, @missing), do: :persistent_term.erase(key)
  defp restore_persistent_flag(key, previous), do: :persistent_term.put(key, previous)

  defp restore_process_flag(key, @missing), do: Process.delete(key)
  defp restore_process_flag(key, previous), do: Process.put(key, previous)
end
