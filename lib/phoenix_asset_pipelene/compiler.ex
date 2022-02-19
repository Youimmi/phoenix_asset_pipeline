defmodule PhoenixAssetPipeline.Compiler do
  @moduledoc false

  # @doc false
  @callback new(String.t()) :: {String.t(), String.t()}

  # @doc false
  @callback compile!(String.t()) :: {String.t(), String.t()}
end
