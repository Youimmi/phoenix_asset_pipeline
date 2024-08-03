defmodule PhoenixAssetPipeline.Plug.Assets do
  @moduledoc false

  import Plug.Conn

  alias Plug.Conn

  @allowed_methods ~w(GET HEAD)
  @behaviour Plug
  @pattern ~r/(?<digest>.{32})\.(?<format>.+)$/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Conn{method: meth, path_info: segments} = conn, _)
      when meth in @allowed_methods do
    case Regex.named_captures(@pattern, Enum.map_join(segments, "/", &URI.decode/1)) do
      %{"digest" => digest, "format" => format} ->
        encoding =
          get_req_header(conn, "accept-encoding")
          |> fetch_encoding()

        extname = "." <> format <> encoding

        :persistent_term.get({:phoenix_asset_pipeline, :assets}, [])
        |> Enum.find_value(fn
          {^extname, ^digest, content} -> content
          _ -> nil
        end)
        |> serve_asset(format, encoding, conn)

      _ ->
        conn
    end
  end

  @impl true
  def call(conn, _), do: conn

  defp brotli_requested?(accept) do
    Conn.Utils.list(accept)
    |> Enum.any?(&String.contains?(&1, ["br", "*"]))
  end

  defp fetch_encoding([accept]) when is_binary(accept) do
    if brotli_requested?(accept), do: ".br", else: ""
  end

  defp fetch_encoding(_), do: ""

  defp maybe_add_encoding(conn, ".br"), do: put_resp_header(conn, "content-encoding", "br")
  defp maybe_add_encoding(conn, ".zstd"), do: put_resp_header(conn, "content-encoding", "zstd")
  defp maybe_add_encoding(conn, _), do: conn

  defp serve_asset(nil, _, _, conn), do: conn

  defp serve_asset(data, extname, encoding, conn) do
    conn
    |> maybe_add_encoding(encoding)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("cache-control", "public, max-age=31536000")
    |> put_resp_header("content-type", MIME.type(extname))
    |> put_resp_header("vary", "Accept-Encoding")
    |> send_resp(200, data)
    |> halt()
  end
end
