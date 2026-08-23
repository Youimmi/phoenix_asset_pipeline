# PhoenixAssetPipeline

Asset pipeline for Phoenix and Phoenix LiveView. It builds and caches application assets, minifies CSS/HTML classes, generates image and SVG variants, compresses static files, and serves everything from one manifest.

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline)

## Requirements

- Elixir 1.18+
- Erlang/OTP 28+
- Phoenix LiveView
- Rust 2024
- Bun packages declared in the application's `assets/package.json`

## Installation

```elixir
def deps do
  [{:phoenix_asset_pipeline, "~> 2.0"}]
end
```

Prepare module-scope classes before Elixir and build the manifest after the application compiler:

```elixir
def project do
  [
    compilers:
      [:phoenix_live_view, :phoenix_asset_pipeline_prepare] ++
        Mix.compilers() ++
        [:phoenix_asset_pipeline]
  ]
end
```

Configure the endpoint and HEEx engine:

```elixir
manifest_mode =
  case config_env() do
    :dev -> :cached
    :test -> :cached
    :prod -> :precompiled
  end

config :phoenix, template_engines: [heex: PhoenixAssetPipeline.HTML.Engine]
config :phoenix_asset_pipeline,
  bun_version: "1.4.0",
  endpoint: MyAppWeb.Endpoint,
  manifest_mode: manifest_mode,
  otp_app: :my_app
```

Start the pipeline before the endpoint:

```elixir
children = [
  PhoenixAssetPipeline,
  MyAppWeb.Endpoint
]
```

## HTML

Use the macros in the application's HTML surface:

```elixir
def html do
  quote do
    use PhoenixAssetPipeline.HTML.Macros

    import PhoenixAssetPipeline.Components
    import PhoenixAssetPipeline.Helpers
  end
end
```

Render manifest-backed assets:

```heex
<html data-d={asset_digest()}>
  <head>
    {script("app", async: true, crossorigin: true)}
    {style("app")}
  </head>
  <body>{@inner_content}</body>
</html>
```

Serve static files before the router:

```elixir
plug PhoenixAssetPipeline.Plug, :put_private_phoenix_assigns
plug PhoenixAssetPipeline.Plug.Static, only: MyAppWeb.static_paths()

plug MyAppWeb.Router
```

## Classes

Calls from functions and HEEx templates resolve through the current manifest at runtime. Module attributes and component defaults embed stable minified literals prepared before Elixir compilation; production builds allocate them deterministically.

```elixir
@container {:div, class: class("h-full")}

def button(assigns) do
  ~H"""
  <button class={class(["button", {"enabled", @enabled}])}>...</button>
  """
end
```

The prepare and final compilers share the same mapping, so module values, runtime values, manifest entries, and CSS selectors remain consistent without a second Elixir compilation.

## Assets

Default inputs:

- `assets/js/*.{js,ts,jsx,tsx,mjs,cjs}`
- `assets/css/*.css`
- `assets/img/**/*.{jpg,jpeg,png,webp,avif}`
- `assets/svg/**/*.svg`
- `assets/svg/sprites/<name>/*.svg`
- Phoenix LiveView colocated assets
- `priv/static/**`

Bun installs application-side dependencies when the package or lockfile changes. Production builds require
`assets/bun.lock` and install with `--frozen-lockfile`. Image masters are auto-oriented and converted into AVIF,
WebP, and PNG density variants with `vix`/libvips. Bun supplies the low-resolution geometry for each light-gray
placeholder.
Brotli, gzip, deflate, and Zstandard representations are stored only when they are smaller than the original.

The source image is the master for the highest configured density. With the default `image_densities: [1, 2]`, a
40×20 source produces a 20×10 base image and a 40×20 `-2x` image in every output format. The `picture` component
uses an obfuscated image class to display the placeholder as its background. Transparent masters receive a
solid inset silhouette mask, keeping placeholders inside their outer transparent edges.

Common options:

```elixir
config :phoenix_asset_pipeline,
  already_compressed_extensions: ~w(.avif .png .webp),
  assets_dir: "assets",
  image_densities: [1, 2],
  image_max_pixels: 40_000_000,
  image_stylesheet: "app.css",
  static_dir: "priv/static"
```

`already_compressed_extensions`, `assets_dir`, `bun_version`, `image_densities`, `image_max_pixels`,
`image_stylesheet`, `manifest_mode`, `otp_app`, and `static_dir` are
compile-time settings. `bun_version` must be an exact semantic version and `otp_app` must match the application
name from `mix.exs`. Generated placeholder rules are appended only to `image_stylesheet`, which must be rendered on
pages containing images. `manifest_mode` defaults to `:cached`; production builds must set it to `:precompiled`.

Hidden files and directories under `static_dir` are excluded, except for non-hidden files under the root `.well-known`
directory. This directory is included automatically for standard files such as Digital Asset Links and Apple App Site
Association. Add `.well-known` to `:only` when filtering requests in `PhoenixAssetPipeline.Plug.Static`.

Files matching `already_compressed_extensions` are served with `Cache-Control: no-transform` so the HTTP server
does not compress them again dynamically.

### SVG sprites

Use `svg_sprites` to select SVG files outside `assets/svg/sprites`. Paths are relative to the project root, and
`names` selects files by basename without requiring literal references in application code:

```elixir
config :phoenix_asset_pipeline,
  svg_sprites: [
    %{
      file: "flags.svg",
      src: "deps/flag_icons/flags/4x3",
      names: ~w(ca jp us),
      metadata_file: "deps/flag_icons/LICENSE"
    }
  ]
```

Internal SVG IDs are namespaced by default so references from different source files cannot collide. Set
`namespace_ids: false` only when every selected SVG is known to contain no internal IDs. When `metadata_file` is
set, its XML-escaped text is inserted as one root `<metadata>` element after optimization. Changes to the metadata
file invalidate the SVG cache and trigger development rebuilds.

## Build

```sh
# Development
mix phx.server

# Production
MIX_ENV=prod mix release

# Manual manifest rebuild
mix phoenix_asset_pipeline.manifest
```

The development watcher rebuilds changed assets and broadcasts LiveReload events. Production compilation generates `PhoenixAssetPipeline.Manifest.Precompiled`; separate asset build/deploy tasks are not required.

## License

PhoenixAssetPipeline is released under the MIT License. See [LICENSE](./LICENSE).
