# PhoenixAssetPipeline

Asset pipeline for Phoenix app

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline/api-reference.html)

## Features

### All environments

- Add **class**, **img**, **script**, **syle** and **tailwind** HTML helpers
- Add [Subresource Integrity (SRI)](https://developer.mozilla.org/en-US/docs/Web/Security/Subresource_Integrity) support
- Add [Content Security Policy (CSP)](https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP) support
- Add JSON parser, based on Erlang/OTP 27.0
- Obfuscate HTML class names
- Pre-compiled assets and static files
- Asset pipeline server with pre-compiled assets and static files

### Dev environment

- Add [Sass](https://sass-lang.com) support
- Add [TypeScript](https://www.typescriptlang.org) support
- Add [Tailwind CSS](https://tailwindcss.com) support with class names obfuscation
- **LiveReload** support

### Prod environment

- Minify CSS and JS
- Minify HTTP response body
- Compress assets and static files (**.brotli**, **.gzip**, **.zstd** versions)
- Define your custom assets domain
- **Releases** support

## Documentation

API documentation is available at https://hexdocs.pm/phoenix_asset_pipeline/api-reference.html

## Installation

Add `phoenix_asset_pipeline` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_asset_pipeline, "~> 0.2.0"}
  ]
end
```

Remove `esbuild` an `tailwind` configuration from `config/config.exs`:

```elixir
# config :esbuild,
#   version: "0.21.5",
#   my_app: [
#     args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
#     cd: Path.expand("../assets", __DIR__),
#     env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
#   ]

# config :tailwind,
#   version: "3.4.4",
#   my_app: [
#     args: ~w(
#       --config=tailwind.config.js
#       --input=css/app.css
#       --output=../priv/static/assets/app.css
#     ),
#     cd: Path.expand("../assets", __DIR__)
#   ]
```

Remove the `esbuild` and `tailwind` watchers from `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  http: [ip: {0, 0, 0, 0}, port: 4000],
  watchers: [
    # esbuild: {Esbuild, :install_and_run, [:my_app, ~w(--sourcemap=inline --watch)]},
    # tailwind: {Tailwind, :install_and_run, [:my_app, ~w(--watch)]}
  ]
```

Remove `"assets.build"`, `"assets.deploy"` and `"assets.setup"` aliases in `mix.exs`:

```elixir
defp aliases do
  [
    # "assets.build": ["tailwind my_app", "esbuild my_app"],
    # "assets.deploy": ["tailwind my_app --minify", "esbuild my_app --minify"],
    # "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
    setup: ["cmd rm -rf _build deps", "deps.get"]
  ]
end
```

#### Opional

Requires **Erlang/OTP 27.0** or later

Update your `config/config.exs`:

```elixir
config :phoenix, :json_library, PhoenixAssetPipeline.Parser.JSON
```

### Add HTML helpers

Add `use PhoenixAssetPipeline.Helpers` inside **quote** block to `defp html_helpers` in your `lib/my_app_web.ex`:

```elixir
defp html_helpers do
  quote do
    # Add asset pipeline macros (class, img, script, style and tailwind)
    use PhoenixAssetPipeline.Helpers # add this line

    # HTML escaping functionality
    import Phoenix.HTML
    # Core UI components and translation
    import MyAppWeb.CoreComponents
    import MyAppWeb.Gettext

    # Shortcut for generating JS commands
    alias Phoenix.LiveView.JS

    # Routes generation with the ~p sigil
    unquote(verified_routes())
  end
end
```

### Add LiveReload

Add the *assets pattern* to your `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"assets/(css|js|img)/.*(css|scss|sass|js|ts|png|svg)$", # add this line
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/my_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]
```

### Add plug

Replace **Plug.Static** with **PhoenixAssetPipeline.Plug** in your `lib/endpoint.ex`:

```elixir
# plug Plug.Static,
#  at: "/",
#  gzip: false
#  from: :my_app,
#  only: MyAppWeb.static_paths()

plug PhoenixAssetPipeline.Plug,
  at: "/",
  from: :my_app,
  only: MyAppWeb.static_paths()
```

## Configure

#### Defaults (out of the box)

You can override the default configuration

`config/config.exs`:

```elixir
config :dart_sass, "1.77.8"
config :esbuild, "0.23.0"
config :tailwind, "3.4.7"

config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"]
```

`config/dev.exs`:

```elixir
config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: 4001]
```

`config/test.exs`:

```elixir
config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4003],
  server: false
```

`config/prod.exs`:

```elixir
config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
  http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4001]
```

`config/runtime.exs`:

```elixir
if System.get_env("PHX_SERVER") do
  config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint, server: true
end
```

## Recommended for production (not included)

> Be careful with the `force_ssl` configuration, it can break your app if you don't have a valid SSL certificate

Add the following to your `config/prod.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  force_ssl: [
    hsts: true,
    preload: true,
    rewrite_on: [:x_forwarded_proto],
    subdomains: true
  ]

config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
  force_ssl: [
    hsts: true,
    preload: true,
    rewrite_on: [:x_forwarded_proto],
    subdomains: true
  ]
```

Update your `config/runtime.exs`:

```elixir
if config_env() == :prod do
  secret_key_base = System.get_env("SECRET_KEY_BASE")
  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  assets_host = System.get_env("ASSETS_HOST") || "assets.example.com"
  assets_port = String.to_integer(System.get_env("ASSETS_PORT") || "4001")

  config :my_app, MyAppWeb.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base: secret_key_base,
    url: [host: host, port: 443, scheme: "https"]

  config :phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint,
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: assets_port
    ],
    url: [host: assets_host, port: 443, scheme: "https"]
```

Read more https://hexdocs.pm/phoenix/Phoenix.Endpoint.html

## Usage

```sh
mix phx.server
```

## Release

All assets and static files will be compiled into elixir macors without the **ptiv/static** folder

```sh
MIX_ENV=prod mix release
_build/prod/rel/my_app/bin/my_app start
```

## Copyright and License

**PhoenixAssetPipeline** is released under [the MIT License](./LICENSE)
