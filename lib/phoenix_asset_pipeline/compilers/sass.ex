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

    opts =
      opts(
        ~w(--embed-source-map --color --stop-on-error --style=compressed --quiet-deps),
        Path.extname(path)
      ) ++ [Path.join(Config.css_path(), path)]

    case Utils.cmd(DartSass.bin_path(), opts) do
      {css, 0} ->
        {
          obfuscate(css, Config.obfuscate_class_names?()),
          Utils.integrity(css)
        }

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          {"", nil}
        else
          raise(SassCompilerError, msg)
        end
    end
  end

  defp opts(opts, ".sass"), do: ["--indented" | opts]
  defp opts(opts, _), do: opts

  defp path(path, ""), do: path <> Config.sass_extension()
  defp path(path, _), do: path

  defp obfuscate(css, true), do: Obfuscator.obfuscate_css(css)
  defp obfuscate(css, _), do: css
end
