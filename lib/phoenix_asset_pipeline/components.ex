defmodule PhoenixAssetPipeline.Components do
  @moduledoc """
  Phoenix components backed by the asset manifest.
  """
  use Phoenix.Component
  use PhoenixAssetPipeline.HTML.Macros

  import Phoenix.Component, except: [embed_templates: 1, embed_templates: 2, sigil_H: 2]

  @image_density_entries Enum.map(PhoenixAssetPipeline.Config.image_densities(), fn
                           1 -> {"", " 1x"}
                           density -> {"-#{density}x", " #{density}x"}
                         end)

  attr :class, :any, default: nil
  attr :name, :string, required: true
  attr :sprite, :string, default: "icons.svg"

  @doc """
  Renders an SVG `<use>` icon from a manifest-backed sprite.
  """
  def icon(assigns) do
    ~H"""
    <svg
      aria-hidden="true"
      class={[
        class("align-middle inline-block"),
        @class
      ]}
      focusable="false"
    >
      <use href={svg_sprite_href("#{@sprite}##{@name}")} />
    </svg>
    """
  end

  attr :alt, :string, required: true
  attr :class, :any, default: nil
  attr :decoding, :string, default: "async"
  attr :fetchpriority, :string, default: "high"
  attr :height, :string, required: true
  attr :id, :string, required: true
  attr :img_class, :any, default: nil
  attr :loading, :string, default: nil
  attr :phx_update, :string, default: "ignore"
  attr :src, :string, required: true
  attr :width, :string, required: true

  @doc """
  Renders an AVIF/WebP/PNG `<picture>` set from a manifest-backed image base path.
  """
  def picture(assigns) do
    {avif_srcset, png_srcset, webp_srcset} = density_srcsets(assigns.src)
    png_src = assigns.src <> ".png"

    assigns =
      assign(assigns,
        avif_srcset: avif_srcset,
        img_class: [class("col-start-1 row-start-1"), assigns.img_class],
        placeholder_src: image_placeholder(png_src),
        png_src: png_src,
        png_srcset: png_srcset,
        webp_srcset: webp_srcset
      )

    ~H"""
    <span
      class={@class}
      id={@id}
      phx-update={@phx_update}
    >
      <span class={class("inline-grid")}>
        <img
          alt=""
          class={@img_class}
          height={@height}
          loading={@loading}
          src={@placeholder_src}
          width={@width}
        />
        <picture class={class("contents")}>
          {source(srcset: @avif_srcset, type: "image/avif")}
          {source(srcset: @webp_srcset, type: "image/webp")}
          {img(@png_src,
            alt: @alt,
            class: @img_class,
            decoding: @decoding,
            fetchpriority: @fetchpriority,
            height: @height,
            loading: @loading,
            srcset: @png_srcset,
            width: @width
          )}
        </picture>
      </span>
    </span>
    """
  end

  defp density_srcsets(src) do
    :lists.foldr(
      fn {suffix, density}, {avif, png, webp} ->
        {
          [src <> suffix <> ".avif" <> density | avif],
          [src <> suffix <> ".png" <> density | png],
          [src <> suffix <> ".webp" <> density | webp]
        }
      end,
      {[], [], []},
      @image_density_entries
    )
  end
end
