# PhoenixAssetPipeline

Asset pipeline for Phoenix and Phoenix LiveView applications.

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline)
[![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline)

PhoenixAssetPipeline builds static assets into an in-memory manifest, rewrites
asset helpers to digested paths, serves compressed static files, provides a HEEx
engine with class extraction/minification, and exposes a small set of Phoenix
plugs for CSP, early hints, manifest snapshots, and static delivery.

## Requirements

- Elixir 1.18 or later
- Erlang/OTP 28 or later
- Phoenix LiveView
- A Rust toolchain that supports Rust 2024 edition
- Bun, when using the included asset build tasks

## Installation

Add `phoenix_asset_pipeline` to your dependencies:

```elixir
def deps do
  [
    {:phoenix_asset_pipeline, "~> 2.0"}
  ]
end
```

Configure Phoenix and the asset pipeline:

```elixir
config :phoenix,
  template_engines: [heex: PhoenixAssetPipeline.HTML.Engine]

config :phoenix_asset_pipeline,
  endpoint: MyAppWeb.Endpoint,
  otp_app: :my_app
```

In development, cache the manifest and skip CSP on Phoenix debug error pages:

```elixir
config :phoenix_asset_pipeline,
  cache_manifest: true,
  csp_skip_statuses: 500..599
```

In production, load a precompiled manifest module:

```elixir
config :phoenix_asset_pipeline, precompiled_manifest: true
```

## Supervision

Start the manifest store before your endpoint. In development, add the watcher
when the endpoint code reloader is enabled.

```elixir
@assets_watcher if Application.compile_env(:my_app, [MyAppWeb.Endpoint, :code_reloader], false),
                  do: [PhoenixAssetPipeline.Watcher],
                  else: []

children = [
  PhoenixAssetPipeline.Manifest,
  MyAppWeb.Endpoint
] ++ @assets_watcher
```

## Endpoint

Use the endpoint plugs before your router. `Plug.Static` serves manifest-backed
static files and digested assets.

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
  plug Static, only: MyAppWeb.static_paths()
  plug :put_content_security_policy
  plug :put_reporting_endpoints
  plug :csp_report

  plug MyAppWeb.Router
end
```

## Router

Use the base secure browser headers in your browser pipeline. The endpoint CSP
plug merges asset hosts and manifest integrities into this policy before the
response is sent.

```elixir
@secure_browser_headers PhoenixAssetPipeline.Plug.secure_browser_headers(
                          cross_origin_opener_policy: Mix.env() == :prod
                        )

pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :put_secure_browser_headers, @secure_browser_headers
end
```

Early hints can be added to selected pipelines:

```elixir
import PhoenixAssetPipeline.Plug, only: [early_hints: 2]

pipeline :browser do
  plug :early_hints
end
```

## Layouts

Import the macros and helpers in your HTML surface:

```elixir
def html do
  quote do
    use PhoenixAssetPipeline.HTML.Macros

    import PhoenixAssetPipeline.Components
    import PhoenixAssetPipeline.Helpers
  end
end
```

Use the generated asset digest in your root layout if you want stale LiveView
clients to reconnect after deploys:

```heex
<html data-d={asset_digest()}>
  <head>
    {script("app", async: true, crossorigin: true)}
    {style("app")}
  </head>
  <body>
    {@inner_content}
  </body>
</html>
```

Then add the LiveView hook:

```elixir
on_mount {PhoenixAssetPipeline.LiveView, fallback_path: "/"}
```

## Asset Layout

Assets are read from `priv/static` by default:

- `assets/css/*.css` is minified, class-obfuscated, and exposed through `style/2`.
- `assets/js/*.js` is exposed through `script/2`.
- `assets/img/**` and `assets/svg/**` are fingerprinted for `img/2`,
  `source/1`, `picture/1`, and `svg_sprite_href/1`.
- Other files under `priv/static` are served as static files.

Set a different static directory at compile time when needed:

```elixir
config :phoenix_asset_pipeline, static_dir: "priv/static"
```

## Mix Tasks

Add aliases in your application:

```elixir
defp aliases do
  [
    "assets.build": ["phoenix_asset_pipeline.assets.build"],
    "assets.deploy": ["phoenix_asset_pipeline.assets.deploy"]
  ]
end
```

The tasks run configured Bun profiles and then generate the manifest. Override
profile names when your app uses custom Bun aliases:

```elixir
config :phoenix_asset_pipeline,
  bun_profiles: [
    css: :my_app_css,
    images: :my_app_images,
    install: :my_app_install,
    js: :my_app_js,
    svg: :my_app_svg
  ]
```

For releases, generate the production manifest before assembling the release:

```sh
MIX_ENV=prod mix phoenix_asset_pipeline.manifest
```

You can remove bundled static files from the release after the manifest is
generated:

```elixir
steps: [:assemble, &PhoenixAssetPipeline.Release.strip_static/1]
```

## License

PhoenixAssetPipeline is released under the MIT License. See [LICENSE](./LICENSE).
