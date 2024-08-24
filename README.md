# PhoenixAssetPipeline

Asset pipeline for Phoenix applications

Serve assets and static files from memory

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline/api-reference.html)

## Goal

Achieve 100/100 scores in [Google PageSpeed ​​Insights](https://pagespeed.web.dev) test out of the box

## Features

### Common

- **class**, **script**, **obfuscate**, **style** and **tailwind** HTML helpers
- HTML class names obfuscation
- JSON parser, based on Erlang/OTP 27.0
- Pre-compiled assets and static files with compressed versions (**brotli**, **deflate** and **gzip**)
- Add [Subresource Integrity (SRI)](https://developer.mozilla.org/en-US/docs/Web/Security/Subresource_Integrity) attributes
- Define your custom assets domain

### Dev environment

- Add [Sass](https://sass-lang.com) support
- Add [TypeScript](https://www.typescriptlang.org) support
- Add [Tailwind CSS](https://tailwindcss.com) support with class names obfuscation
- **LiveReload** support

### Prod environment

- Minify CSS and JS
- Minify HTTP response body
- Add [Content Security Policy (CSP)](https://developer.mozilla.org/en-US/docs/Web/HTTP/CSP) directives
- **Releases** support

## Documentation

API documentation is available at https://hexdocs.pm/phoenix_asset_pipeline/api-reference.html

## Installation

Add `phoenix_asset_pipeline` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_asset_pipeline, "~> 1.0"}
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
    # Asset pipeline helpers (class, script, obfuscate, style and tailwind)
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
      ~r"assets/(css|js)/.*(css|scss|sass|js|ts)$", # add this line
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/my_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]
```

### Add plug

Replace **Plug.Static** with **PhoenixAssetPipeline** in your `lib/endpoint.ex`:

```elixir

defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app
  use PhoenixAssetPipeline, only: MyAppWeb.static_paths()

  # plug Plug.Static,
  #   at: "/",
  #   from: :yui,
  #   gzip: false,
  #   only: MyAppWeb.static_paths()
```

Options https://github.com/Youimmi/phoenix_asset_pipeline/blob/main/lib/phoenix_asset_pipeline/plug.ex

## Configure

You can override the default configuration

`config/config.exs`:

```elixir
config :dart_sass, "1.77.8"
config :esbuild, "0.23.1"
config :tailwind, "3.4.10"
```

Add `static_url` to your `config/runtime.exs`:

```elixir
if config_env() == :prod do
  assets_host = System.get_env("ASSETS_HOST") || "assets.example.com"

  config :my_app, MyAppWeb.Endpoint, static_url: [host: assets_host, port: 443, scheme: "https"]
```

Read more https://hexdocs.pm/phoenix/Phoenix.Endpoint.html

## Example

**lib/my_app_web/components/layouts/root.html.heex**
```elixir
<!DOCTYPE html>
<html lang="en" {class("[scrollbar-gutter:stable]")}>
  <head>
    <meta charset="utf-8" />
    <.live_title>
      <%= @page_title %>
    </.live_title>
    <link href={~p"/apple-touch-icon.png"} rel="apple-touch-icon" sizes="180x180" />
    <link href={~p"/favicon-16x16.png"} rel="icon" type="image/png" sizes="16x16" />
    <link href={~p"/favicon-32x32.png"} rel="icon" type="image/png" sizes="32x32" />
    <link href={~p"/site.webmanifest"} rel="manifest" />
    <link color="#c1272d" href={~p"/safari-pinned-tab.svg"} rel="mask-icon" />
    <meta content={@page_description} name="description" />
    <meta content="width=device-width, initial-scale=1" name="viewport" />
    <meta content="yes" name="mobile-web-app-capable" />
    <meta content="Youimmi" name="apple-mobile-web-app-title" />
    <meta content="Youimmi" name="application-name" />
    <meta content={get_csrf_token()} name="csrf-token" />
    <meta content="#fff" name="apple-mobile-web-app-status-bar-style" />
    <meta content="#fff" name="msapplication-TileColor" />
    <meta content="#fff" name="msapplication-navbutton-color" />
    <meta content="#fff" name="theme-color" />
    <%= script("app", async: true, crossorigin: "anonymous") %>
    <%= tailwind("app.sass") %>
  </head>
  <body>
    <%= @inner_content %>
  </body>
</html>
```

See example project [phoenix_asset_pipeline_example](https://github.com/Youimmi/phoenix_asset_pipeline_example)

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
