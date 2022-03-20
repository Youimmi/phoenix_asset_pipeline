defmodule PhoenixAssetPipeline.Plugs.MinifyHTML do
  @moduledoc false
  @behaviour Plug

  alias Plug.Conn

  @impl true
  def init(opts \\ []), do: opts

  @impl true
  def call(%Conn{} = conn, _ \\ []) do
    Conn.register_before_send(conn, &minify_html/1)
  end

  defp minify_html(%Conn{resp_headers: [{"content-type", "text/html" <> _} | _]} = conn) do
    body = Floki.parse_document!(conn.resp_body)
    %Conn{conn | resp_body: Floki.raw_html(body)}
  end

  defp minify_html(conn), do: conn
end
