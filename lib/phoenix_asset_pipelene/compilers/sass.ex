defmodule PhoenixAssetPipeline.Compilers.Sass do
  @moduledoc false

  import PhoenixAssetPipeline.Config

  require Logger

  alias PhoenixAssetPipeline.{Compiler, Exceptions.SassCompilerError, Obfuscator, Utils}

  @behaviour Compiler

  @impl true
  def new(path) do
    compile!(path)
  end

  @impl true
  def compile!(path) do
    Utils.install_sass()

    args = []
    bin = DartSass.bin_path()
    opts = ~w(--embed-source-map --color --indented --stop-on-error --style=compressed)

    case Utils.cmd(bin, args ++ opts ++ [Path.join(Utils.assets_path(), "#{path}.sass")]) do
      {css, 0} ->
        {
          content(css, obfuscate_class_names?()),
          integrity(css)
        }

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          {"", ""}
        else
          raise(SassCompilerError, msg)
        end
    end
  end

  defp content(css, true), do: Obfuscator.obfuscate_css(css)
  defp content(css, _), do: css

  defp integrity(css) do
    sri_hash_algoritm()
    |> String.to_atom()
    |> :crypto.hash(css)
    |> Base.encode64()
  end
end
