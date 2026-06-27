defmodule Mix.Tasks.Compile.PhoenixAssetPipeline do
  @shortdoc "Builds the PhoenixAssetPipeline manifest"
  @moduledoc false
  use Mix.Task.Compiler

  alias Mix.Task.Compiler
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest

  @recursive true
  @class_descriptors_compiled_key {__MODULE__, :class_descriptors_compiled}
  @compiler_configured_cache_key {__MODULE__, :compiler_configured_cache}
  @compiler_disabled_key {__MODULE__, :compiler_disabled}
  @missing :__phoenix_asset_pipeline_missing__
  @recompiling_key {__MODULE__, :recompiling}

  @impl true
  def run(args) do
    target = manifest_target()

    cond do
      compiler_disabled?() -> {:noop, []}
      recompiling?() -> {:noop, []}
      target == :noop -> {:noop, []}
      !class_descriptors_compiled?() and PhoenixAssetPipeline.current?() -> {:noop, []}
      true -> compile(args, target)
    end
  end

  @doc false
  def after_compile do
    cond do
      compiler_disabled?() -> :ok
      recompiling?() -> :ok
      compiler_configured?() -> mark_class_descriptors_compiled()
      Process.whereis(Manifest) -> PhoenixAssetPipeline.run()
      true -> :ok
    end
  end

  @doc false
  def save_manifest(manifest, compile_args \\ [], source_snapshot \\ nil)

  def save_manifest(manifest, compile_args, source_snapshot) do
    target = manifest_target()

    if target != :noop do
      save_manifest(manifest, target, compile_args, source_snapshot)
    end

    :ok
  end

  defp build_manifest(nil), do: PhoenixAssetPipeline.build()

  defp build_manifest(source_snapshot), do: PhoenixAssetPipeline.build_from_source_snapshot(source_snapshot)

  defp save_manifest_once(manifest, :cached, opts) do
    :ok = Manifest.put_compile_manifest(manifest)
    :ok = Manifest.save_cached(manifest)
    maybe_log_manifest(Manifest.cache_path(), opts)
  end

  defp save_manifest_once(manifest, :precompiled, opts) do
    manifest
    |> Manifest.save_precompiled!()
    |> maybe_log_manifest(opts)
  end

  defp maybe_log_manifest(path, opts) do
    if Keyword.get(opts, :log?, true), do: log_manifest(path)
  end

  @doc false
  def recompile_consumers(manifest_description, compile_args \\ []) do
    Mix.shell().info("Recompiling with #{manifest_description}")

    with_process_flag(@recompiling_key, true, fn ->
      reenable_compilers()
      Mix.Task.run("compile", force_args(compile_args))
    end)
  end

  @doc false
  def with_compiler_disabled(fun) when is_function(fun, 0) do
    with_process_flag(@compiler_disabled_key, true, fun)
  end

  @doc false
  def compiler_configured? do
    case Process.get(@compiler_configured_cache_key, @missing) do
      @missing ->
        configured? = compiler_configured_uncached?()
        Process.put(@compiler_configured_cache_key, configured?)
        configured?

      configured? ->
        configured?
    end
  end

  defp compiler_configured_uncached? do
    :phoenix_asset_pipeline in Compiler.compilers()
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  defp compile(args, target) do
    source_snapshot = PhoenixAssetPipeline.source_snapshot()

    source_snapshot
    |> PhoenixAssetPipeline.build_from_source_snapshot()
    |> save_manifest(target, args, source_snapshot)

    {:ok, []}
  end

  defp save_manifest(manifest, target, compile_args, source_snapshot) do
    save_manifest_once(manifest, target, log?: false)
    recompile_consumers(manifest_description(target), compile_args)

    save_manifest_once(build_manifest(source_snapshot), target, log?: true)
    recompile_consumers(manifest_description(target), compile_args)

    :ok
  end

  defp class_descriptors_compiled? do
    if :persistent_term.get(@class_descriptors_compiled_key, false) do
      :persistent_term.erase(@class_descriptors_compiled_key)
      true
    else
      false
    end
  end

  defp compiler_disabled?, do: process_or_persistent?(@compiler_disabled_key)

  defp mark_class_descriptors_compiled do
    if !:persistent_term.get(@class_descriptors_compiled_key, false) do
      :persistent_term.put(@class_descriptors_compiled_key, true)
    end

    :ok
  end

  defp process_or_persistent?(key) do
    Process.get(key, false) or :persistent_term.get(key, false)
  end

  defp recompiling?, do: process_or_persistent?(@recompiling_key)

  defp force_args(args) do
    args
    |> Enum.reject(&(&1 == "--force"))
    |> then(&["--force" | &1])
  end

  defp manifest_description(:cached), do: "cached PhoenixAssetPipeline manifest"
  defp manifest_description(:precompiled), do: "precompiled PhoenixAssetPipeline manifest"

  defp manifest_target do
    cond do
      Config.precompiled_manifest?() -> :precompiled
      Config.watcher?() -> :cached
      true -> :noop
    end
  end

  defp log_manifest(path) do
    Mix.shell().info("Wrote #{Path.relative_to_cwd(path)}")
  end

  defp reenable_compilers do
    if function_exported?(Compiler, :reenable, 0) do
      Compiler.reenable()
    else
      Mix.Task.reenable("compile")
      Mix.Task.reenable("compile.all")

      Enum.each(Compiler.compilers(), &Mix.Task.reenable("compile.#{&1}"))
    end
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
