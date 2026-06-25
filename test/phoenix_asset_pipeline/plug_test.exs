defmodule PhoenixAssetPipeline.PlugTest do
  use ExUnit.Case, async: true

  import Plug.Conn,
    only: [get_resp_header: 2, put_private: 3, put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  import Plug.Test

  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Plug, as: AssetPlug

  defmodule JSON do
    @moduledoc false

    def try_decode("{}", [:use_nil]), do: {:ok, %{}}
    def try_decode(_, [:use_nil]), do: :error
  end

  test "sends early hints with binary link header" do
    previous_snapshot =
      Manifest.put_snapshot(%{
        early_hints_preloads: ["/app.js>; rel=preload; as=script; crossorigin"]
      })

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)

    conn = conn(:get, "/")
    {Plug.Adapters.Test.Conn, %{ref: ref}} = conn.adapter

    conn
    |> put_in([Access.key!(:private), :phoenix_static_url], "http://localhost:4000")
    |> AssetPlug.early_hints([])

    assert_receive {^ref, :inform, {103, [{"link", link}]}}

    assert link ==
             "<http://localhost:4000>; rel=preconnect; crossorigin, " <>
               "<http://localhost:4000/app.js>; rel=preload; as=script; crossorigin"
  end

  test "builds secure browser headers from base policies" do
    headers = AssetPlug.secure_browser_headers(cross_origin_opener_policy: true)

    assert headers["content-security-policy"] =~ "default-src 'self'"
    assert headers["content-security-policy"] =~ "script-src 'strict-dynamic'"
    assert headers["permissions-policy"] == "fullscreen=(self),geolocation=(self)"
    assert headers["cross-origin-opener-policy"] == "same-origin"
  end

  test "skips content security policy for configured response statuses" do
    conn =
      :get
      |> conn("/")
      |> put_in([Access.key!(:private), :phoenix_static_url], "http://localhost:4000")
      |> AssetPlug.put_content_security_policy([])
      |> put_resp_content_type("text/html")
      |> send_resp(:internal_server_error, "error")

    assert get_resp_header(conn, "content-security-policy") == []
  end

  test "merges precomputed asset CSP directives into HTML responses" do
    previous_snapshot =
      Manifest.put_snapshot(%{
        csp_directives: %{
          "script-src" => ["'sha512-script'"],
          "style-src" => ["'sha512-style'"]
        }
      })

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)

    conn =
      :get
      |> conn("/")
      |> put_private(:phoenix_static_url, "http://static.example.com")
      |> put_resp_header("content-security-policy", "default-src 'self'; script-src 'strict-dynamic'; style-src 'self'")
      |> AssetPlug.put_content_security_policy([])
      |> put_resp_content_type("text/html")
      |> send_resp(:ok, "ok")

    assert [csp] = get_resp_header(conn, "content-security-policy")
    assert csp =~ "img-src http://static.example.com"
    assert csp =~ "script-src 'strict-dynamic' 'sha512-script'"
    assert csp =~ "style-src 'self' 'sha512-style'"
  end

  test "merges precomputed asset CSP directives into standard CSP response" do
    previous_snapshot =
      Manifest.put_snapshot(%{
        csp_directives: %{
          "script-src" => ["'sha512-script'"],
          "style-src" => ["'sha512-style'"]
        }
      })

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)

    conn =
      :get
      |> conn("/")
      |> put_private(:phoenix_static_url, "http://static.example.com")
      |> put_resp_header("content-security-policy", AssetPlug.content_security_policy())
      |> AssetPlug.put_content_security_policy([])
      |> put_resp_content_type("text/html")
      |> send_resp(:ok, "ok")

    assert [csp] = get_resp_header(conn, "content-security-policy")

    assert csp ==
             "base-uri 'none'; default-src 'self'; form-action 'self'; frame-ancestors 'self'; " <>
               "img-src 'self' data: http://static.example.com; object-src 'none'; report-to default; " <>
               "require-trusted-types-for 'script'; script-src 'strict-dynamic' 'sha512-script'; " <>
               "style-src 'sha512-style'; trusted-types decodeHTMLEntitiesPolicy default"
  end

  test "accepts valid CSP reports" do
    conn =
      :post
      |> conn("/csp-report", "{}")
      |> AssetPlug.csp_report(json_library: JSON)

    assert conn.halted
    assert conn.status == 204
    assert conn.resp_body == ""
  end

  test "rejects invalid CSP reports" do
    conn =
      :post
      |> conn("/csp-report", "invalid")
      |> AssetPlug.csp_report(json_library: JSON)

    assert conn.halted
    assert conn.status == 400
    assert conn.resp_body == "Invalid CSP report"
  end
end
