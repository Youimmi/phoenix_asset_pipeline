defmodule PhoenixAssetPipeline.Digest do
  @moduledoc false

  def binary(data), do: :crypto.hash(:sha256, data)

  def hex(data) do
    data
    |> binary()
    |> Base.encode16(case: :lower)
  end

  def term(term) do
    term
    |> :erlang.term_to_iovec([:deterministic])
    |> binary()
  end
end
