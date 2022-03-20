defmodule PhoenixAssetPipeline.Storage do
  @moduledoc """
  This module implements the `AssetPipeline.Storage` and stores the data with [:persistent_term](https://erlang.org/doc/man/persistent_term.html).
  """

  defdelegate get(key, default \\ nil), to: :persistent_term
  defdelegate put(key, value), to: :persistent_term
end
