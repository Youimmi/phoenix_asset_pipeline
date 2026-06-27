defmodule PhoenixAssetPipeline.Plug.Static do
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

    * `:content_types` - controls custom MIME type mapping.
      It can be a map with filename as key and content type as value to override
      the default type for matching filenames. Alternatively, it can be `false`
      to opt out of setting the content type header. Defaults to manifest content types.
  """
  @behaviour Plug

  import Plug.Conn,
    only: [
      get_req_header: 2,
      halt: 1,
      put_resp_content_type: 2,
      put_resp_header: 3,
      send_resp: 3
    ]

  alias PhoenixAssetPipeline.Manifest
  alias Plug.Conn

  @allowed_methods ~w(GET HEAD)
  @impl true
  def init(opts) do
    only =
      opts
      |> Keyword.get(:only, [])
      |> List.wrap()
      |> MapSet.new()

    only_matching =
      opts
      |> Keyword.get(:only_matching, [])
      |> List.wrap()

    %{
      content_types: content_types(opts),
      only_rules: {MapSet.size(only) == 0 and only_matching == [], only, only_matching}
    }
  end

  @impl true
  def call(%{method: method, path_info: [_ | _] = segments} = conn, %{only_rules: only_rules} = opts)
      when method in @allowed_methods do
    case static_asset_type(conn, segments) do
      nil ->
        if static_path?(only_rules, segments),
          do: serve_static_file(conn, segments, opts),
          else: conn

      type ->
        serve_static_asset(conn, segments, type, opts)
    end
  end

  @impl true
  def call(conn, _), do: conn

  defp accepted_encoding_tokens([token | rest], acc) do
    token = trim_ascii(token)

    case :binary.split(token, ";") do
      [encoding] ->
        accepted_encoding_tokens(rest, put_accepted_encoding(trim_ascii(encoding), 1, acc))

      [encoding, params] ->
        accepted_encoding_tokens(rest, put_accepted_encoding(trim_ascii(encoding), qvalue(params), acc))
    end
  end

  defp accepted_encoding_tokens([], acc), do: acc

  defp accepted_encodings([header | rest], acc) do
    accepted_encodings(rest, accepted_encoding_tokens(:binary.split(header, ",", [:global]), acc))
  end

  defp accepted_encodings([], acc), do: acc

  defp content(data, nil), do: data["raw"]
  defp content(data, encoding), do: data[encoding]

  defp static_content(data, nil), do: data["raw"]
  defp static_content(data, encoding), do: data[encoding]

  defp content_types(opts) do
    case Keyword.get(opts, :content_types) do
      content_types when content_types == %{} -> nil
      content_types -> content_types
    end
  end

  defp decode_segment(segment) do
    if String.contains?(segment, "%"),
      do: URI.decode(segment),
      else: segment
  end

  defp digested_asset_type(path) do
    size = byte_size(path)

    case stem_size(path, size) do
      nil -> nil
      {type, stem_size} -> if digested_stem?(path, stem_size), do: type
    end
  end

  defp digested_stem?(path, 32), do: hex?(path, 0, 32)

  defp digested_stem?(path, stem_size) when stem_size > 33 do
    digest_start = stem_size - 32

    :binary.at(path, digest_start - 1) == ?- and word_prefix?(path, digest_start - 1) and
      hex?(path, digest_start, stem_size)
  end

  defp digested_stem?(_, _), do: false

  defp encoding(_, [_]), do: nil

  defp encoding(accept, _) do
    accept
    |> accepted_encodings({:unset, :unset, :unset, :unset, :unset})
    |> preferred_encoding()
  end

  defp etag_match?("*", _), do: true

  defp etag_match?(tag, etag), do: tag == etag

  defp fresh_etag?(headers, etag) do
    Enum.any?(headers, fn header ->
      header
      |> Conn.Utils.list()
      |> Enum.any?(&etag_match?(&1, etag))
    end)
  end

  defp hex?(_, stop, stop), do: true

  defp hex?(path, index, stop) do
    char = :binary.at(path, index)

    ((char >= ?0 and char <= ?9) or (char >= ?a and char <= ?f)) and
      hex?(path, index + 1, stop)
  end

  defp maybe_add_encoding(conn, nil), do: conn
  defp maybe_add_encoding(conn, encoding), do: put_resp_header(conn, "content-encoding", encoding)

  defp maybe_add_vary(conn) do
    update_in(conn.resp_headers, &[{"vary", "Accept-Encoding"} | &1])
  end

  defp maybe_put_content_type(conn, false, _, _), do: conn

  defp maybe_put_content_type(conn, nil, %{content_type: content_type}, _) do
    put_resp_content_type(conn, content_type)
  end

  defp maybe_put_content_type(conn, content_types, asset, path) do
    content_type =
      Map.get(content_types, Path.basename(path)) ||
        asset.content_type

    put_resp_content_type(conn, content_type)
  end

  defp not_found(conn) do
    conn
    |> send_resp(:not_found, "Not found")
    |> halt()
  end

  defp parse_qvalue(value) do
    case Float.parse(String.trim(trim_ascii(value), ~s("))) do
      {q, ""} when q >= 0 and q <= 1 -> q
      _ -> 0
    end
  end

  defp path_raw([segment]), do: segment
  defp path_raw(segments), do: Enum.join(segments, "/")

  defp path([segment]), do: decode_segment(segment)

  defp path(segments), do: Enum.map_join(segments, "/", &decode_segment/1)

  defp qvalue(params) do
    params
    |> :binary.split(";", [:global])
    |> qvalue(1)
  end

  defp qvalue([param | rest], default) do
    case :binary.split(trim_ascii(param), "=") do
      ["q", value] -> parse_qvalue(value)
      _ -> qvalue(rest, default)
    end
  end

  defp qvalue([], default), do: default

  defp put_accepted_encoding("br", qvalue, {_, zstd, deflate, gzip, wildcard}) do
    {qvalue, zstd, deflate, gzip, wildcard}
  end

  defp put_accepted_encoding("zstd", qvalue, {br, _, deflate, gzip, wildcard}) do
    {br, qvalue, deflate, gzip, wildcard}
  end

  defp put_accepted_encoding("deflate", qvalue, {br, zstd, _, gzip, wildcard}) do
    {br, zstd, qvalue, gzip, wildcard}
  end

  defp put_accepted_encoding("gzip", qvalue, {br, zstd, deflate, _, wildcard}) do
    {br, zstd, deflate, qvalue, wildcard}
  end

  defp put_accepted_encoding("*", qvalue, {br, zstd, deflate, gzip, _}) do
    {br, zstd, deflate, gzip, qvalue}
  end

  defp put_accepted_encoding(_, _, acc), do: acc

  defp preferred_encoding({br, zstd, deflate, gzip, wildcard}) do
    {"br", qvalue_or_wildcard(br, wildcard)}
    |> preferred_encoding({"zstd", qvalue_or_wildcard(zstd, wildcard)})
    |> preferred_encoding({"deflate", qvalue_or_wildcard(deflate, wildcard)})
    |> preferred_encoding({"gzip", qvalue_or_wildcard(gzip, wildcard)})
    |> elem(0)
  end

  defp preferred_encoding({_, qvalue}, {encoding, candidate}) when candidate > qvalue and candidate > 0 do
    {encoding, candidate}
  end

  defp preferred_encoding({encoding, qvalue}, _) when qvalue > 0 do
    {encoding, qvalue}
  end

  defp preferred_encoding(_, {encoding, candidate}) when candidate > 0 do
    {encoding, candidate}
  end

  defp preferred_encoding(_, _), do: {nil, 0}

  defp qvalue_or_wildcard(:unset, :unset), do: 0
  defp qvalue_or_wildcard(:unset, wildcard), do: wildcard
  defp qvalue_or_wildcard(qvalue, _), do: qvalue

  defp send_range(conn, content, 0, range_end, byte_size) when range_end == byte_size - 1 do
    serve(conn, content)
  end

  defp send_range(conn, content, range_start, range_end, byte_size) do
    length = range_end - range_start + 1

    conn
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{byte_size}")
    |> send_resp(:partial_content, :binary.part(content, range_start, length))
    |> halt()
  end

  defp serve(conn, content) do
    conn
    |> maybe_add_vary()
    |> send_resp(:ok, content)
    |> halt()
  end

  defp serve_range(conn, content, byte_size, [range]) do
    with "bytes=" <> bytes <- range,
         true <- byte_size(bytes) <= 41,
         {range_start, range_end} <- start_and_end(bytes, byte_size) do
      send_range(conn, content, range_start, range_end, byte_size)
    else
      _ -> serve(conn, content)
    end
  end

  defp serve_range(conn, content, _, _), do: serve(conn, content)

  defp send_asset(
         %{private: %{phoenix_router_url: router_url}} = conn,
         content,
         byte_size,
         encoding,
         range,
         asset,
         path,
         opts
       ) do
    conn
    |> maybe_add_encoding(encoding)
    |> maybe_put_content_type(opts.content_types, asset, path)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("access-control-allow-origin", router_url)
    |> serve_range(content, byte_size, range)
  end

  defp serve_asset(conn, data, asset, path, opts) do
    range = get_req_header(conn, "range")

    encoding =
      conn
      |> get_req_header("accept-encoding")
      |> encoding(range)

    {content, byte_size} = content(data, encoding)

    send_asset(conn, content, byte_size, encoding, range, asset, path, opts)
  end

  defp serve_static_asset(conn, segments, type, opts) do
    path = path_raw(segments)

    case Manifest.find(type, path) do
      %{data: data} = asset ->
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000, immutable")
        |> serve_asset(data, asset, path, opts)

      _ ->
        not_found(conn)
    end
  end

  defp serve_static_file(conn, segments, opts) do
    path = path(segments)

    case Manifest.find(:static_files, path) do
      %{data: data} = asset ->
        range = get_req_header(conn, "range")

        encoding =
          conn
          |> get_req_header("accept-encoding")
          |> encoding(range)

        {content, byte_size, etag} = static_content(data, encoding)

        conn =
          conn
          |> put_resp_header("cache-control", "public")
          |> put_resp_header("etag", etag)

        if fresh_etag?(get_req_header(conn, "if-none-match"), etag) do
          conn
          |> maybe_add_vary()
          |> send_resp(:not_modified, "")
          |> halt()
        else
          send_asset(conn, content, byte_size, encoding, range, asset, path, opts)
        end

      _ ->
        not_found(conn)
    end
  end

  defp start_and_end("-" <> rest, byte_size) do
    case Integer.parse(rest) do
      {last, ""} when last > 0 and last <= byte_size -> {byte_size - last, byte_size - 1}
      _ -> :error
    end
  end

  defp start_and_end(range, byte_size) do
    case Integer.parse(range) do
      {first, "-"} when first >= 0 and first < byte_size ->
        {first, byte_size - 1}

      {first, "-" <> rest} when first >= 0 and first < byte_size ->
        case Integer.parse(rest) do
          {last, ""} when last >= first -> {first, min(last, byte_size - 1)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp static_asset_type(%{host: host, private: %{phoenix_router_host: router_host, phoenix_static_host: static_host}}, [
         path | _
       ])
       when host == static_host and static_host != router_host do
    digested_asset_type(path)
  end

  defp static_asset_type(%{host: host, private: %{phoenix_router_host: router_host}}, [path | _])
       when host == router_host do
    digested_asset_type(path)
  end

  defp static_asset_type(_, _), do: nil

  defp static_path?({true, _, _}, _), do: true

  defp static_path?({false, full, prefix}, [h | _]) do
    MapSet.member?(full, h) or (prefix != [] and String.starts_with?(h, prefix))
  end

  defp stem_size(path, size) when size > 3 do
    cond do
      :binary.part(path, size - 3, 3) == ".js" -> {:scripts, size - 3}
      size > 4 and :binary.part(path, size - 4, 4) in [".png", ".svg"] -> {:images, size - 4}
      size > 5 and :binary.part(path, size - 5, 5) in [".avif", ".webp"] -> {:images, size - 5}
      true -> nil
    end
  end

  defp stem_size(_, _), do: nil

  defp trim_ascii(binary), do: trim_ascii_left(binary)

  defp trim_ascii_left(<<char, rest::binary>>) when char in [?\s, ?\t], do: trim_ascii_left(rest)
  defp trim_ascii_left(binary), do: trim_ascii_right(binary, byte_size(binary))

  defp trim_ascii_right(binary, size) when size > 0 do
    case :binary.at(binary, size - 1) do
      char when char in [?\s, ?\t] -> trim_ascii_right(binary, size - 1)
      _ -> :binary.part(binary, 0, size)
    end
  end

  defp trim_ascii_right(_, 0), do: ""

  defp word_char?(char) do
    (char >= ?0 and char <= ?9) or (char >= ?A and char <= ?Z) or char == ?_ or
      (char >= ?a and char <= ?z)
  end

  defp word_prefix?(_, 0), do: false
  defp word_prefix?(path, stop), do: word_prefix?(path, 0, stop)
  defp word_prefix?(_, stop, stop), do: true

  defp word_prefix?(path, index, stop) do
    word_char?(:binary.at(path, index)) and word_prefix?(path, index + 1, stop)
  end
end
