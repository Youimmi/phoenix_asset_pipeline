defmodule PhoenixAssetPipeline.Compilers.Esbuild do
  @moduledoc false

  require Logger

  alias PhoenixAssetPipeline.{
    Compiler,
    Config,
    Exceptions.EsbuildCompilerError,
    Obfuscator,
    Utils
  }

  @behaviour Compiler

  @impl true
  def new(path), do: compile!(path)

  @impl true
  def compile!(path) do
    path = path(path, Path.extname(path))
    args = ~w(--bundle --tree-shaking=true --minify --target=es2020)

    args =
      if Code.ensure_loaded?(IEx),
        do: ["--sourcemap=inline" | args],
        else: args

    opts = [
      cd: Path.join(File.cwd!(), Config.js_path()),
      env: %{"NODE_PATH" => Path.expand(Path.join(File.cwd!(), "deps"), __DIR__)},
      stderr_to_stdout: true
    ]

    case Utils.cmd([Esbuild.bin_path(), path], args, opts) do
      {js, 0} ->
        js = Obfuscator.obfuscate_js(js)
        {js, Utils.integrity(js)}

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          {"", nil}
        else
          raise(EsbuildCompilerError, msg)
        end
    end
  end

  defp path(path, ""), do: path <> ".ts"
  defp path(path, _), do: path
end
