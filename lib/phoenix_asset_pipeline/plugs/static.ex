defmodule PhoenixAssetPipeline.Static do
  @moduledoc false

  import Plug.Conn

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  alias Plug.Conn

  @behaviour Plug
  @allowed_methods ~w(GET HEAD)

  defmodule InvalidPathError do
    defexception message: "invalid path for static asset", plug_status: 400
  end

  @impl true
  def init(opts) do
    from =
      case Keyword.fetch!(opts, :from) do
        {_, _} = from -> from
        {_, _, _} = from -> from
        from when is_atom(from) -> {from, "priv/static"}
        from when is_binary(from) -> from
        _ -> raise ArgumentError, ":from must be an atom, a binary or a tuple"
      end

    encodings =
      opts
      |> Keyword.get(:encodings, [])
      |> maybe_add("br", ".br", Keyword.get(opts, :brotli, false))
      |> maybe_add("gzip", ".gz", Keyword.get(opts, :gzip, false))

    %{
      encodings: encodings,
      only_rules: {Keyword.get(opts, :only, []), Keyword.get(opts, :only_matching, [])},
      qs_cache: Keyword.get(opts, :cache_control_for_vsn_requests, "public, max-age=31536000"),
      et_cache: Keyword.get(opts, :cache_control_for_etags, "public"),
      et_generation: Keyword.get(opts, :etag_generation, nil),
      headers: Keyword.get(opts, :headers, %{}),
      content_types: Keyword.get(opts, :content_types, %{}),
      from: from,
      at: opts |> Keyword.fetch!(:at) |> Plug.Router.Utils.split()
    }
  end

  @impl true
  def call(
        conn = %Conn{method: meth},
        %{at: at, only_rules: only_rules, from: from, encodings: encodings} = options
      )
      when meth in @allowed_methods do
    segments = subset(at, conn.path_info)

    if allowed?(only_rules, segments) do
      segments = Enum.map(segments, &URI.decode/1)

      if invalid_path?(segments) do
        raise InvalidPathError
      end

      path = path(from, segments)
      range = get_req_header(conn, "range")
      encoding = file_encoding(conn, path, range, encodings)
      serve_static(encoding, conn, segments, range, options)
    else
      conn
    end
  end

  def call(conn, _) do
    conn
  end

  defp allowed?(_, []), do: false
  defp allowed?({[], []}, _list), do: true

  defp allowed?({full, prefix}, [h | _]) do
    h in full or (prefix != [] and match?({0, _}, :binary.match(h, prefix)))
  end

  defp serve_static({content_encoding, file_info, path}, conn, segments, range, options) do
    %{
      qs_cache: qs_cache,
      et_cache: et_cache,
      et_generation: et_generation,
      headers: headers,
      content_types: types
    } = options

    case put_cache_header(conn, qs_cache, et_cache, et_generation, file_info, path) do
      {:stale, conn} ->
        filename = List.last(segments)
        content_type = Map.get(types, filename) || MIME.from_path(filename)

        conn
        |> put_resp_header("content-type", content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> maybe_add_encoding(content_encoding)
        |> merge_headers(headers)
        |> serve_range(file_info, path, range, options)

      {:fresh, conn} ->
        conn
        |> maybe_add_vary(options)
        |> send_resp(304, "")
        |> halt()
    end
  end

  defp serve_static(:error, conn, _, _, _) do
    conn
  end

  defp serve_range(conn, file_info, path, [range], options) do
    file_info(size: file_size) = file_info

    with %{"bytes" => bytes} <- Plug.Conn.Utils.params(range),
         {range_start, range_end} <- start_and_end(bytes, file_size) do
      send_range(conn, path, range_start, range_end, file_size, options)
    else
      _ -> send_entire_file(conn, path, options)
    end
  end

  defp serve_range(conn, _, path, _, options) do
    send_entire_file(conn, path, options)
  end

  defp start_and_end("-" <> rest, file_size) do
    case Integer.parse(rest) do
      {last, ""} when last > 0 and last <= file_size -> {file_size - last, file_size - 1}
      _ -> :error
    end
  end

  defp start_and_end(range, file_size) do
    case Integer.parse(range) do
      {first, "-"} when first >= 0 ->
        {first, file_size - 1}

      {first, "-" <> rest} when first >= 0 ->
        case Integer.parse(rest) do
          {last, ""} when last >= first -> {first, min(last, file_size - 1)}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp send_range(conn, path, 0, range_end, file_size, options) when range_end == file_size - 1 do
    send_entire_file(conn, path, options)
  end

  defp send_range(conn, path, range_start, range_end, file_size, _) do
    length = range_end - range_start + 1

    conn
    |> put_resp_header("content-range", "bytes #{range_start}-#{range_end}/#{file_size}")
    |> send_file(206, path, range_start, length)
    |> halt()
  end

  defp send_entire_file(conn, path, options) do
    conn
    |> maybe_add_vary(options)
    |> send_file(200, path)
    |> halt()
  end

  defp maybe_add_encoding(conn, nil), do: conn
  defp maybe_add_encoding(conn, ce), do: put_resp_header(conn, "content-encoding", ce)

  defp maybe_add_vary(conn, %{encodings: encodings}) do
    if encodings != [] do
      update_in(conn.resp_headers, &[{"vary", "Accept-Encoding"} | &1])
    else
      conn
    end
  end

  defp put_cache_header(%Conn{query_string: "vsn=" <> _} = conn, qs_cache, _, _, _, _)
       when is_binary(qs_cache) do
    {:stale, put_resp_header(conn, "cache-control", qs_cache)}
  end

  defp put_cache_header(conn, _, et_cache, et_generation, file_info, path)
       when is_binary(et_cache) do
    etag = etag_for_path(file_info, et_generation, path)

    conn =
      conn
      |> put_resp_header("cache-control", et_cache)
      |> put_resp_header("etag", etag)

    if etag in get_req_header(conn, "if-none-match") do
      {:fresh, conn}
    else
      {:stale, conn}
    end
  end

  defp put_cache_header(conn, _, _, _, _, _) do
    {:stale, conn}
  end

  defp etag_for_path(file_info, et_generation, path) do
    case et_generation do
      {module, function, args} ->
        apply(module, function, [path | args])

      nil ->
        file_info(size: size, mtime: mtime) = file_info
        <<?", {size, mtime} |> :erlang.phash2() |> Integer.to_string(16)::binary, ?">>
    end
  end

  defp file_encoding(conn, path, [_], _) do
    file_encoding(conn, path, nil, [])
  end

  defp file_encoding(conn, path, _, encodings) do
    encoded =
      Enum.find_value(encodings, fn {encoding, ext} ->
        if file_info = accept_encoding?(conn, encoding) && regular_file_info(path <> ext) do
          {encoding, file_info, path <> ext}
        end
      end)

    cond do
      not is_nil(encoded) ->
        encoded

      file_info = regular_file_info(path) ->
        {nil, file_info, path}

      true ->
        :error
    end
  end

  defp regular_file_info(path) do
    case :prim_file.read_file_info(path) do
      {:ok, file_info(type: :regular) = file_info} ->
        file_info

      _ ->
        nil
    end
  end

  defp accept_encoding?(conn, encoding) do
    encoding? = &String.contains?(&1, [encoding, "*"])

    Enum.any?(get_req_header(conn, "accept-encoding"), fn accept ->
      accept |> Plug.Conn.Utils.list() |> Enum.any?(encoding?)
    end)
  end

  defp maybe_add(list, key, value, true), do: list ++ [{key, value}]
  defp maybe_add(list, _, _, false), do: list

  defp path({module, function, arguments}, segments)
       when is_atom(module) and is_atom(function) and is_list(arguments),
       do: Enum.join([apply(module, function, arguments) | segments], "/")

  defp path({app, from}, segments) when is_atom(app) and is_binary(from),
    do: Enum.join([Application.app_dir(app), from | segments], "/")

  defp path(from, segments),
    do: Enum.join([from | segments], "/")

  defp subset([h | expected], [h | actual]), do: subset(expected, actual)
  defp subset([], actual), do: actual
  defp subset(_, _), do: []

  defp invalid_path?(list) do
    invalid_path?(list, :binary.compile_pattern(["/", "\\", ":", "\0"]))
  end

  defp invalid_path?([h | _], _) when h in [".", "..", ""], do: true
  defp invalid_path?([h | t], match), do: String.contains?(h, match) or invalid_path?(t)
  defp invalid_path?([], _), do: false

  defp merge_headers(conn, {module, function, args}) do
    merge_headers(conn, apply(module, function, [conn | args]))
  end

  defp merge_headers(conn, headers) do
    merge_resp_headers(conn, headers)
  end
end
