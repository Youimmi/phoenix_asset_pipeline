# PhoenixAssetPipeline

Asset pipeline for Phoenix and Phoenix LiveView applications.

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline)

PhoenixAssetPipeline builds a manifest from application assets, fingerprints and
compresses files, minifies CSS/HTML classes, serves static assets, and provides
helpers, components, plugs, and a dev watcher.

## Requirements

- Elixir 1.18+
- Erlang/OTP 28+
- Phoenix LiveView
- Rust 2024 toolchain
- An app-side `assets/package.json` when using JS, Tailwind, SVGO, or SVG sprites

Image variants are generated through `vix`/libvips. Bun is used as an in-memory
runtime for JS, Tailwind, SVGO, and SVG sprite builds.

## Installation

```elixir
def deps do
  [
    {:phoenix_asset_pipeline, "~> 2.0"}
  ]
end
```

Add the compiler last:

```elixir
def project do
  [
    compilers: [:phoenix_live_view] ++ Mix.compilers() ++ [:phoenix_asset_pipeline]
  ]
end
```

Configure Phoenix and the asset pipeline:

```elixir
config :phoenix, template_engines: [heex: PhoenixAssetPipeline.HTML.Engine]

config :phoenix_asset_pipeline, endpoint: MyAppWeb.Endpoint
```

Recommended environment config:

```elixir
# dev.exs
config :phoenix_asset_pipeline, cache_manifest: true

# prod.exs
config :phoenix_asset_pipeline, precompiled_manifest: true
```

## Supervision

Start `PhoenixAssetPipeline` before the endpoint. It starts the manifest process
and starts the watcher only when the configured endpoint has `code_reloader:
true`.

```elixir
children = [
  PhoenixAssetPipeline,
  MyAppWeb.Endpoint
]
```

## Endpoint

Use the plugs before your router:

```elixir
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  import PhoenixAssetPipeline.Plug,
    only: [
      csp_report: 2,
      put_content_security_policy: 2,
      put_private_phoenix_assigns: 2,
      put_reporting_endpoints: 2
    ]

  alias PhoenixAssetPipeline.Plug.Static

  if code_reloading? do
    plug PhoenixAssetPipeline.Plug, :put_asset_manifest_snapshot
  end

  plug :put_private_phoenix_assigns

  plug Static,
    content_types: %{"apple-app-site-association" => "application/json"},
    only: MyAppWeb.static_paths()

  plug :put_content_security_policy
  plug :put_reporting_endpoints
  plug :csp_report

  plug MyAppWeb.Router
end
```

Remove `Endpoint` asset watchers. Keep `live_reload` patterns if you want
Phoenix LiveReload to refresh the browser.

Use early hints in router pipelines:

```elixir
defmodule MyAppWeb.Router do
  import PhoenixAssetPipeline.Plug, only: [early_hints: 2]

  pipeline :browser do
    plug :early_hints,
      links: [
        {"/site.webmanifest", rel: "preload", as: "fetch", type: "application/manifest+json", crossorigin: true}
      ]
  end
end
```

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"lib/my_app_web/(controllers|live|components)/.*\.(ex|heex)$"E,
      ~r"lib/my_app_web/router\.ex$"E,
      ~r"priv/gettext/.*\.po$"E
    ]
  ]
```

## HTML

Import helpers and components in your HTML surface:

```elixir
def html do
  quote do
    use PhoenixAssetPipeline.HTML.Macros

    import PhoenixAssetPipeline.Components
    import PhoenixAssetPipeline.Helpers
  end
end
```

Use manifest-backed helpers in layouts:

```heex
<html data-d={asset_digest()}>
  <head>
    {script("app", async: true, crossorigin: true)}
    {style("app")}
  </head>
  <body>{@inner_content}</body>
</html>
```

For stale LiveView clients after deploys:

```elixir
on_mount {PhoenixAssetPipeline.LiveView, fallback_path: "/"}
```

## Assets

The app owns `assets/package.json` and `assets/node_modules`. Add only the npm
packages your app uses:

```json
{
  "dependencies": {
    "@tailwindcss/cli": "^4.3",
    "svg-sprite": ">=3.0.0-rc <4",
    "tailwindcss": "^4.3"
  }
}
```

When JS, CSS, SVGO, or SVG sprites are needed, PhoenixAssetPipeline runs
`bun install` automatically if `assets/node_modules` is missing or
`assets/package.json`, `assets/bun.lock`, or `assets/bun.lockb` changes.
It downloads Bun from official GitHub releases when `_build/bun` is missing.
The default Bun version is `latest`; pin it when reproducible builds need an
exact runtime:

```elixir
config :phoenix_asset_pipeline, bun_version: "1.3.14"
```

The downloader honors `HTTP_PROXY` and `HTTPS_PROXY`. If Erlang cannot find
system CA certificates, point it at a PEM bundle:

```elixir
config :phoenix_asset_pipeline, bun_cacertfile: "/etc/ssl/cert.pem"
```

Add `svgo` when using direct SVG files outside `assets/svg/sprites/**`.
`svg-sprite` runs its own SVGO transform for sprite sources.

Default inputs:

- `assets/js/*.{js,ts,jsx,tsx,mjs,cjs}` -> `script/2`
- `assets/css/*.css` -> Tailwind CSS -> `style/2`
- `assets/img/**/*.{png,webp,avif}` -> image helpers
- `assets/svg/**/*.svg` outside `sprites/` -> optimized SVG image helpers
- `assets/svg/sprites/app/*.svg` -> stack sprite `app.svg`
- `assets/svg/sprites/<name>/*.svg` -> symbol sprite `<name>.svg`
- configured SVG sprite sources -> their configured sprite
- Phoenix LiveView colocated assets from `_build/<env>/phoenix-colocated/<otp_app>`
- `priv/static/**` files -> `PhoenixAssetPipeline.Plug.Static`

PNG, WebP, and AVIF sources are optimized and produce PNG, AVIF, and WebP variants through `vix`.

`cache_manifest: true` is a development startup cache. The manifest is stored
under `_build/<env>/phoenix_asset_pipeline/asset_manifest.term` and refreshed by
the watcher when sources change.

Optional compile-time directories:

```elixir
config :phoenix_asset_pipeline,
  assets_dir: "assets",
  static_dir: "priv/static"
```

External icon packages can stay as application dependencies:

```elixir
{:heroicons,
 app: false,
 compile: false,
 depth: 1,
 github: "tailwindlabs/heroicons",
 sparse: "optimized"}
```

Flag icons can stay as an application dependency too:

```elixir
{:flag_icons,
 app: false,
 compile: false,
 depth: 1,
 github: "lipis/flag-icons",
 sparse: "flags"}
```

Add arbitrary external SVG sources to any sprite with `:svg_sprites`.
Relative paths are resolved from the project root:

```elixir
config :phoenix_asset_pipeline,
  svg_sprites: [
    %{
      file: "icons.svg",
      src: "deps/lucide/icons",
      names: ~w(menu search x),
      prefix: "lucide-"
    },
    %{
      file: "brands.svg",
      src: "deps/simple_icons/icons",
      names: ~w(github x)
    },
    %{
      file: "flags.svg",
      src: "deps/flag_icons/flags/4x3"
    },
    %{
      file: "icons.svg",
      src: "deps/heroicons/optimized/24/outline",
      prefix: "hero-"
    },
    %{
      file: "icons.svg",
      src: "deps/heroicons/optimized/16/solid",
      prefix: "hero-",
      suffix: "-micro"
    }
  ]
```

Configured sprite sources include only SVGs referenced by literal
`svg_sprite_href("sprite.svg#id")` calls and literal `<.icon ...>` component
attributes in `.ex` and `.heex` files under `lib` by default. For `icons.svg`,
literal `icon: "name"` values and `icon_name(...), do: "name"` clauses are also
detected for common dynamic component patterns.

Use `files: [...]` instead of `names: [...]` when source files do not match
`<name>.svg`. Fully dynamic icon names and intentionally bundled icons still
need explicit `names`/`files`.
Set `mode: :stack` for stack sprites; the default is `:symbol`, except
`app.svg`, which defaults to `:stack`.
Use `prefix: "hero-"` with `file: "icons.svg"` to feed the default
`<.icon>` component. Use `suffix` when the source filename and sprite id should
differ, for example `x-mark.svg` -> `hero-x-mark-micro`.

## Build Flow

In development:

```sh
mix phx.server
```

`mix compile` builds the initial manifest, and `PhoenixAssetPipeline.Watcher`
rebuilds it after source changes.

In production:

```sh
MIX_ENV=prod mix release
```

With `precompiled_manifest: true`, `mix compile` generates
`PhoenixAssetPipeline.Manifest.Precompiled`. Separate `assets.build` and
`assets.deploy` tasks are not required.

Optional manual manifest regeneration:

```sh
mix phoenix_asset_pipeline.manifest
```

## License

PhoenixAssetPipeline is released under the MIT License. See [LICENSE](./LICENSE).
