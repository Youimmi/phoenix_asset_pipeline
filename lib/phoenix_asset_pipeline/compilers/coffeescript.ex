defmodule PhoenixAssetPipeline.Compilers.CoffeeScript do
  @moduledoc false

  @behaviour PhoenixAssetPipeline.Compiler

  @impl true
  def new(path) do
    compile!(path)
  end

  @impl true
  def compile!(_) do
    {"", ""}
  end
end
