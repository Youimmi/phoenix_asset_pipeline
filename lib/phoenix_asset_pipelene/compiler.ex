defmodule PhoenixAssetPipeline.Compiler do
  @moduledoc false

  @doc false
  @callback new(binary) :: binary

  @doc false
  @callback compile(binary) :: {:ok, binary} | {:error, binary}
end
