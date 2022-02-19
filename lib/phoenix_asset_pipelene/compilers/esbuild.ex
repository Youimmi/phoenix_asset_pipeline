defmodule PhoenixAssetPipeline.Compilers.Esbuild do
  @moduledoc false

  import PhoenixAssetPipeline.Config

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

    integrity =
      sri_hash_algoritm()
      |> String.to_atom()
      |> :crypto.hash(js)
      |> Base.encode64()

    {js, integrity}
  end
end
