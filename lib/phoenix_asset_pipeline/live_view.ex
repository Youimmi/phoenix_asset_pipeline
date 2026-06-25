defmodule PhoenixAssetPipeline.LiveView do
  @moduledoc """
  LiveView helpers for asset digest aware navigation.
  """

  import Phoenix.LiveView, only: [get_connect_params: 1, redirect: 2]

  alias PhoenixAssetPipeline.Manifest

  @default_digest_param "_digest"
  @default_fallback_path "/"
  @default_uri_param "_uri"

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
    opts = opts(opts)
    digest_param = opts.digest_param
    fallback_path = opts.fallback_path
    uri_param = opts.uri_param
    digest = Manifest.get(:digest)

    case get_connect_params(socket) do
      nil -> {:cont, socket}
      %{^digest_param => ^digest} -> {:cont, socket}
      %{^uri_param => uri} -> {:halt, redirect(socket, to: safe_redirect_path(uri, fallback_path))}
      _ -> {:halt, redirect(socket, to: fallback_path)}
    end
  end

  defp opts(opts) do
    opts = List.wrap(opts)

    %{
      digest_param: Keyword.get(opts, :digest_param, @default_digest_param),
      fallback_path: safe_fallback_path(Keyword.get(opts, :fallback_path, @default_fallback_path)),
      uri_param: Keyword.get(opts, :uri_param, @default_uri_param)
    }
  end

  defp safe_fallback_path(path) when is_binary(path) do
    if safe_path?(path), do: path, else: @default_fallback_path
  end

  defp safe_fallback_path(_), do: @default_fallback_path

  defp safe_path?(path) do
    String.starts_with?(path, "/") and not String.starts_with?(path, "//")
  end

  defp safe_redirect_path(path, fallback_path) when is_binary(path) do
    if safe_path?(path), do: path, else: fallback_path
  end

  defp safe_redirect_path(_, fallback_path), do: fallback_path
end
