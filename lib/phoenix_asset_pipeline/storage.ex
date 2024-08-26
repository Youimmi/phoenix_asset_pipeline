defmodule PhoenixAssetPipeline.Storage do
  @moduledoc false

  @atom :phoenix_asset_pipeline

  def erase(key), do: :persistent_term.erase({@atom, key})

  def get(key, default \\ []), do: :persistent_term.get({@atom, key}, default)

  def put(key, value) when is_list(value) do
    list = value ++ get(key)
    :persistent_term.put({@atom, key}, Enum.uniq(list))
  end

  def put(key, value), do: :persistent_term.put({@atom, key}, value)
end
