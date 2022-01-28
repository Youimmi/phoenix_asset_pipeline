defmodule PhoenixAssetPipeline.Compilers.Sass do
  @moduledoc false

  import PhoenixAssetPipeline.{Obfuscator, Utils}
  alias PhoenixAssetPipeline.Exceptions.SassCompilerError

  def new(path) do
    compile(path)
  end

  def compile(path) do
    install_sass()

    args = []
    opts = ~w(--embed-source-map --color --indented --style=compressed)
    bin = DartSass.bin_path()

    case cmd(bin, args ++ opts ++ [assets_path() <> "/#{path}.sass"]) do
      {css, 0} ->
        Regex.replace(~r{\.(-?[_a-zA-Z]+[_a-zA-Z0-9-]*)}, css, fn _, class_name, _ ->
          "." <> obfuscate(class_name)
        end)

      {error, _} ->
        raise SassCompilerError, error
    end
  end
end
