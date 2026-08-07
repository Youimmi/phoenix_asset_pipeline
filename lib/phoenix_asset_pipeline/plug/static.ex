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

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest

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

  defp accepted_encoding_value(value, acc) do
    case :binary.match(value, ";") do
      :nomatch ->
        put_accepted_encoding(trim_ascii(value), 1000, acc)

      {index, 1} ->
        encoding = value |> binary_part(0, index) |> trim_ascii()
        params = binary_part(value, index + 1, byte_size(value) - index - 1)
        put_accepted_encoding(encoding, qvalue(params, 1000), acc)
    end
  end

  defp already_compressed?(path) do
    extension = path |> Path.extname() |> String.downcase()
    is_map_key(Config.already_compressed_extensions(), extension)
  end

  defp content(data, nil), do: data["raw"]
  defp content(data, encoding), do: data[encoding]

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

  defp digested_stem?(_, _), do: false

  defp encoding([], _, _), do: nil

  defp encoding(accept, range, data) do
    accepted = accepted_encodings(accept, {:unset, :unset, :unset, :unset, :unset, :unset})

    if range == :none,
      do: preferred_encoding(accepted, data),
      else: preferred_identity(accepted, data)
  end

  defp fresh_etag?(headers, etag) do
    Enum.any?(headers, &etag_header_match?(&1, etag, 0, byte_size(&1)))
  end

  defp etag_header_match?(_, _, index, size) when index >= size, do: false

  defp etag_header_match?(header, etag, index, size) do
    index = skip_etag_separators(header, index, size)

    cond do
      index >= size ->
        false

      wildcard_etag?(header, index, size) ->
        true

      true ->
        start = weak_etag_start(header, index, size)

        case etag_stop(header, start, size) do
          nil -> false
          stop -> etag_part_match?(header, start, stop, etag) or etag_header_match?(header, etag, stop, size)
        end
    end
  end

  defp etag_part_match?(header, start, stop, etag) do
    size = stop - start
    size == byte_size(etag) and :binary.part(header, start, size) == etag
  end

  defp etag_stop(header, index, size) when index < size do
    if :binary.at(header, index) == ?" do
      case :binary.match(header, "\"", scope: {index + 1, size - index - 1}) do
        {stop, 1} -> stop + 1
        :nomatch -> nil
      end
    else
      case :binary.match(header, ",", scope: {index, size - index}) do
        {stop, 1} -> stop
        :nomatch -> size
      end
    end
  end

  defp etag_stop(_, _, _), do: nil

  defp skip_etag_separators(header, index, size) when index < size do
    if :binary.at(header, index) in [?,, ?\s, ?\t],
      do: skip_etag_separators(header, index + 1, size),
      else: index
  end

  defp skip_etag_separators(_, index, _), do: index

  defp weak_etag_start(header, index, size) when index + 1 < size do
    if :binary.part(header, index, 2) == "W/", do: index + 2, else: index
  end

  defp weak_etag_start(_, index, _), do: index

  defp wildcard_etag?(header, index, size) do
    :binary.at(header, index) == ?* and
      (index + 1 == size or :binary.at(header, index + 1) in [?,, ?\s, ?\t])
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

  defp not_acceptable(conn) do
    conn
    |> maybe_add_vary()
    |> send_resp(:not_acceptable, "Not acceptable")
    |> halt()
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

  defp path_raw([segment]), do: segment
  defp path_raw(segments), do: Enum.join(segments, "/")

  defp path([segment]), do: decode_segment(segment)

  defp path(segments), do: Enum.map_join(segments, "/", &decode_segment/1)

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

  defp qvalue_param(param, default) do
    case :binary.match(param, "=") do
      :nomatch ->
        default

      {index, 1} ->
        name = param |> binary_part(0, index) |> trim_ascii()

        if name in ["q", "Q"] do
          param
          |> binary_part(index + 1, byte_size(param) - index - 1)
          |> trim_ascii()
          |> parse_qvalue()
        else
          default
        end
    end
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
    value = if already_compressed?(path), do: value <> ", no-transform", else: value
    put_resp_header(conn, "cache-control", value)
  end

  defp preferred_encoding({br, zstd, deflate, gzip, wildcard, identity}, data) do
    br = available_qvalue(data, "br", qvalue_or_wildcard(br, wildcard))
    zstd = available_qvalue(data, "zstd", qvalue_or_wildcard(zstd, wildcard))
    deflate = available_qvalue(data, "deflate", qvalue_or_wildcard(deflate, wildcard))
    gzip = available_qvalue(data, "gzip", qvalue_or_wildcard(gzip, wildcard))
    identity = available_qvalue(data, "raw", identity_qvalue(identity, wildcard))

    case max(max(br, zstd), max(deflate, max(gzip, identity))) do
      qvalue when qvalue <= 0 -> :not_acceptable
      ^br -> "br"
      ^zstd -> "zstd"
      ^deflate -> "deflate"
      ^gzip -> "gzip"
      _ -> nil
    end
  end

  defp preferred_identity({_, _, _, _, wildcard, identity}, data) do
    if available_qvalue(data, "raw", identity_qvalue(identity, wildcard)) > 0,
      do: nil,
      else: :not_acceptable
  end

  defp available_qvalue(data, encoding, qvalue) do
    if :erlang.is_map_key(encoding, data), do: qvalue, else: 0
  end

  defp identity_qvalue(:unset, 0), do: 0
  defp identity_qvalue(:unset, _), do: 1000
  defp identity_qvalue(qvalue, _), do: qvalue

  defp qvalue_or_wildcard(:unset, :unset), do: 0
  defp qvalue_or_wildcard(:unset, wildcard), do: wildcard
  defp qvalue_or_wildcard(qvalue, _), do: qvalue

  defp send_range(conn, content, range_start, range_end, byte_size) do
    length = range_end - range_start + 1

    conn
    |> maybe_add_vary()
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{byte_size}")
    |> send_resp(:partial_content, :binary.part(content, range_start, length))
    |> halt()
  end

  defp send_unsatisfiable_range(conn, byte_size) do
    conn
    |> maybe_add_vary()
    |> put_resp_header("content-range", "bytes */#{byte_size}")
    |> send_resp(416, "")
    |> halt()
  end

  defp serve(conn, content) do
    conn
    |> maybe_add_vary()
    |> send_resp(:ok, content)
    |> halt()
  end

  defp serve_range(conn, content, byte_size, {:range, range_start, range_end}) do
    send_range(conn, content, range_start, range_end, byte_size)
  end

  defp serve_range(conn, content, _, :none), do: serve(conn, content)

  defp prepare_asset(%{private: %{phoenix_router_url: router_url}} = conn, encoding, asset, path, opts) do
    conn
    |> maybe_add_encoding(encoding)
    |> maybe_put_content_type(opts.content_types, asset, path)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("access-control-allow-origin", router_url)
  end

  defp send_asset(conn, content, byte_size, encoding, range, asset, path, opts) do
    conn
    |> prepare_asset(encoding, asset, path, opts)
    |> serve_range(content, byte_size, range)
  end

  defp serve_asset(conn, data, asset, path, opts) do
    {_, raw_byte_size} = data["raw"]
    range = request_range(get_req_header(conn, "range"), raw_byte_size)

    encoding =
      conn
      |> get_req_header("accept-encoding")
      |> encoding(range, data)

    case {range, encoding} do
      {:unsatisfiable, _} ->
        conn
        |> prepare_asset(nil, asset, path, opts)
        |> send_unsatisfiable_range(raw_byte_size)

      {_, :not_acceptable} ->
        not_acceptable(conn)

      _ ->
        {content, byte_size} = content(data, encoding)
        send_asset(conn, content, byte_size, encoding, range, asset, path, opts)
    end
  end

  defp serve_static_asset(conn, segments, type, opts) do
    path = path_raw(segments)

    case Manifest.find(type, path) do
      %{data: data} = asset ->
        conn
        |> put_cache_control("public, max-age=31536000, immutable", path)
        |> serve_asset(data, asset, path, opts)

      _ ->
        not_found(conn)
    end
  end

  defp serve_static_file(conn, segments, opts) do
    path = path(segments)

    case Manifest.find(:static_files, path) do
      %{data: _} = asset ->
        serve_static_file(conn, asset, path, opts)

      _ ->
        not_found(conn)
    end
  end

  defp serve_static_file(conn, %{data: data} = asset, path, opts) do
    {_, raw_byte_size, raw_etag} = data["raw"]

    range =
      conn
      |> get_req_header("range")
      |> request_range(raw_byte_size)
      |> apply_if_range(get_req_header(conn, "if-range"), raw_etag)

    encoding =
      conn
      |> get_req_header("accept-encoding")
      |> encoding(range, data)

    case {range, encoding} do
      {:unsatisfiable, _} ->
        conn
        |> put_cache_control("public", path)
        |> put_resp_header("etag", raw_etag)
        |> prepare_asset(nil, asset, path, opts)
        |> send_unsatisfiable_range(raw_byte_size)

      {_, :not_acceptable} ->
        not_acceptable(conn)

      _ ->
        {content, byte_size, etag} = content(data, encoding)

        conn =
          conn
          |> put_cache_control("public", path)
          |> put_resp_header("etag", etag)

        if fresh_etag?(get_req_header(conn, "if-none-match"), etag) do
          conn
          |> maybe_add_vary()
          |> send_resp(:not_modified, "")
          |> halt()
        else
          send_asset(conn, content, byte_size, encoding, range, asset, path, opts)
        end
    end
  end

  defp apply_if_range(:none, _, _), do: :none
  defp apply_if_range(range, [], _), do: range
  defp apply_if_range(range, [etag], etag), do: range
  defp apply_if_range(_, _, _), do: :none

  defp request_range([], _), do: :none

  defp request_range(["bytes=" <> bytes], byte_size) when byte_size(bytes) <= 41 do
    start_and_end(bytes, byte_size)
  end

  defp request_range(_, _), do: :none

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
end
