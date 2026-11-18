defmodule PhoenixAssetPipeline.Plug.Static do
  @moduledoc """
  A plug for serving pre-compiled assets and static files from the manifest.

  Digested assets are served on the router and static hosts regardless of the
  filters below. Other `GET` and `HEAD` requests are looked up among the
  manifest's static files. Without filters, a path that is not in the manifest
  passes through to the next plug. With `:only` or `:only_matching`, a path that
  matches a filter but is not in the manifest receives `404`, so a filter must
  not cover paths handled by the router.

  ## Options

    * `:only` - filters which requests to serve by their first path segment.
      For example, if `only: ["images", "favicon.ico"]` is specified, only
      files in the "images" directory and the "favicon.ico" file are served.
      Filters are matched against the request URI as received. When requesting
      a file with name containing non-ascii or special characters,
      you should use urlencoded form. For example, you should write
      `only: ["file%20name"]` instead of `only: ["file name"]`.
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
      delete_resp_header: 2,
      get_req_header: 2,
      halt: 1,
      put_resp_content_type: 2,
      put_resp_header: 3,
      send_resp: 3
    ]

  alias PhoenixAssetPipeline.Manifest
  alias PhoenixAssetPipeline.StaticAsset

  @allowed_methods ~w(GET HEAD)

  @impl true
  def call(%{method: method, path_info: [segment | _] = segments} = conn, %{only_rules: only_rules} = opts)
      when method in @allowed_methods do
    case static_asset(conn, segments) do
      nil ->
        if static_path?(only_rules, segment),
          do: serve_static_file(conn, path(segments), opts),
          else: conn

      asset ->
        serve(conn, asset, segment, "public, max-age=31536000, immutable", opts)
    end
  end

  @impl true
  def call(conn, _), do: conn

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

  defp accepted_encoding_value(value, acc) do
    case :binary.match(value, ";") do
      :nomatch ->
        put_accepted_encoding(trim_ows(value), 1000, acc)

      {index, 1} ->
        encoding = value |> binary_part(0, index) |> trim_ows()
        params = binary_part(value, index + 1, byte_size(value) - index - 1)
        put_accepted_encoding(encoding, qvalue(params, 1000), acc)
    end
  end

  defp accepted_encoding_values(header, acc) do
    case :binary.match(header, ",") do
      :nomatch ->
        accepted_encoding_value(header, acc)

      {index, 1} ->
        encoding = binary_part(header, 0, index)
        rest = binary_part(header, index + 1, byte_size(header) - index - 1)
        accepted_encoding_values(rest, accepted_encoding_value(encoding, acc))
    end
  end

  defp accepted_encodings(["gzip, deflate, br, zstd" | rest], {_, _, _, _, wildcard, identity}) do
    accepted_encodings(rest, {1000, 1000, 1000, 1000, wildcard, identity})
  end

  defp accepted_encodings(["gzip, deflate, br" | rest], {_, zstd, _, _, wildcard, identity}) do
    accepted_encodings(rest, {1000, zstd, 1000, 1000, wildcard, identity})
  end

  defp accepted_encodings(["gzip, deflate" | rest], {br, zstd, _, _, wildcard, identity}) do
    accepted_encodings(rest, {br, zstd, 1000, 1000, wildcard, identity})
  end

  defp accepted_encodings([header | rest], acc) do
    accepted_encodings(rest, accepted_encoding_values(header, acc))
  end

  defp accepted_encodings([], acc), do: acc

  defp available_qvalue(data, encoding, qvalue) do
    if :erlang.is_map_key(encoding, data), do: qvalue, else: 0
  end

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

  defp digested_asset(<<_::binary-size(64), extension::binary>> = path) do
    if (extension == "" or match?(<<?., _::binary>>, extension)) and hex?(path, 0, 64) do
      case extension do
        ".js" -> Manifest.find(:scripts, path) || Manifest.find(:images, path)
        _ -> Manifest.find(:images, path)
      end
    end
  end

  defp digested_asset(_), do: nil

  defp encoding([], _), do: "raw"

  defp encoding(accept, data) do
    accept
    |> accepted_encodings({:unset, :unset, :unset, :unset, :unset, :unset})
    |> preferred_encoding(data)
  end

  defp etag_header_match?(_, _, index, size, _) when index >= size, do: false

  defp etag_header_match?(header, etag, index, size, weak?) do
    index = skip_etag_separators(header, index, size)

    if index < size do
      start = weak_etag_start(header, index, size)

      case etag_stop(header, start, size) do
        nil ->
          false

        stop ->
          ((weak? or start == index) and etag_part_match?(header, start, stop, etag)) or
            etag_header_match?(header, etag, stop, size, weak?)
      end
    else
      false
    end
  end

  defp etag_part_match?(header, start, stop, etag) do
    size = stop - start
    size >= byte_size(etag) and trim_ows_right(:binary.part(header, start, size), size) == etag
  end

  defp etag_stop(header, index, size) when index < size do
    if :binary.at(header, index) == ?" do
      case :binary.match(header, "\"", scope: {index + 1, size - index - 1}) do
        {stop, 1} -> etag_stop(header, stop + 1, size)
        :nomatch -> nil
      end
    else
      case :binary.match(header, ",", scope: {index, size - index}) do
        {stop, 1} -> stop
        :nomatch -> size
      end
    end
  end

  defp etag_stop(_, index, _), do: index

  defp finish_range(first, "", byte_size) when first < byte_size do
    {:range, first, byte_size - 1}
  end

  defp finish_range(_, "", _), do: :unsatisfiable

  defp finish_range(first, rest, byte_size) do
    case Integer.parse(rest) do
      {last, ""} when first < byte_size and last >= first -> {:range, first, min(last, byte_size - 1)}
      {last, ""} when last >= 0 -> :unsatisfiable
      _ -> :none
    end
  end

  defp fresh_etag?([], _), do: false
  defp fresh_etag?([header], nil), do: trim_ows(header) == "*"

  defp fresh_etag?([header], etag) do
    header = trim_ows(header)
    header == etag or header == "*" or etag_header_match?(header, etag, 0, byte_size(header), true)
  end

  defp fresh_etag?(headers, etag) do
    Enum.any?(headers, &fresh_etag?([&1], etag))
  end

  defp hex?(_, stop, stop), do: true

  defp hex?(path, index, stop) do
    char = :binary.at(path, index)

    ((char >= ?0 and char <= ?9) or (char >= ?a and char <= ?f)) and
      hex?(path, index + 1, stop)
  end

  defp if_match?([], _), do: true

  defp if_match?(headers, entry) do
    case Enum.map(headers, &trim_ows/1) do
      ["*"] ->
        true

      headers ->
        tuple_size(entry) == 3 and
          Enum.any?(headers, &etag_header_match?(&1, elem(entry, 2), 0, byte_size(&1), false))
    end
  end

  defp parse_qvalue("0"), do: 0
  defp parse_qvalue("0."), do: 0
  defp parse_qvalue(<<"0.", digit>>) when digit in ?0..?9, do: (digit - ?0) * 100

  defp parse_qvalue(<<"0.", first, second>>) when first in ?0..?9 and second in ?0..?9 do
    (first - ?0) * 100 + (second - ?0) * 10
  end

  defp parse_qvalue(<<"0.", first, second, third>>) when first in ?0..?9 and second in ?0..?9 and third in ?0..?9 do
    (first - ?0) * 100 + (second - ?0) * 10 + third - ?0
  end

  defp parse_qvalue("1"), do: 1000
  defp parse_qvalue("1."), do: 1000
  defp parse_qvalue("1.0"), do: 1000
  defp parse_qvalue("1.00"), do: 1000
  defp parse_qvalue("1.000"), do: 1000
  defp parse_qvalue(_), do: 0

  defp path([segment]), do: decode_segment(segment)

  defp path(segments), do: Enum.map_join(segments, "/", &decode_segment/1)

  defp preferred_encoding({br, zstd, deflate, gzip, wildcard, identity}, data) do
    br = available_qvalue(data, "br", qvalue_or_wildcard(br, wildcard, 0))
    zstd = available_qvalue(data, "zstd", qvalue_or_wildcard(zstd, wildcard, 0))
    deflate = available_qvalue(data, "deflate", qvalue_or_wildcard(deflate, wildcard, 0))
    gzip = available_qvalue(data, "gzip", qvalue_or_wildcard(gzip, wildcard, 0))
    # Unlisted identity stays acceptable but ranks below every accepted coding.
    identity = available_qvalue(data, "raw", qvalue_or_wildcard(identity, wildcard, 1))

    case max(max(br, zstd), max(deflate, max(gzip, identity))) do
      qvalue when qvalue <= 0 -> :not_acceptable
      ^br -> "br"
      ^zstd -> "zstd"
      ^deflate -> "deflate"
      ^gzip -> "gzip"
      _ -> "raw"
    end
  end

  defp prepare(%{private: %{phoenix_router_origin: router_origin}} = conn, encoding, asset, path, opts) do
    conn
    |> put_encoding(encoding)
    |> put_content_type(opts.content_types, asset, path)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("access-control-allow-origin", router_origin)
    |> put_vary()
  end

  defp put_accepted_encoding("br", qvalue, {_, zstd, deflate, gzip, wildcard, identity}) do
    {qvalue, zstd, deflate, gzip, wildcard, identity}
  end

  defp put_accepted_encoding("zstd", qvalue, {br, _, deflate, gzip, wildcard, identity}) do
    {br, qvalue, deflate, gzip, wildcard, identity}
  end

  defp put_accepted_encoding("deflate", qvalue, {br, zstd, _, gzip, wildcard, identity}) do
    {br, zstd, qvalue, gzip, wildcard, identity}
  end

  defp put_accepted_encoding("gzip", qvalue, {br, zstd, deflate, _, wildcard, identity}) do
    {br, zstd, deflate, qvalue, wildcard, identity}
  end

  defp put_accepted_encoding("*", qvalue, {br, zstd, deflate, gzip, _, identity}) do
    {br, zstd, deflate, gzip, qvalue, identity}
  end

  defp put_accepted_encoding("identity", qvalue, {br, zstd, deflate, gzip, wildcard, _}) do
    {br, zstd, deflate, gzip, wildcard, qvalue}
  end

  defp put_accepted_encoding(encoding, qvalue, acc) do
    case String.downcase(encoding) do
      ^encoding -> acc
      encoding -> put_accepted_encoding(encoding, qvalue, acc)
    end
  end

  defp put_cache_control(conn, value, path) do
    value = if StaticAsset.already_compressed?(path), do: value <> ", no-transform", else: value
    put_resp_header(conn, "cache-control", value)
  end

  defp put_content_type(conn, false, _, _), do: conn

  # Without a declared type `nosniff` would make browsers refuse scripts and styles.
  defp put_content_type(conn, content_types, asset, path) do
    content_type = (content_types && Map.get(content_types, Path.basename(path))) || asset.content_type

    conn
    |> put_resp_content_type(content_type)
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp put_encoding(conn, "raw"), do: conn
  defp put_encoding(conn, encoding), do: put_resp_header(conn, "content-encoding", encoding)

  defp put_vary(conn), do: update_in(conn.resp_headers, &[{"vary", "Accept-Encoding"} | &1])

  defp qvalue(params, default) do
    case :binary.match(params, ";") do
      :nomatch ->
        qvalue_param(params, default)

      {index, 1} ->
        param = binary_part(params, 0, index)
        rest = binary_part(params, index + 1, byte_size(params) - index - 1)

        case qvalue_param(param, :missing) do
          :missing -> qvalue(rest, default)
          qvalue -> qvalue
        end
    end
  end

  defp qvalue_or_wildcard(:unset, :unset, default), do: default
  defp qvalue_or_wildcard(:unset, wildcard, _), do: wildcard
  defp qvalue_or_wildcard(qvalue, _, _), do: qvalue

  defp qvalue_param(param, default) do
    case :binary.match(param, "=") do
      :nomatch ->
        default

      {index, 1} ->
        name = param |> binary_part(0, index) |> trim_ows()

        if name in ["q", "Q"] do
          param
          |> binary_part(index + 1, byte_size(param) - index - 1)
          |> trim_ows()
          |> parse_qvalue()
        else
          default
        end
    end
  end

  defp request_range(%{method: "GET"} = conn, byte_size, etag) do
    with ["bytes=" <> bytes] when byte_size(bytes) <= 41 <- get_req_header(conn, "range"),
         if_range = get_req_header(conn, "if-range"),
         true <- if_range == [] or match?([^etag], if_range) do
      start_and_end(bytes, byte_size)
    else
      _ -> :none
    end
  end

  defp request_range(_, _, _), do: :none

  defp send_range(conn, content, byte_size, {:range, range_start, range_end}) do
    conn
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{byte_size}")
    |> send_resp(:partial_content, :binary.part(content, range_start, range_end - range_start + 1))
    |> halt()
  end

  defp send_range(conn, _, byte_size, :unsatisfiable) do
    conn
    |> delete_resp_header("cache-control")
    |> delete_resp_header("content-encoding")
    |> put_resp_header("content-range", "bytes */#{byte_size}")
    |> send_resp(416, "")
    |> halt()
  end

  defp send_range(conn, content, _, :none) do
    conn
    |> send_resp(:ok, content)
    |> halt()
  end

  defp serve(conn, %{data: data} = asset, path, cache_control, opts) do
    case encoding(get_req_header(conn, "accept-encoding"), data) do
      :not_acceptable ->
        conn
        |> put_vary()
        |> send_resp(:not_acceptable, "Not acceptable")
        |> halt()

      encoding ->
        entry = :erlang.map_get(encoding, data)

        if if_match?(get_req_header(conn, "if-match"), entry) do
          conn
          |> put_cache_control(cache_control, path)
          |> serve_entry(entry, encoding, asset, path, opts)
        else
          conn
          |> put_vary()
          |> send_resp(:precondition_failed, "")
          |> halt()
        end
    end
  end

  # Digested assets are immutable and carry no ETag, so only `If-None-Match: *` can match.
  defp serve_entry(conn, {content, byte_size}, encoding, asset, path, opts) do
    conn = prepare(conn, encoding, asset, path, opts)

    if fresh_etag?(get_req_header(conn, "if-none-match"), nil) do
      conn
      |> send_resp(:not_modified, "")
      |> halt()
    else
      send_range(conn, content, byte_size, request_range(conn, byte_size, nil))
    end
  end

  defp serve_entry(conn, {content, byte_size, etag}, encoding, asset, path, opts) do
    conn =
      conn
      |> put_resp_header("etag", etag)
      |> prepare(encoding, asset, path, opts)

    if fresh_etag?(get_req_header(conn, "if-none-match"), etag) do
      conn
      |> send_resp(:not_modified, "")
      |> halt()
    else
      send_range(conn, content, byte_size, request_range(conn, byte_size, etag))
    end
  end

  defp serve_static_file(conn, path, opts) do
    case Manifest.find(:static_files, path) do
      %{data: _} = asset ->
        serve(conn, asset, path, "public", opts)

      nil when elem(opts.only_rules, 0) ->
        conn

      _ ->
        conn
        |> send_resp(:not_found, "Not found")
        |> halt()
    end
  end

  defp skip_etag_separators(header, index, size) when index < size do
    if :binary.at(header, index) in [?,, ?\s, ?\t],
      do: skip_etag_separators(header, index + 1, size),
      else: index
  end

  defp skip_etag_separators(_, index, _), do: index

  defp start_and_end("-" <> rest, byte_size) do
    case Integer.parse(rest) do
      {last, ""} when last > 0 and byte_size > 0 -> {:range, max(byte_size - last, 0), byte_size - 1}
      {last, ""} when last >= 0 -> :unsatisfiable
      _ -> :none
    end
  end

  defp start_and_end(range, byte_size) do
    case Integer.parse(range) do
      {first, "-" <> rest} when first >= 0 -> finish_range(first, rest, byte_size)
      _ -> :none
    end
  end

  defp static_asset(%{host: host, private: %{phoenix_router_host: router_host, phoenix_static_host: static_host}}, [
         <<_::binary-size(64), _::binary>> = path
       ]) do
    if host == router_host or host == static_host or String.downcase(host) in [router_host, static_host],
      do: digested_asset(path)
  end

  defp static_asset(_, _), do: nil

  defp static_path?({true, _, _}, _), do: true

  defp static_path?({false, full, prefix}, segment) do
    MapSet.member?(full, segment) or (prefix != [] and String.starts_with?(segment, prefix))
  end

  # Optional whitespace in HTTP field values is only spaces and tabs.
  defp trim_ows(<<char, rest::binary>>) when char in [?\s, ?\t], do: trim_ows(rest)
  defp trim_ows(binary), do: trim_ows_right(binary, byte_size(binary))

  defp trim_ows_right(binary, size) when size > 0 do
    case :binary.at(binary, size - 1) do
      char when char in [?\s, ?\t] -> trim_ows_right(binary, size - 1)
      _ -> :binary.part(binary, 0, size)
    end
  end

  defp trim_ows_right(_, 0), do: ""

  defp weak_etag_start(header, index, size) when index + 1 < size do
    if :binary.part(header, index, 2) == "W/", do: index + 2, else: index
  end

  defp weak_etag_start(_, index, _), do: index
end
