defmodule PhoenixAssetPipeline.Plug do
  @moduledoc false

  import Plug.Conn

  alias PhoenixAssetPipeline.Endpoint
  alias PhoenixAssetPipeline.Plug.Assets
  alias PhoenixAssetPipeline.Plug.Static

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, opts) do
    server = Phoenix.Endpoint.server?(:phoenix_asset_pipeline, Endpoint)

    conn
    |> minify_html()
    |> assets(server)
    |> Static.call(Static.init(opts))
  end

  defp assets(conn, true), do: conn

  defp assets(conn, _) do
    if String.starts_with?(request_url(conn), Endpoint.url()),
      do: Assets.call(conn, []),
      else: conn
  end

  defp minify_html(conn) do
    if PhoenixAssetPipeline.env() == :prod,
      do: register_before_send(conn, &minify/1),
      else: conn
  end

  defp minify(%{resp_headers: [{"content-type", "text/html" <> _} | _]} = conn) do
    body = Floki.parse_document!(conn.resp_body)
    %{conn | resp_body: "<!DOCTYPE html>" <> Floki.raw_html(body)}
  end

  defp minify(conn), do: conn
end
