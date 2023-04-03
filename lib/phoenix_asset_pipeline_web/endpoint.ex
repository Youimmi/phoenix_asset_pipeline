defmodule PhoenixAssetPipelineWeb.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :phoenix_asset_pipeline

  plug PhoenixAssetPipelineWeb.Plugs.Assets
  plug :not_found

  defp not_found(conn, _) do
    send_resp(conn, 404, "not found")
  end
end
