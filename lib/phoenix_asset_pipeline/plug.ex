defmodule PhoenixAssetPipeline.Plug do
  @moduledoc """
  A plug for serving pre-compiled assets and static files.

  ## Options

    * `:only` - filters which requests to serve. This is useful to avoid
      file system access on every request when this plug is mounted
      at `"/"`. For example, if `only: ["images", "favicon.ico"]` is
      specified, only files in the "images" directory and the
      "favicon.ico" file will be served by `Plug.Static`.
      Note that `Plug.Static` matches these filters against request
      uri and not against the filesystem. When requesting
      a file with name containing non-ascii or special characters,
      you should use urlencoded form. For example, you should write
      `only: ["file%20name"]` instead of `only: ["file name"]`.
      Defaults to `nil` (no filtering).

    * `:only_matching` - a relaxed version of `:only` that will
      serve any request as long as one of the given values matches the
      given path. For example, `only_matching: ["images", "favicon"]`
      will match any request that starts at "images" or "favicon",
      be it "/images/foo.png", "/images-high/foo.png", "/favicon.ico"
      or "/favicon-high.ico". Such matches are useful when serving
      digested files at the root. Defaults to `nil` (no filtering).
  """

  import Plug.Conn

  alias PhoenixAssetPipeline.Storage
  alias Plug.Conn.Utils

  @allowed_methods ~w(GET HEAD)
  @assets_pattern ~r/(?<digest>.{32})\.(?<format>.+)$/

  @encodings [
    {"br", ".br"},
    {"deflate", ".deflate"},
    {"gzip", ".gz"}
  ]

  @static_pattern ~r/(?<path>.+)\.(?<format>.+)$/

  @doc """
  Serves pre-compiled assets.
  """
  def assets(
        %{
          method: meth,
          path_info: [path | _],
          private: %{phoenix_static_url: phoenix_static_url}
        } = conn,
        _
      )
      when meth in @allowed_methods do
    with true <- String.starts_with?(request_url(conn), phoenix_static_url),
         %{"digest" => digest, "format" => format} <-
           Regex.named_captures(@assets_pattern, URI.decode(path)) do
      accept = get_req_header(conn, "accept-encoding")
      range = get_req_header(conn, "range")
      {encoding, ext} = encoding(accept, range, @encodings)

      Storage.get(:assets, [])
      |> Enum.find_value(fn
        {"." <> ^format <> ^ext, ^digest, content, byte_size} ->
          {content, digest, byte_size, :asset}

        _ ->
          nil
      end)
      |> serve(format, encoding, range, conn)
    else
      _ -> conn
    end
  end

  def assets(conn, _), do: conn

  @doc """
  Serves pre-compiled static files.
  """
  def static(
        conn = %{
          method: meth,
          path_info: segments,
          private: %{phoenix_endpoint: phoenix_endpoint}
        },
        opts
      )
      when meth in @allowed_methods do
    only_rules = {Keyword.get(opts, :only, []), Keyword.get(opts, :only_matching, [])}

    with true <- allowed?(only_rules, segments),
         path = Enum.map_join(segments, "/", &URI.decode/1),
         %{"path" => path, "format" => format} <-
           Regex.named_captures(@static_pattern, path) do
      accept = get_req_header(conn, "accept-encoding")
      range = get_req_header(conn, "range")
      {encoding, ext} = encoding(accept, range, @encodings)

      phoenix_endpoint.assets()
      |> Enum.find_value(fn
        {"." <> ^format <> ^ext, ^path, digest, content, byte_size} ->
          {content, digest, byte_size, :static}

        _ ->
          nil
      end)
      |> serve(format, encoding, range, conn)
    else
      _ -> conn
    end
  end

  def static(conn, _), do: conn

  defp accept_encoding?(accept, encoding) do
    encoding? = &String.contains?(&1, [encoding, "*"])

    Enum.any?(accept, fn accept ->
      accept |> Utils.list() |> Enum.any?(encoding?)
    end)
  end

  defp allowed?(_, []), do: false
  defp allowed?({[], []}, _), do: true

  defp allowed?({full, prefix}, [h | _]) do
    h in full or (prefix != [] and match?({0, _}, :binary.match(h, prefix)))
  end

  defp encoding(accept, [_], _), do: encoding(accept, nil, [])

  defp encoding(accept, _, encodings) do
    Enum.find_value(encodings, {nil, ""}, fn {encoding, ext} ->
      if accept_encoding?(accept, encoding), do: {encoding, ext}
    end)
  end

  defp et_cache(:asset), do: "public, max-age=31536000, immutable"
  defp et_cache(_), do: "public"

  defp maybe_add_encoding(conn, nil), do: conn
  defp maybe_add_encoding(conn, encoding), do: put_resp_header(conn, "content-encoding", encoding)

  defp maybe_add_vary(%{adapter: {_, adapter}} = conn) do
    if Keyword.get(adapter.opts.http, :compress, true),
      do: conn,
      else: put_resp_header(conn, "vary", "accept-encoding")
  end

  defp not_found(conn) do
    conn
    |> send_resp(404, "Not found")
    |> halt()
  end

  defp put_cache_header(conn, {_, digest, _, type}) do
    conn =
      conn
      |> put_resp_header("cache-control", et_cache(type))
      |> put_resp_header("etag", digest)

    if digest in get_req_header(conn, "if-none-match"),
      do: {:fresh, conn},
      else: {:stale, conn}
  end

  defp serve_range(conn, content, byte_size, [range]) do
    with %{"bytes" => bytes} <- Utils.params(range),
         {range_start, range_end} <- start_and_end(bytes, byte_size) do
      send_range(conn, content, range_start, range_end, byte_size)
    else
      _ -> send_asset(conn, content)
    end
  end

  defp serve_range(conn, content, _, _), do: send_asset(conn, content)

  defp start_and_end("-" <> rest, byte_size) do
    case Integer.parse(rest) do
      {last, ""} when last > 0 and last <= byte_size -> {byte_size - last, byte_size - 1}
      _ -> nil
    end
  end

  defp start_and_end(range, byte_size) do
    case Integer.parse(range) do
      {first, "-"} when first >= 0 ->
        {first, byte_size - 1}

      {first, "-" <> rest} when first >= 0 ->
        case Integer.parse(rest) do
          {last, ""} when last >= first -> {first, min(last, byte_size - 1)}
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp send_range(conn, content, 0, range_end, byte_size) when range_end == byte_size - 1 do
    send_asset(conn, content)
  end

  defp send_range(conn, content, range_start, range_end, byte_size) do
    length = range_end - range_start + 1

    conn
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{byte_size}")
    |> send_resp(206, String.slice(content, range_start, length))
    |> halt()
  end

  defp send_asset(conn, content) do
    conn
    |> maybe_add_vary()
    |> put_resp_header("access-control-allow-origin", conn.private.phoenix_router_url)
    |> send_resp(200, content)
    |> halt()
  end

  defp serve(nil, _, _, _, conn), do: not_found(conn)

  defp serve({content, _, byte_size, _} = asset, format, encoding, range, conn) do
    case put_cache_header(conn, asset) do
      {:stale, conn} ->
        conn
        |> put_resp_header("content-type", MIME.type(format))
        |> put_resp_header("accept-ranges", "bytes")
        |> maybe_add_encoding(encoding)
        |> serve_range(content, byte_size, range)

      {:fresh, conn} ->
        conn
        |> maybe_add_vary()
        |> send_resp(304, "")
        |> halt()
    end
  end
end
