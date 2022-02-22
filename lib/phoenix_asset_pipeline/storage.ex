defmodule PhoenixAssetPipeline.Storage do
  @moduledoc """
  This module implements the `AssetPipeline.Storage` and stores the data with
  [:dets](https://erlang.org/doc/man/dets.html) and [:persistent_term](https://erlang.org/doc/man/persistent_term.html).
  """

  #   def key(path, prefix), do: String.to_atom(prefix <> path)

  #   def drop(path, prefix) do
  #     path
  #     |> key(prefix)
  #     |> :persistent_term.erase() ||
  #       for(key <- key_list(prefix), do: :persistent_term.erase(key))
  #   end

  #   def key_list(prefix) do
  #     :lists.filter(
  #       fn {key, _value} -> is_atom(key) and String.starts_with?(Atom.to_string(key), prefix) end,
  #       :persistent_term.get()
  #     )
  #     |> Keyword.keys()
  #   end

  #   defdelegate get(key, default \\ nil), to: :persistent_term
  #   defdelegate put(key, value), to: :persistent_term
end
