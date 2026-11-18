defmodule Mix.Tasks.Compile.PhoenixAssetPipeline do
  @shortdoc "Builds the PhoenixAssetPipeline manifest"
  @moduledoc false
  use Mix.Task.Compiler

  alias PhoenixAssetPipeline.Manifest

  @compiler_disabled_key {__MODULE__, :compiler_disabled}

  @impl true
  def run(_) do
    if :persistent_term.get(@compiler_disabled_key, 0) > 0,
      do: {:noop, []},
      else: PhoenixAssetPipeline.with_run_lock(&compile/0)
  end

  if PhoenixAssetPipeline.Config.precompiled_manifest?() do
    def save_manifest(manifest) when is_map(manifest) do
      manifest
      |> Manifest.save_precompiled!()
      |> log_manifest()
    end
  else
    def save_manifest(manifest) when is_map(manifest) do
      :ok = Manifest.put_compile_manifest(manifest)
      :ok = Manifest.save_cached(manifest)
      log_manifest(Manifest.cache_path())
    end
  end

  def with_compiler_disabled(fun) when is_function(fun, 0) do
    :ok = update_compiler_disabled_count(1)

    try do
      fun.()
    after
      :ok = update_compiler_disabled_count(-1)
    end
  end

  defp compile do
    result = if Manifest.loaded?(), do: PhoenixAssetPipeline.build_if_stale(), else: {:ok, PhoenixAssetPipeline.build()}

    case result do
      :current ->
        {:noop, []}

      {:ok, manifest} ->
        save_manifest(manifest)
        {:ok, []}
    end
  end

  defp log_manifest(path) do
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp update_compiler_disabled_count(amount) do
    :global.trans(
      {@compiler_disabled_key, self()},
      fn ->
        case :persistent_term.get(@compiler_disabled_key, 0) + amount do
          0 -> :persistent_term.erase(@compiler_disabled_key)
          count -> :persistent_term.put(@compiler_disabled_key, count)
        end

        :ok
      end,
      [node()],
      :infinity
    )
  end
end
