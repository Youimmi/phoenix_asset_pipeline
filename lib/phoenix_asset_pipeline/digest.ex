defmodule PhoenixAssetPipeline.Digest do
  @moduledoc false

  def binary(data), do: :crypto.hash(:sha256, data)

  def file(path) do
    case File.read(path) do
      {:ok, content} -> binary(content)
      {:error, :enoent} -> :missing
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

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
