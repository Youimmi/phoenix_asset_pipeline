defmodule PhoenixAssetPipeline.StaticAsset do
  @moduledoc false

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Native

  @minimum_compression_size 1_024
  @encodings if Config.precompiled_manifest?(),
               do: [
                 {"br", {:brotli, 11}},
                 {"deflate", {:zlib, 15, 9}},
                 {"gzip", {:zlib, 31, 9}},
                 {"zstd", {:zstd, 22}}
               ],
               else: []
  @profile {
    if(Config.precompiled_manifest?(), do: :production, else: :development),
    @encodings,
    @minimum_compression_size,
    Config.already_compressed_extensions()
  }

  def build(path, content) do
    content = IO.iodata_to_binary(content)
    digest = Digest.hex(content)
    data = %{"raw" => {content, byte_size(content)}}
    data = if compressible?(path, content), do: Map.merge(data, compress(content, @encodings)), else: data

    %{
      content_type: MIME.from_path(path),
      data: data(data, etags(data, digest)),
      digest: digest
    }
  end

  def compress(content, encodings) do
    Enum.reduce(encodings, %{}, fn {encoding, opts}, encoded_assets ->
      encoded = encode(content, opts)

      if byte_size(encoded) < byte_size(content),
        do: Map.put(encoded_assets, encoding, {encoded, byte_size(encoded)}),
        else: encoded_assets
    end)
  end

  def compressible?(path, content) when byte_size(content) >= @minimum_compression_size do
    extension = path |> Path.extname() |> String.downcase()
    not is_map_key(Config.already_compressed_extensions(), extension)
  end

  def compressible?(_, _), do: false

  def data(data, etags) do
    Map.new(data, fn {encoding, {content, size}} ->
      {encoding, {content, size, Map.fetch!(etags, encoding)}}
    end)
  end

  def etags(data, digest) do
    Map.new(data, fn
      {"raw", _} -> {"raw", <<?\", digest::binary, ?\">>}
      {encoding, {content, _}} -> {encoding, ~s("#{Digest.hex(content)}")}
    end)
  end

  def profile, do: @profile

  defp encode(content, {:brotli, quality}), do: Native.compress(content, quality)

  defp encode(content, {:zstd, level}) do
    content
    |> :zstd.compress(%{compressionLevel: level})
    |> IO.iodata_to_binary()
  end

  defp encode(content, {:zlib, window_bits, level}) do
    zstream = :zlib.open()

    try do
      :zlib.deflateInit(zstream, level, :deflated, window_bits, 9, :default)
      data = :zlib.deflate(zstream, content, :finish)
      IO.iodata_to_binary(data)
    after
      try do
        :zlib.deflateEnd(zstream)
      catch
        _, _ -> :ok
      end

      :zlib.close(zstream)
    end
  end
end
