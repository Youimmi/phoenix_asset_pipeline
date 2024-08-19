defmodule PhoenixAssetPipeline.Parser.JSON do
  @moduledoc """
    JSON parser, based on Erlang/OTP 27.0
  """

  def encode_to_iodata!(data) do
    data
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  defdelegate decode!(data), to: :json, as: :decode
end
