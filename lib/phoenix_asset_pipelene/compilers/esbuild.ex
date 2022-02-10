defmodule PhoenixAssetPipeline.Compilers.Esbuild do
  @moduledoc false

  import PhoenixAssetPipeline.Utils
  alias PhoenixAssetPipeline.Compiler

  @behaviour Compiler

  @impl true
  def new(_), do: ""

  @impl true
  def compile!(_) do
    install_esbuild()
    ""
  end
end
