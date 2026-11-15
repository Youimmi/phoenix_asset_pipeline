defmodule PhoenixAssetPipeline.HTML.RawText do
  @moduledoc false

  # Elements whose content is kept as written: raw text, escapable raw text and <pre>, where
  # whitespace is significant.
  @tags MapSet.new(~w(pre script style textarea title))

  # A tag name ends at whitespace, `>`, `/` or the end of the input.
  def boundary?(source, index) when index == byte_size(source), do: true
  def boundary?(source, index), do: :binary.at(source, index) in [?>, ?/, ?\s, ?\t, ?\n, ?\r, ?\f]

  # Returns the index of the first `</tag` closing tag, matched case-insensitively, or nil.
  def close_index(source, tag), do: close_index(source, tag, 0)

  def closing_tag?(source, tag) do
    size = byte_size(tag) + 2

    byte_size(source) >= size and String.downcase(binary_part(source, 0, size), :ascii) == "</" <> tag and
      boundary?(source, size)
  end

  def tag?(name), do: MapSet.member?(@tags, name)

  defp close_index(source, tag, offset) do
    case :binary.match(source, "</", scope: {offset, byte_size(source) - offset}) do
      {index, 2} ->
        if closing_tag?(binary_part(source, index, byte_size(source) - index), tag),
          do: index,
          else: close_index(source, tag, index + 2)

      :nomatch ->
        nil
    end
  end
end
