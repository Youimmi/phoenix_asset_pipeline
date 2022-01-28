defmodule PhoenixAssetPipeline.Compilers.Sass do
  @moduledoc false

  import PhoenixAssetPipeline.{Obfuscator, Utils}
  alias PhoenixAssetPipeline.{Compiler, Exceptions.SassCompilerError}

  @behaviour Compiler

  @impl true
  def new(path) do
    case compile(path) do
      {:ok, css} -> css
      {:error, msg} -> raise SassCompilerError, msg
    end
  end

  @impl true
  def compile(path) do
    install_sass()

    args = []
    opts = ~w(--embed-source-map --color --indented --style=compressed)
    bin = DartSass.bin_path()

    case cmd(bin, args ++ opts ++ [assets_path() <> "/#{path}.sass"]) do
      {css, 0} ->
        css =
          Regex.replace(~r{\.(-?[_a-zA-Z]+[_a-zA-Z0-9-]*)}, css, fn _, class_name, _ ->
            "." <> obfuscate(class_name)
          end)

        {:ok, css}

      {error, _} ->
        {:error, error}
    end
  end
end
