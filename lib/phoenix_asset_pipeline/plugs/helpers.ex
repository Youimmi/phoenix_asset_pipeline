defmodule PhoenixAssetPipeline.Plugs.Helpers do
  @moduledoc false

  import PhoenixAssetPipeline.Helpers
  import Plug.Conn

  alias Plug.Conn

  def minify_html(%Conn{} = conn, _) do
    register_before_send(conn, &minify/1)
  end

  def put_assets_url(%Conn{} = conn, _) do
    put_session(conn, :assets_url, base_url(conn))
  end

  defp minify(%{resp_headers: [{"content-type", "text/html" <> _} | _]} = conn) do
    body = Floki.parse_document!(conn.resp_body)
    %Conn{conn | resp_body: Floki.raw_html(body)}
  end

  defp minify(conn), do: conn
end
