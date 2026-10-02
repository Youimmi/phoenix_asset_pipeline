defmodule PhoenixAssetPipeline.GeneratedStaticTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.Plug.Static

  @body String.duplicate("<url><loc>https://example.com/i/about?l=en</loc></url>", 100)

  setup do
    counter = start_supervised!({Agent, fn -> 0 end})
    generator = {__MODULE__, :content, [counter]}
    opts = Static.init(only: ["generated.xml"], generated: %{"generated.xml" => generator})

    on_exit(fn ->
      for function <- [:content, :fails_once] do
        :persistent_term.erase({Manifest, :generated_file, "generated.xml", {__MODULE__, function, [counter]}})
      end
    end)

    %{counter: counter, opts: opts}
  end

  test "concurrent requests build a generated file only once", %{counter: counter, opts: opts} do
    assert Agent.get(counter, & &1) == 0

    1..24
    |> Task.async_stream(fn _ -> request(:get, opts) end, max_concurrency: 12, timeout: :infinity)
    |> Enum.each(fn {:ok, conn} ->
      assert conn.status == 200
      assert conn.resp_body == @body
    end)

    assert Agent.get(counter, & &1) == 1
  end

  test "conditional requests reuse the generated representation", %{counter: counter, opts: opts} do
    [etag] = :get |> request(opts) |> get_resp_header("etag")

    for value <- [etag, "W/" <> etag, ~s("old", W/) <> etag, "*"] do
      conn = request(:get, opts, [{"if-none-match", value}])
      assert conn.status == 304
      assert conn.resp_body == ""
      assert get_resp_header(conn, "etag") == [etag]
      assert Enum.map(get_resp_header(conn, "vary"), &String.downcase/1) == ["accept-encoding"]
    end

    assert request(:get, opts, [{"if-none-match", ~s("old")}]).resp_body == @body
    assert Agent.get(counter, & &1) == 1
  end

  test "ranges and If-Range use the selected representation", %{opts: opts} do
    [etag] = :get |> request(opts) |> get_resp_header("etag")
    conn = request(:get, opts, [{"range", "bytes=0-15"}, {"if-range", etag}])

    assert conn.status == 206
    assert conn.resp_body == binary_part(@body, 0, 16)
    assert get_resp_header(conn, "content-range") == ["bytes 0-15/#{byte_size(@body)}"]

    stale = request(:get, opts, [{"range", "bytes=0-15"}, {"if-range", ~s("old")}])
    assert stale.status == 200
    assert stale.resp_body == @body

    invalid = request(:get, opts, [{"range", "bytes=999999-"}])
    assert invalid.status == 416
    assert invalid.resp_body == ""
  end

  test "path filters and methods do not invoke generators", %{counter: counter, opts: opts} do
    assert request(:post, opts).status == nil
    assert request(:get, Static.init(only: ["other"], generated: opts.generated)).status == nil
    assert Agent.get(counter, & &1) == 0
  end

  test "a failed generator can be retried", %{counter: counter, opts: opts} do
    opts = %{opts | generated: %{"generated.xml" => {__MODULE__, :fails_once, [counter]}}}
    assert_raise RuntimeError, "not ready", fn -> request(:get, opts) end
    assert request(:get, opts).resp_body == @body
    assert request(:get, opts).resp_body == @body
    assert Agent.get(counter, & &1) == 2
  end

  if Config.precompiled_manifest?() do
    test "production variants use compression and distinct validators", %{opts: opts} do
      [raw_etag] = :get |> request(opts) |> get_resp_header("etag")

      for encoding <- ~w(br gzip deflate zstd) do
        conn = request(:get, opts, [{"accept-encoding", encoding}])
        [etag] = get_resp_header(conn, "etag")
        assert conn.status == 200
        assert byte_size(conn.resp_body) < byte_size(@body)
        assert get_resp_header(conn, "content-encoding") == [encoding]
        refute etag == raw_etag

        if encoding == "gzip", do: assert(:zlib.gunzip(conn.resp_body) == @body)
        if encoding == "deflate", do: assert(:zlib.uncompress(conn.resp_body) == @body)

        cached = request(:get, opts, [{"accept-encoding", encoding}, {"if-none-match", etag}])
        assert cached.status == 304
        assert cached.resp_body == ""
      end
    end

    test "encoding negotiation respects quality values and exclusions", %{opts: opts} do
      for {accept, encoding} <- [
            {"br, gzip", ["br"]},
            {"BR;Q=1, gzip;q=0.5", ["br"]},
            {"br;q=0, gzip", ["gzip"]},
            {"br;q=0.4, gzip;q=0.8, identity;q=0", ["gzip"]},
            {"br;q=0, gzip;q=0", []},
            {"*;q=0, gzip;q=1", ["gzip"]}
          ] do
        conn = request(:get, opts, [{"accept-encoding", accept}])
        assert conn.status == 200
        assert get_resp_header(conn, "content-encoding") == encoding
      end

      assert request(:get, opts, [{"accept-encoding", "*;q=0"}]).status == 406
    end
  else
    test "development uses the uncompressed encoding profile", %{opts: opts} do
      conn = request(:get, opts, [{"accept-encoding", "br, gzip"}])
      assert conn.resp_body == @body
      assert get_resp_header(conn, "content-encoding") == []
      assert request(:get, opts, [{"accept-encoding", "*;q=0"}]).status == 406
    end
  end

  def content(counter), do: Agent.get_and_update(counter, &{[@body], &1 + 1})

  def fails_once(counter) do
    case Agent.get_and_update(counter, &{&1, &1 + 1}) do
      0 -> raise "not ready"
      _ -> @body
    end
  end

  defp request(method, opts, headers \\ []) do
    method
    |> conn("/generated.xml")
    |> put_private(:phoenix_router_url, "https://example.com")
    |> Map.put(:req_headers, headers)
    |> Static.call(opts)
  end
end
