defmodule PhoenixAssetPipeline.Plug.StaticTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Plug.Static

  setup do
    previous_snapshot =
      Manifest.put_snapshot(%{
        scripts: %{
          "asset.js" => %{
            content_type: "application/javascript",
            data: %{"br" => {"br", 2}, "raw" => {"raw", 3}, "zstd" => {"zstd", 4}},
            digest: "asset"
          },
          "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.js" => %{
            content_type: "application/javascript",
            data: %{"br" => {"br", 2}, "raw" => {"raw", 3}, "zstd" => {"zstd", 4}},
            digest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
          }
        },
        static_files: %{
          "apple-app-site-association" => %{
            content_type: "application/octet-stream",
            data: %{
              "br" => {"br", 2, ~s("br-digest")},
              "raw" => {"{}", 2, ~s("raw-digest")}
            },
            digest: "digest"
          }
        }
      })

    on_exit(fn -> Manifest.restore_snapshot(previous_snapshot) end)
  end

  test "uses custom content type by filename" do
    conn =
      [only: ["apple-app-site-association"], content_types: %{"apple-app-site-association" => "application/json"}]
      |> Static.init()
      |> then(&(:get |> conn("/apple-app-site-association") |> put_asset_private() |> Static.call(&1)))

    assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    assert conn.resp_body == "{}"
  end

  test "serves digested asset from router host" do
    conn =
      []
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.js")
        |> put_same_host_private()
        |> put_req_header("accept-encoding", "zstd, br")
        |> Static.call(opts)
      end)

    assert conn.status == 200
    assert get_resp_header(conn, "content-encoding") == ["br"]
    assert conn.resp_body == "br"
  end

  test "serves asset from static host" do
    conn =
      []
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("http://static.example.com/asset.js")
        |> put_split_host_private()
        |> put_req_header("accept-encoding", "zstd")
        |> Static.call(opts)
      end)

    assert conn.status == 200
    assert get_resp_header(conn, "content-encoding") == ["zstd"]
    assert conn.resp_body == "zstd"
  end

  test "can skip content type header" do
    conn =
      [only: ["apple-app-site-association"], content_types: false]
      |> Static.init()
      |> then(&(:get |> conn("/apple-app-site-association") |> put_asset_private() |> Static.call(&1)))

    assert get_resp_header(conn, "content-type") == []
    assert conn.resp_body == "{}"
  end

  test "adds vary without replacing existing vary headers" do
    conn =
      [only: ["apple-app-site-association"]]
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/apple-app-site-association")
        |> put_asset_private()
        |> put_resp_header("vary", "Origin")
        |> Static.call(opts)
      end)

    assert "Accept-Encoding" in get_resp_header(conn, "vary")
    assert "Origin" in get_resp_header(conn, "vary")
  end

  test "serves byte range" do
    conn =
      [only: ["apple-app-site-association"]]
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/apple-app-site-association")
        |> put_asset_private()
        |> put_req_header("range", "bytes=0-0")
        |> Static.call(opts)
      end)

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 0-0/2"]
    assert conn.resp_body == "{"
  end

  test "falls back to full response for out of bounds byte range" do
    conn =
      [only: ["apple-app-site-association"]]
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/apple-app-site-association")
        |> put_asset_private()
        |> put_req_header("range", "bytes=100-")
        |> Static.call(opts)
      end)

    assert conn.status == 200
    assert get_resp_header(conn, "content-range") == []
    assert conn.resp_body == "{}"
  end

  test "returns not modified for matching encoded static file etag" do
    conn =
      [only: ["apple-app-site-association"]]
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/apple-app-site-association")
        |> put_asset_private()
        |> put_req_header("accept-encoding", "br")
        |> put_req_header("if-none-match", ~s("br-digest"))
        |> Static.call(opts)
      end)

    assert conn.status == 304
    assert get_resp_header(conn, "etag") == [~s("br-digest")]
    assert conn.resp_body == ""
  end

  test "does not match weak static file etag" do
    conn =
      [only: ["apple-app-site-association"]]
      |> Static.init()
      |> then(fn opts ->
        :get
        |> conn("/apple-app-site-association")
        |> put_asset_private()
        |> put_req_header("if-none-match", ~s(W/"raw-digest"))
        |> Static.call(opts)
      end)

    assert conn.status == 200
    assert get_resp_header(conn, "etag") == [~s("raw-digest")]
    assert conn.resp_body == "{}"
  end

  defp put_asset_private(conn) do
    conn
    |> put_private(:phoenix_router_url, "http://www.example.com")
    |> put_private(:phoenix_router_host, "www.example.com")
    |> put_private(:phoenix_static_url, "http://static.example.com")
    |> put_private(:phoenix_static_host, "static.example.com")
  end

  defp put_same_host_private(conn) do
    conn
    |> put_private(:phoenix_router_url, "http://www.example.com")
    |> put_private(:phoenix_router_host, "www.example.com")
    |> put_private(:phoenix_static_url, "http://www.example.com")
    |> put_private(:phoenix_static_host, "www.example.com")
  end

  defp put_split_host_private(conn) do
    conn
    |> put_private(:phoenix_router_url, "http://www.example.com")
    |> put_private(:phoenix_router_host, "www.example.com")
    |> put_private(:phoenix_static_url, "http://static.example.com")
    |> put_private(:phoenix_static_host, "static.example.com")
  end
end
