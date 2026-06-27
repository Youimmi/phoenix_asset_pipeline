defmodule PhoenixAssetPipeline.Components do
  @moduledoc """
  Phoenix components backed by the asset manifest.
  """
  use Phoenix.Component
  use PhoenixAssetPipeline.HTML.Macros

  import Phoenix.Component, except: [embed_templates: 1, embed_templates: 2, sigil_H: 2]

  @rtl_flipped_icon_names ~w(
    chevron-left
    chevron-right
  )

  attr(:class, :any, default: nil)
  attr(:name, :string, required: true)
  attr(:prefix, :string, default: "hero-")
  attr(:sprite, :string, default: "icons.svg")

  @doc """
  Renders an SVG `<use>` icon from a manifest-backed sprite.
  """
  def icon(assigns) do
    assigns = assign(assigns, rtl_flip_class: icon_rtl_flip_class(assigns.name))

    ~H"""
    <svg
      aria-hidden="true"
      class={[
        class("align-middle inline-block"),
        @rtl_flip_class,
        @class
      ]}
      focusable="false"
    >
      <use href={svg_sprite_href("#{@sprite}##{@prefix}#{@name}")} />
    </svg>
    """
  end

  attr(:alt, :string, required: true)
  attr(:class, :any, default: nil)
  attr(:decoding, :string, default: "async")
  attr(:fetchpriority, :string, default: "high")
  attr(:height, :string, required: true)
  attr(:id, :string, required: true)
  attr(:img_class, :any, default: nil)
  attr(:loading, :string, default: nil)
  attr(:phx_update, :string, default: "ignore")
  attr(:src, :string, required: true)
  attr(:width, :string, required: true)

  @doc """
  Renders an AVIF/WebP/PNG `<picture>` set from a manifest-backed image base path.
  """
  def picture(assigns) do
    ~H"""
    <picture class={@class} id={@id} phx-update={@phx_update}>
      {source(srcset: ["#{@src}.avif 1x", "#{@src}-2x.avif 2x"], type: "image/avif")}
      {source(srcset: ["#{@src}.webp 1x", "#{@src}-2x.webp 2x"], type: "image/webp")}
      {img("#{@src}.png",
        alt: @alt,
        class: @img_class,
        decoding: @decoding,
        fetchpriority: @fetchpriority,
        height: @height,
        loading: @loading,
        srcset: ["#{@src}-2x.png 2x"],
        width: @width
      )}
    </picture>
    """
  end

  defp icon_rtl_flip_class(name) when name in @rtl_flipped_icon_names do
    class("[[dir=rtl]_&]:scale-x-[-1]")
  end

  defp icon_rtl_flip_class(_), do: nil
end
