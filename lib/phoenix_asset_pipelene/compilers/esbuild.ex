defmodule PhoenixAssetPipeline.Compilers.Esbuild do
  @moduledoc false

  alias PhoenixAssetPipeline.{Compiler, Utils}

  @behaviour Compiler

  @impl true
  def new(_), do: ""

  @impl true
  def compile!(_) do
    Utils.install_esbuild()
    ""
  end
end
