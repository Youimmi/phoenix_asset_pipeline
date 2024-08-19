defmodule PhoenixAssetPipeline.Storage do
  @moduledoc """
  This module stores the data with [:persistent_term](https://erlang.org/doc/man/persistent_term.html).
  """

  @atom :phoenix_asset_pipeline

  @doc false
  def erase(key), do: :persistent_term.erase({@atom, key})

  @doc false
  def get(key, default \\ nil), do: :persistent_term.get({@atom, key}, default)

  @doc false
  def put(key, value), do: :persistent_term.put({@atom, key}, value)
end
