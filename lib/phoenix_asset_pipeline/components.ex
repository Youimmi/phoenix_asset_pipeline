defmodule PhoenixAssetPipeline.Components do
  @moduledoc """
  Phoenix components backed by the asset manifest.
  """
  use Phoenix.Component
  use PhoenixAssetPipeline.HTML.Macros

  import Phoenix.Component, except: [embed_templates: 1, embed_templates: 2, sigil_H: 2]

  @image_density_entries Enum.map(PhoenixAssetPipeline.Config.image_densities(), fn
                           1 -> {"", 1}
                           density -> {"-#{density}x", density}
                         end)
  @image_max_density List.last(PhoenixAssetPipeline.Config.image_densities())

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
  attr :img_class, :any, default: nil
  attr :loading, :string, default: nil
  attr :sizes, :string, default: nil
  attr :source_width, :integer, required: true
  attr :src, :string, required: true
  attr :width, :string, required: true

  @doc """
  Renders an AVIF/WebP/PNG `<picture>` set from a manifest-backed image base path.

  `source_width` is the pixel width of the highest-density source after orientation.
  Candidates use their actual pixel widths. `sizes` defaults to `width` in pixels;
  set it explicitly when CSS changes the displayed width across viewports.
  """
  def picture(%{source_width: width} = assigns) when is_integer(width) and width > 0 do
    {avif_srcset, png_srcset, webp_srcset} = width_srcsets(assigns.src, width)
    png_src = assigns.src <> ".png"

    assigns =
      assign(assigns,
        avif_srcset: avif_srcset,
        png_src: png_src,
        png_srcset: png_srcset,
        sizes: assigns.sizes || assigns.width <> "px",
        webp_srcset: webp_srcset
      )

    ~H"""
    <picture class={@class}>
      {source(srcset: @avif_srcset, sizes: @sizes, type: "image/avif")}
      {source(srcset: @webp_srcset, sizes: @sizes, type: "image/webp")}
      {img(@png_src,
        alt: @alt,
        class: @img_class,
        decoding: @decoding,
        fetchpriority: @fetchpriority,
        height: @height,
        loading: @loading,
        sizes: @sizes,
        srcset: @png_srcset,
        width: @width
      )}
    </picture>
    """
  end

  def picture(_), do: raise(ArgumentError, "picture source_width must be a positive integer")

  defp width_srcsets(src, source_width) do
    {avif, png, webp, _} =
      :lists.foldr(
        fn {suffix, density}, {avif, png, webp, previous_width} = srcsets ->
          # Match libvips' scale clamp and reciprocal rounding in reduceh.
          scale = max(density / @image_max_density, 1.0 / source_width)
          width = round(source_width / (1.0 / scale))

          if width == previous_width do
            srcsets
          else
            descriptor = " #{width}w"

            {
              [src <> suffix <> ".avif" <> descriptor | avif],
              [src <> suffix <> ".png" <> descriptor | png],
              [src <> suffix <> ".webp" <> descriptor | webp],
              width
            }
          end
        end,
        {[], [], [], nil},
        @image_density_entries
      )

    {avif, png, webp}
  end
end
