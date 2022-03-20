defmodule PhoenixAssetPipeline.Compilers.Sass do
  @moduledoc false

  require Logger

  alias PhoenixAssetPipeline.{
    Compiler,
    Config,
    Exceptions.SassCompilerError,
    Obfuscator,
    Utils
  }

  @behaviour Compiler

  @impl true
  def new(path) do
    compile!(path)
  end

  @impl true
  def compile!(path) do
    Utils.install_sass()

    path = path(path, Path.extname(path))
    args = ~w(--embed-source-map --color --stop-on-error --style=compressed --quiet-deps)
    args = args(args, Path.extname(path)) ++ [Path.join(Config.css_path(), path)]

    opts = [
      cd: File.cwd!(),
      stderr_to_stdout: true
    ]

    case Utils.cmd(DartSass.bin_path(), args, opts) do
      {css, 0} ->
        css = Obfuscator.obfuscate_css(css)
        {css, Utils.integrity(css)}

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          {"", nil}
        else
          raise(SassCompilerError, msg)
        end
    end
  end

  defp args(args, ".sass"), do: ["--indented" | args]
  defp args(args, _), do: args

  defp path(path, ""), do: path <> ".sass"
  defp path(path, _), do: path
end
