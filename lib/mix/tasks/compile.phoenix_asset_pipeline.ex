defmodule Mix.Tasks.Compile.PhoenixAssetPipeline do
  @shortdoc "Builds the PhoenixAssetPipeline manifest"
  @moduledoc false
  use Mix.Task.Compiler

  alias PhoenixAssetPipeline.Config

  @compiler_disabled_key {__MODULE__, :compiler_disabled}

  @impl true
  def run(_) do
    if compiler_disabled?(),
      do: {:noop, []},
      else: :global.trans({{PhoenixAssetPipeline, :run}, self()}, &compile/0, [node()], :infinity)
  end

  @doc false
  def save_manifest(manifest) when is_map(manifest) do
    save_manifest_once(manifest)
    :ok
  end

  @doc false
  def with_compiler_disabled(fun) when is_function(fun, 0) do
    :ok = update_compiler_disabled_count(1)

    try do
      fun.()
    after
      :ok = update_compiler_disabled_count(-1)
    end
  end

  if Config.precompiled_manifest?() do
    defp compile do
      if PhoenixAssetPipeline.Manifest.precompiled_loaded?() do
        compile_if_stale()
      else
        save_manifest_once(PhoenixAssetPipeline.build())
        {:ok, []}
      end
    end
  else
    defp compile do
      if PhoenixAssetPipeline.Manifest.cached_loaded?() do
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

  defp compiler_disabled?, do: :persistent_term.get(@compiler_disabled_key, 0) > 0

  defp log_manifest(path) do
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  if Config.precompiled_manifest?() do
    defp save_manifest_once(manifest) do
      manifest
      |> PhoenixAssetPipeline.Manifest.save_precompiled!()
      |> log_manifest()
    end
  else
    defp save_manifest_once(manifest) do
      :ok = PhoenixAssetPipeline.Manifest.put_compile_manifest(manifest)
      :ok = PhoenixAssetPipeline.Manifest.save_cached(manifest)
      log_manifest(PhoenixAssetPipeline.Manifest.cache_path())
    end
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
