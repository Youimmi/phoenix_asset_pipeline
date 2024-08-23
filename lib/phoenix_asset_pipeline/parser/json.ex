defmodule PhoenixAssetPipeline.Parser.JSON do
  @moduledoc """
    JSON parser, based on Erlang/OTP 27.0
  """

  def encode_to_iodata!(data) do
    data
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  def decode!(data) do
    data
    |> :json.decode(:ok, %{null: nil})
    |> elem(0)
  end
end
