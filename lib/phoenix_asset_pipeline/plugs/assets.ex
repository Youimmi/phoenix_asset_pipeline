defmodule PhoenixAssetPipeline.Plugs.Assets do
  @moduledoc false

  import Plug.Conn

  require PhoenixAssetPipeline.Utils

  alias Plug.Conn
  alias PhoenixAssetPipeline.{Helpers, Storage, Utils}

  @behaviour Plug
  @on_load :preload
  @allowed_methods ~w(GET HEAD)
  @pattern ~r/(?<name>.*)-(?<digest>.{32})\.(?<extname>.+)$/

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Conn{method: method, path_info: segments} = conn, _)
      when method in @allowed_methods do
    case Regex.named_captures(@pattern, Enum.map_join(segments, "/", &URI.decode/1)) do
      %{"extname" => extname, "digest" => digest, "name" => name} ->
        extname = "." <> extname

        Storage.get({extname, name, digest})
        |> serve_asset(conn, extname)

      _ ->
        conn
    end
  end

  def call(conn, _), do: conn

  # defp accept_encoding?(conn, encoding) do
  #   encoding? = &String.contains?(&1, [encoding, "*"])

  #   Enum.any?(get_req_header(conn, "accept-encoding"), fn accept ->
  #     accept |> Plug.Conn.Utils.list() |> Enum.any?(encoding?)
  #   end)
  # end

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

  defp content_type(".js"), do: "application/javascript"
  defp content_type(type), do: MIME.type(type)

  defp encoding("br"), do: "br"
  defp encoding("gz"), do: "gzip"
  defp encoding(_), do: nil

  defp maybe_add_encoding(conn, nil), do: conn
  defp maybe_add_encoding(conn, ce), do: put_resp_header(conn, "content-encoding", ce)

  defp serve_asset(nil, conn, _), do: conn

  defp serve_asset(data, conn, extname) do
    encoding = encoding(Path.extname(extname))

    conn
    |> maybe_add_encoding(encoding)
    |> put_resp_header("accept-ranges", "bytes")
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("content-type", content_type(extname))
    |> send_resp(200, data)
    |> halt()
  end
end
