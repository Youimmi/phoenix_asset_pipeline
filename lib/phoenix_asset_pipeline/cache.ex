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
    write_atomic!(path, :erlang.term_to_iovec(term))
  end

  @doc false
  def write_atomic!(path, content) when is_binary(content) or is_list(content) do
    File.mkdir_p!(Path.dirname(path))
    publish_atomic!(path, content)
  end

  defp publish_atomic!(path, content) do
    tmp_path = temporary_path(path)

    case File.open(tmp_path, [:write, :binary, :raw, :exclusive]) do
      {:ok, file} ->
        try do
          try do
            :ok = :file.write(file, content)
            :ok = :file.sync(file)
          after
            :file.close(file)
          end

          File.rename!(tmp_path, path)
        after
          _ = File.rm(tmp_path)
        end

      {:error, :eexist} ->
        publish_atomic!(path, content)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "open temporary cache file", path: tmp_path
    end
  end

  defp temporary_path(path) do
    unique = System.unique_integer([:monotonic, :positive])
    "#{path}.#{System.pid()}.#{unique}.tmp"
  end
end
