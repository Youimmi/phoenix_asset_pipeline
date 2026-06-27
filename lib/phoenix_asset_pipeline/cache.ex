defmodule PhoenixAssetPipeline.Cache do
  @moduledoc false

  def read_term(path, default, decode) when is_function(decode, 1) do
    with {:ok, binary} <- File.read(path),
         term = :erlang.binary_to_term(binary, [:safe]),
         {:ok, value} <- decode.(term) do
      value
    else
      _ -> default
    end
  rescue
    _ -> default
  end

  def write_term!(path, term) do
    write_atomic!(path, :erlang.term_to_binary(term))
  end

  defp write_atomic!(path, content) do
    tmp_path = "#{path}.#{System.unique_integer([:positive])}.tmp"

    File.mkdir_p!(Path.dirname(path))

    try do
      File.write!(tmp_path, content)
      File.rename!(tmp_path, path)
    after
      _ = File.rm(tmp_path)
    end
  end
end
