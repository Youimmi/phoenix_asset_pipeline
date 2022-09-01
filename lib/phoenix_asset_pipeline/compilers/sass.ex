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

  # @sourse_map Application.compile_env(:phoenix_asset_pipeline, :sourse_map, true)

  @impl true
  def new(path), do: compile!(path)

  @impl true
  def compile!(path) do
    path = path(path, Path.extname(path))
    args = ~w(--color --load-path=assets/css --stop-on-error --style=compressed --quiet-deps)

    args =
      if Code.ensure_loaded?(IEx),
        do: args ++ ["--embed-source-map", "--embed-sources"],
        else: args

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
