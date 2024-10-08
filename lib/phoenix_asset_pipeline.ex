defmodule PhoenixAssetPipeline do
  @moduledoc false
  import Plug.Conn,
    only: [
      halt: 1,
      put_private: 3,
      put_resp_header: 3,
      register_before_send: 2,
      send_resp: 3
    ]

  alias PhoenixAssetPipeline.Storage

  defmacro __using__(opts) do
    quote do
      import PhoenixAssetPipeline.Plug, only: [assets: 2, static: 2]
      import unquote(__MODULE__)

      alias PhoenixAssetPipeline.Utils

      paths = Utils.static_paths()

      @env Mix.env()
      @on_load :on_load
      @paths_hash :erlang.md5(paths)
      @static_files Utils.static_files()

      for path <- paths, do: @external_resource(path)

      plug :heath_check
      plug :put_router_url
      plug :put_static_url
      plug :assets
      plug :static, unquote(opts)
      plug :content_security_policy, @env
      plug :minify_html_body, @env

      def __mix_recompile__? do
        Utils.static_paths() |> :erlang.md5() != @paths_hash
      end

      def static_files, do: @static_files

      def on_load, do: Storage.put(:endpoint, __MODULE__)
    end
  end

  def content_security_policy(conn, :prod) do
    register_before_send(conn, &put_content_security_policy/1)
  end

  def content_security_policy(conn, _), do: conn

  def heath_check(%{path_info: ["health"]} = conn, _) do
    conn
    |> send_resp(200, "ok")
    |> halt()
  end

  def heath_check(conn, _), do: conn

  def minify_html_body(conn, :prod), do: register_before_send(conn, &minify/1)
  def minify_html_body(conn, _), do: conn

  def put_router_url(%{host: host, private: %{phoenix_endpoint: phoenix_endpoint}} = conn, _) do
    router_url = phoenix_endpoint.url()
    router_url = phoenix_endpoint.struct_url() |> base_url(host, router_url)

    put_private(conn, :phoenix_router_url, router_url)
  end

  def put_static_url(%{host: host, private: %{phoenix_endpoint: phoenix_endpoint}} = conn, _) do
    static_url = phoenix_endpoint.static_url()
    static_url = static_url |> URI.parse() |> base_url(host, static_url)

    put_private(conn, :phoenix_static_url, static_url)
  end

  defp base_url(uri, host), do: URI.to_string(%{uri | host: host})
  defp base_url(%{host: "localhost"} = uri, host, _), do: base_url(uri, host)
  defp base_url(_, _, url), do: url

  defp minify(%{resp_body: body, resp_headers: [{"content-type", "text/html" <> _} | _]} = conn) do
    body =
      body
      |> Floki.parse_document!()
      |> Floki.raw_html()

    %{conn | resp_body: "<!DOCTYPE html>" <> body}
  end

  defp minify(conn), do: conn

  defp put_content_security_policy(conn) do
    integrities = Storage.get(:modules) |> Enum.flat_map(& &1.integrities())
    fun = &"'sha512-#{&1}'"

    script_src = for {".js", integrity} <- integrities, do: fun.(integrity)
    style_src = for {".css", integrity} <- integrities, do: fun.(integrity)

    directives =
      [
        "base-uri 'self'",
        "default-src 'self'",
        "script-src 'unsafe-inline' #{conn.private.phoenix_static_url} #{Enum.join(script_src, " ")} 'strict-dynamic'",
        "style-src 'self' #{Enum.join(style_src, " ")}"
      ]
      |> Enum.join("; ")

    put_resp_header(conn, "content-security-policy", directives)
  end
end
