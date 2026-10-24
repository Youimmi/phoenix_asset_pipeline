defmodule PhoenixAssetPipeline.HTML.Entities do
  @moduledoc false

  alias Floki.HTML.Tokenizer

  def decode_attribute(value) when is_binary(value) do
    if :binary.match(value, "&") == :nomatch do
      value
    else
      value = :binary.replace(value, "\"", "&quot;", [:global])
      %{tokens: [%{attributes: [%{value: decoded}]}, :eof]} = Tokenizer.tokenize("<x a=\"" <> value <> "\">")
      IO.chardata_to_string(decoded)
    end
  end
end
