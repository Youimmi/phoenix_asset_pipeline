defmodule PhoenixAssetPipeline.Plugs.Assets do
  @moduledoc false

  import Plug.Conn

  require PhoenixAssetPipeline.Utils

  alias Plug.Conn
  alias PhoenixAssetPipeline.{Helpers, Storage, Utils}

  @allowed_methods ~w(GET HEAD)
  @behaviour Plug
  @on_load :preload
  @pattern ~r/((?<name>.*)-)?(?<digest>.{32})\.(?<extname>.+)$/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Conn{method: method, path_info: segments} = conn, _)
      when method in @allowed_methods do
    case Regex.named_captures(@pattern, Enum.map_join(segments, "/", &URI.decode/1)) do
      %{"extname" => extname, "digest" => digest, "name" => name} ->
        encoding =
          get_req_header(conn, "accept-encoding")
          |> fetch_encoding()

        extname = Path.rootname(extname)

        Storage.get({"." <> extname <> encoding, name, digest})
        |> serve_asset(extname, encoding, conn)

      _ ->
        conn
    end
  end

  def call(conn, _), do: conn

  def preload do
    dets_file = Utils.dets_file(Helpers)

    keys =
      Utils.dets_table(dets_file)
      |> :dets.match({{:"$1", :"$2", :"$3"}, :"$4"})

    :dets.close(dets_file)

    for [extname, name, digest, content] <- keys do
      Storage.put({extname, name, digest}, content)
    end

    :ok
  end

  defp brotli_requested?(accept) do
    Plug.Conn.Utils.list(accept)
    |> Enum.any?(&String.contains?(&1, ["br", "*"]))
  end

  defp fetch_encoding([accept]) when is_binary(accept) do
    if brotli_requested?(accept), do: ".br", else: ""
  end

  defp fetch_encoding(_), do: ""

  defp maybe_add_encoding(conn, ".br"), do: put_resp_header(conn, "content-encoding", "br")
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
