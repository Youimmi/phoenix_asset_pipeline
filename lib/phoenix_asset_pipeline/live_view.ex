defmodule PhoenixAssetPipeline.LiveView do
  @moduledoc """
  LiveView helpers for asset digest aware navigation.
  """

  import Phoenix.LiveView, only: [get_connect_params: 1, redirect: 2]

  alias PhoenixAssetPipeline.Manifest

  @default_fallback_path "/"

  @doc """
  Redirects connected LiveView clients when their asset digest is stale.

  Add it with:

      on_mount {PhoenixAssetPipeline.LiveView, fallback_path: "/"}

  The hook compares the connect param named by `:digest_param` (default:
  `"_digest"`) with the current manifest digest. When stale, it redirects to
  the safe connect param named by `:uri_param` (default: `"_uri"`) or to the
  configured `:fallback_path`.
  """
  def on_mount(opts, _, _, socket) do
    opts = List.wrap(opts)
    digest_param = Keyword.get(opts, :digest_param, "_digest")
    uri_param = Keyword.get(opts, :uri_param, "_uri")
    digest = Manifest.get(:digest)

    case get_connect_params(socket) do
      nil -> {:cont, socket}
      %{^digest_param => ^digest} -> {:cont, socket}
      params -> {:halt, redirect(socket, to: safe_path(params[uri_param], fallback_path(opts)))}
    end
  end

  defp fallback_path(opts) do
    opts
    |> Keyword.get(:fallback_path)
    |> safe_path(@default_fallback_path)
  end

  # Mirrors the paths `Phoenix.LiveView.redirect/2` accepts, so an unsafe one falls back instead of raising.
  defp safe_path("/" <> rest = path, fallback) do
    if not match?("/" <> _, rest) and safe_path_bytes?(rest) and not String.contains?(path, "/%09"),
      do: path,
      else: fallback
  end

  defp safe_path(_, fallback), do: fallback

  defp safe_path_bytes?(<<byte, _::binary>>) when byte <= 0x20 or byte in [?\\, 0x7F], do: false
  defp safe_path_bytes?(<<_, rest::binary>>), do: safe_path_bytes?(rest)
  defp safe_path_bytes?(<<>>), do: true
end
