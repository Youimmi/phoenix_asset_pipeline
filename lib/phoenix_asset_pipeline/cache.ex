defmodule PhoenixAssetPipeline.Cache do
  @moduledoc false

  alias Mix.Sync.Lock
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files

  def prune_blobs!(referenced) do
    case File.ls(blob_dir()) do
      {:ok, files} -> for file <- files, not MapSet.member?(referenced, file), do: File.rm!(Path.join(blob_dir(), file))
      {:error, :enoent} -> []
    end

    :ok
  end

  def put_blob!(content, hex \\ nil) do
    hex = hex || Digest.hex(content)
    path = Path.join(blob_dir(), hex)
    if not File.regular?(path), do: write_atomic!(path, content)
    hex
  end

  def read_blob!(hex) do
    with true <- is_binary(hex) and byte_size(hex) == 64,
         {:ok, digest} <- Base.decode16(hex, case: :lower) do
      path = Path.join(blob_dir(), hex)
      content = Files.read_regular!(path)

      if Digest.binary(content) != digest do
        _ = File.rm(path)
        raise File.Error, reason: :einval, action: "read corrupt blob", path: path
      end

      content
    else
      _ -> raise File.Error, reason: :einval, action: "read blob", path: inspect(hex)
    end
  end

  def read_map(path, fingerprint) do
    read_term(path, %{}, fn
      {^fingerprint, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end)
  end

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

  def with_lock(key, fun) when is_function(fun, 0), do: Lock.with_lock("phoenix_asset_pipeline #{key}", fun)

  def write_atomic!(path, content) when is_binary(content) or is_list(content) do
    File.mkdir_p!(Path.dirname(path))
    publish_atomic!(path, content)
  end

  def write_term!(path, term) do
    write_atomic!(path, :erlang.term_to_iovec(term))
  end

  defp blob_dir, do: Path.join(Config.manifest_cache_dir(), "blobs")

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
