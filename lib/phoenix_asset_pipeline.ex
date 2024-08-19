defmodule PhoenixAssetPipeline do
  @moduledoc """
  Provides assets and static files pipeline.
  """

  import Plug.Conn, only: [put_private: 3, put_resp_header: 3, register_before_send: 2]

  alias PhoenixAssetPipeline.Storage

  defmacro __using__(opts) do
    quote do
      import PhoenixAssetPipeline.Plug, only: [assets: 2, static: 2]
      import unquote(__MODULE__)

      alias PhoenixAssetPipeline.Utils

      @env Mix.env()
      @on_load :on_load
      @static_files Utils.static_files()

      for path <- Utils.static_paths(), do: @external_resource(path)

      plug :put_static_url
      plug :assets
      plug :static, unquote(opts)
      plug :content_security_policy, @env
      plug :minify_html_body, @env

      def assets, do: @static_files

      def on_load, do: Storage.put(:endpoint, __MODULE__)
    end
  end

  def minify_html_body(conn, :prod), do: register_before_send(conn, &minify/1)
  def minify_html_body(conn, _), do: conn

  def content_security_policy(conn, :prod) do
    register_before_send(conn, &put_content_security_policy/1)
  end

  def content_security_policy(conn, _), do: conn

  def put_static_url(%{host: host, private: %{phoenix_endpoint: phoenix_endpoint}} = conn, _) do
    url = phoenix_endpoint.url()
    static_url = phoenix_endpoint.static_url()

    router_url = base_url(URI.parse(url), url, host)
    static_url = base_url(URI.parse(static_url), static_url, host)

    conn
    |> put_private(:phoenix_router_url, router_url)
    |> put_private(:phoenix_static_url, static_url)
  end

  defp base_url(%{host: "localhost"} = uri, _, host), do: URI.to_string(%{uri | host: host})
  defp base_url(_, url, _), do: url

  defp put_content_security_policy(conn) do
    integrities = Storage.get(:integrities, [])
    fun = &"'sha512-#{&1}'"

    script_src = for {".js", integrity} <- integrities, do: fun.(integrity)
    style_src = for {".css", integrity} <- integrities, do: fun.(integrity)

    conn
    |> put_resp_header(
      "content-security-policy",
      "default-src 'self'; script-src #{conn.private.phoenix_static_url} #{Enum.join(script_src, " ")}; style-src 'self' #{Enum.join(style_src, " ")}"
    )
  end

  defp minify(%{resp_body: body, resp_headers: [{"content-type", "text/html" <> _} | _]} = conn) do
    body =
      body
      |> Floki.parse_document!()
      |> Floki.raw_html()

    %{conn | resp_body: "<!DOCTYPE html>" <> body}
  end

  defp minify(conn), do: conn
end
