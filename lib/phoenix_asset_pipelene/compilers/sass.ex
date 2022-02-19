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
    opts = ~w(--embed-source-map --color --indented --style=compressed)

    case Utils.cmd(bin, args ++ opts ++ [Path.join(Utils.assets_path(), "#{path}.sass")]) do
      {css, 0} ->
        css = minify(obfuscate_class_names?(), css)

        integrity =
          sri_hash_algoritm()
          |> String.to_atom()
          |> :crypto.hash(css)
          |> Base.encode64()

        {css, integrity}

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          {"", ""}
        else
          raise(SassCompilerError, msg)
        end
    end
  end

  defp minify(true, css) do
    # Matches a valid CSS class name. Read more https://rgxdb.com/r/3SSUL9QL
    Regex.replace(~r{\.(-?[_a-zA-Z]+[_a-zA-Z0-9-]*)}, css, fn _, class_name, _ ->
      "." <> Obfuscator.obfuscate(class_name)
    end)
  end

  defp minify(_, css), do: css
end
