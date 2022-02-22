defmodule PhoenixAssetPipeline.Compilers.Esbuild do
  @moduledoc false

  alias PhoenixAssetPipeline.{Compiler, Utils}

  @behaviour Compiler

  @impl true
  def new(path) do
    compile!(path)
  end

  @impl true
  def compile!(path) do
    Utils.install_esbuild()

    js =
      case path do
        "app" -> "console.log('index')"
        "index" -> "console.log('index')"
        _ -> ""
      end

    integrity = Utils.integrity(js)

    {js, integrity}
  end
end
