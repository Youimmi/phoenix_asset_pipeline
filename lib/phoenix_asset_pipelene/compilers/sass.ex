defmodule PhoenixAssetPipeline.Compilers.Sass do
  @moduledoc false

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
        # Matches a valid CSS class name. Read more https://rgxdb.com/r/3SSUL9QL
        regex = ~r{\.(-?[_a-zA-Z]+[_a-zA-Z0-9-]*)}

        Regex.replace(regex, css, fn _, class_name, _ ->
          "." <> Obfuscator.obfuscate(class_name)
        end)

      {msg, _} ->
        if Code.ensure_loaded?(Mix.Project) and Utils.application_started?() do
          Logger.error(msg)
          ""
        else
          raise SassCompilerError, msg
        end
    end
  end
end
