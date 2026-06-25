defmodule PhoenixAssetPipeline.ComponentsTest do
  use ExUnit.Case

  import Phoenix.LiveViewTest

  alias PhoenixAssetPipeline.Components
  alias PhoenixAssetPipeline.Helpers
  alias PhoenixAssetPipeline.Manifest

  defmodule Endpoint do
    @moduledoc false

    def static_path(path), do: path
    def static_url, do: "http://localhost:4000"
  end

  setup do
    previous_endpoint = Application.get_env(:phoenix_asset_pipeline, :endpoint)

    Application.put_env(:phoenix_asset_pipeline, :endpoint, Endpoint)
    on_exit(fn -> Application.put_env(:phoenix_asset_pipeline, :endpoint, previous_endpoint) end)

    start_supervised!(Manifest)

    :ok =
      Manifest.put(%{
        digest: "asset-digest",
        image_sources: %{
          "avatar.avif" => %{digest: "avatar-avif-digest", path: "/avatar-avif-digest.avif"},
          "avatar-2x.avif" => %{digest: "avatar-2x-avif-digest", path: "/avatar-2x-avif-digest.avif"},
          "avatar.webp" => %{digest: "avatar-webp-digest", path: "/avatar-webp-digest.webp"},
          "avatar-2x.webp" => %{digest: "avatar-2x-webp-digest", path: "/avatar-2x-webp-digest.webp"},
          "avatar.png" => %{digest: "avatar-png-digest", path: "/avatar-png-digest.png"},
          "avatar-2x.png" => %{digest: "avatar-2x-png-digest", path: "/avatar-2x-png-digest.png"},
          "icons.svg" => %{digest: "icons-digest", path: "/icons-digest.svg"}
        }
      })

    :ok
  end

  test "returns current asset digest" do
    assert Helpers.asset_digest() == "asset-digest"
  end

  test "renders picture sources through the asset manifest" do
    html =
      render_component(&Components.picture/1,
        alt: "Avatar",
        height: "20",
        id: "avatar",
        src: "avatar",
        width: "20"
      )

    assert html =~ ~s(<picture)
    assert html =~ ~s(id="avatar")
    assert html =~ "/avatar-avif-digest.avif 1x"
    assert html =~ "/avatar-2x-webp-digest.webp 2x"
    assert html =~ ~s(src="/avatar-png-digest.png")
    assert html =~ ~s(srcset="/avatar-2x-png-digest.png 2x")
  end

  test "renders hero icon through the sprite manifest" do
    html = render_component(&Components.icon/1, name: "x-mark", class: "size-4")

    assert html =~ ~s(<svg)
    assert html =~ ~s(href="/icons-digest.svg#hero-x-mark")
    assert html =~ "size-4"
  end
end
