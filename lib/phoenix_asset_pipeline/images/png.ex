defmodule PhoenixAssetPipeline.Images.PNG do
  @moduledoc false

  # libvips writes pHYs even with keep: none. Stop before the compressed image data.
  def strip_resolution(content), do: strip_resolution(content, 8)

  defp strip_resolution(content, offset) do
    case binary_part(content, offset, 8) do
      <<9::32, "pHYs">> ->
        binary_part(content, 0, offset) <>
          binary_part(content, offset + 21, byte_size(content) - offset - 21)

      <<_::32, "IDAT">> ->
        content

      <<size::32, _::32>> ->
        strip_resolution(content, offset + size + 12)
    end
  end
end
