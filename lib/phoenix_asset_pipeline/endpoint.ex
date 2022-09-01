defmodule PhoenixAssetPipeline.Endpoint do
  @moduledoc false

  use Plug.Builder

  alias PhoenixAssetPipeline.Plugs.Assets
  alias Plug.SSL

  plug :ssl
  plug :assets
  plug :not_found

  def __handler__(conn, opts) do
    {:plug, conn, __MODULE__, opts}
  end

  defp assets(conn, _opts) do
    Assets.call(conn, [])
  end

  defp not_found(conn, _opts) do
    send_resp(conn, 404, "not found")
  end

  defp ssl(conn, opts) do
    force_ssl = Keyword.get(opts, :force_ssl, false)

    case force_ssl do
      false -> conn
      _ -> SSL.call(conn, SSL.init(force_ssl))
    end
  end
end
