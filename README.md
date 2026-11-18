# PhoenixAssetPipeline

Build, optimize, cache, and serve Phoenix assets from one manifest.

[![Hex.pm](https://img.shields.io/hexpm/v/phoenix_asset_pipeline.svg)](https://hex.pm/packages/phoenix_asset_pipeline) [![Documentation](https://img.shields.io/badge/documentation-gray)](https://hexdocs.pm/phoenix_asset_pipeline)

## Requirements

Elixir 1.20+, Erlang/OTP 29+, Rust 1.98+, and Phoenix LiveView 1.2+. The pipeline installs and manages its pinned Bun version.

## Installation

Add the dependency and compilers to `mix.exs`:

```elixir
def deps do
  [{:phoenix_asset_pipeline, "~> 7.0"}]
end

def project do
  [
    compilers:
      [:phoenix_live_view, :phoenix_asset_pipeline_prepare] ++
        Mix.compilers() ++
        [:phoenix_asset_pipeline]
  ]
end
```

Configure the application:

```elixir
config :phoenix, template_engines: [heex: PhoenixAssetPipeline.HTML.Engine]

config :phoenix_asset_pipeline,
  endpoint: MyAppWeb.Endpoint,
  otp_app: :my_app

config :my_app, MyAppWeb.Endpoint,
  adapter: PhoenixAssetPipeline.EndpointAdapter,
  server_adapter: Bandit.PhoenixAdapter
```

Enable a precompiled manifest in `config/prod.exs`:

```elixir
config :phoenix_asset_pipeline, precompiled_manifest: true
```

The default is a cached manifest. Use your application's name for `otp_app`.
The adapter starts the pipeline after endpoint configuration is ready and before
the HTTP server. When `server: false`, start the pipeline after the endpoint in
your application's supervision tree:

```elixir
children = [MyAppWeb.Endpoint]

children =
  if Phoenix.Endpoint.server?(:my_app, MyAppWeb.Endpoint),
    do: children,
    else: children ++ [PhoenixAssetPipeline]
```

Set `server_adapter` to your web server's Phoenix adapter. Bandit remains an
application dependency.

## HTML

Add these imports to the application's HTML helpers:

```elixir
use PhoenixAssetPipeline.HTML.Macros

import Phoenix.Component, except: [embed_templates: 1, embed_templates: 2, sigil_H: 2]
import PhoenixAssetPipeline.Components
import PhoenixAssetPipeline.Helpers
```

The macros replace `~H` and `embed_templates`, so the `Phoenix.Component` versions
must be excluded where both modules are imported.

Render assets:

```heex
<html data-d={asset_digest()}>
  <head>
    {script("app", async: true)}
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

Digested assets are served regardless of `:only`. A path that matches the filter
but is not in the manifest receives `404`, so the filter must not cover paths
handled by the router; without a filter, unknown paths pass through.

## Early hints

After `put_private_phoenix_assigns`, select the JavaScript entry points used by
that response:

```elixir
PhoenixAssetPipeline.Plug.early_hints(conn, scripts: ["app"])
```

Entries are named as for `script/2`; the `.js` extension is optional. Each
selected entry is preloaded as a module with its SRI hash and anonymous CORS,
matching the `type="module"` tag rendered by `script("app")`.
The default `scripts: []` sends only a preconnect hint for the static origin.
Use `:links` for additional configured preload links.

## Classes

Classes are minified consistently in CSS, HEEx, and Elixir. Use `class/1` in Elixir expressions:

```elixir
@container {:div, class: class("h-full")}

class(["button", {"enabled", enabled}])
```

Literal `class` and `*_class` component attributes are handled automatically.
A literal string next to or inside a dynamic value does not compile; wrap the
literals with `class/1`, as in `class={[class("button"), @class]}` or
`class={@active && class("font-bold")}`.

Styles are rendered inline, so a relative `url(...)` in CSS resolves against
the page URL. Reference resources with root-relative or absolute URLs.

Include the library's component utilities in `assets/css/app.css`:

```css
@source "../../deps/phoenix_asset_pipeline/lib/phoenix_asset_pipeline/components.ex";
```

The prepare compiler resolves module attributes and component defaults before Elixir compilation. Function and HEEx expressions use the current manifest at runtime.

Static HEEx minification preserves text in raw-text elements, literal whitespace-preserving
Tailwind classes and inline styles, and SVG `xml:space="preserve"` subtrees. Use
`phx-no-format` on a container when whitespace depends on custom CSS or dynamic values,
for example `:empty` or non-table `display` on table and `<select>` elements, whose
whitespace is otherwise removed; this works in both `~H` and `.heex` templates and is
omitted from the rendered HTML.
The `~H` modifier `noformat` disables static minification for the entire template.
HTML comments are removed unless `:debug_heex_annotations` is enabled for
`:phoenix_live_view`, so LiveView's annotations stay visible in development.

## Formatting

Enable canonical Tailwind classes in `.formatter.exs`:

```elixir
[
  plugins: [Phoenix.LiveView.HTMLFormatter, PhoenixAssetPipeline.HTML.Formatter],
  tailwind: "assets/css/app.css"
]
```

The formatter uses the project's installed `@tailwindcss/node` (4.3 or later),
which is also included by `@tailwindcss/cli`. It processes literal `class` and
`*_class` attributes, including conditional classes, in HEEx files and `~H` sigils.
`mix format --check-formatted` reports required changes without writing files.
The same plugin works when formatting through an editor.

Classes keep the formatter's existing sorting and grouping rules. Unknown classes
and conflicting utilities are not removed. Conditions and helper arguments are
left unchanged. Omit `:tailwind` to only sort and group classes.

## Assets

Default inputs:

- `assets/js/*.{js,ts,jsx,tsx,mjs,cjs}` and LiveView colocated assets
- `assets/css/*.css`
- `assets/img/**/*.{jpg,jpeg,png,webp,avif}`
- `assets/svg/**/*.svg` and `assets/svg/sprites/<name>/*.svg`
- `priv/static/**`; files under `assets/{css,img,js,svg}` there fail the build, since those paths are reserved for built assets

Declare Bun packages in `assets/package.json`. Dependencies are installed when `package.json`, `bun.lock`, or `bunfig.toml` changes; production requires `assets/bun.lock` and uses `--frozen-lockfile`. The managed Bun 1.4.4 archive and executable are verified against pinned SHA-256 checksums before execution. TypeScript entry points are checked before Bun writes build outputs.

Bun downloads use OTP's system CA certificates. Set `:bun_cacertfile` for a custom CA bundle.

JavaScript builds support JavaScript and CSS imports. CSS imported by a JavaScript entry is emitted as `assets/css/<entry>.css`, so it must not share its name with a CSS entry. Imports that emit separate binary files fail the build; keep images and other static files in the asset directories above. Type-only imports, module-resolution directories, Tailwind imports, and external `@source` files participate in cache invalidation and development watching.

Class attribute selectors with `~=` and single-token `=` are renamed together with HTML classes, including inside `@supports selector()`. Feature-query syntax, comments, and unknown selector branches are preserved. Case-insensitive, partial-match, namespaced, and whitespace-containing equality selectors are rejected because their matching behavior cannot be preserved by class obfuscation and class normalization.

Phoenix system classes, HTML attributes, events, and protocol names retain their standard `phx` prefixes. Utility portions of `phx-*-loading:*` classes are still obfuscated.

CSS custom properties declared in stylesheets are obfuscated; names that are only read keep their spelling. List declared names that JavaScript, inline styles, or other external consumers also set or read in `:public_css_variables` so their public contract stays unchanged:

```elixir
config :phoenix_asset_pipeline,
  public_css_variables: ~w(--pixel --viewport-height)
```

Names also used as opaque CSS values (such as indirect property aliases) remain reserved because those references cannot be safely distinguished from unrelated identifiers.

Images are auto-oriented and converted to AVIF, WebP, and PNG with libvips. The source is the highest density: with `image_densities: [1, 2]`, a 40×20 source produces 20×10 and 40×20 variants. `<.picture>` renders responsive sources and a PNG fallback; `width` and `height` reserve space during loading. Set `source_width` to the source's pixel width after orientation so each candidate has its actual width descriptor. `sizes` defaults to the displayed `width` in pixels; override it for images whose CSS width changes with the viewport.

```heex
<.picture src="hero" alt="Welcome" source_width={1280} width="640" height="480" />
<.picture
  src="hero"
  alt="Welcome"
  source_width={1280}
  width="640"
  height="480"
  sizes="(max-width: 640px) 100vw, 640px"
/>
```

Images default to densities `[1, 2]` and a 40,000,000-pixel input limit. Override `image_densities` or `image_max_pixels` when needed.

Brotli, gzip, deflate, and Zstandard variants are kept only when smaller than the original. Already compressed files use `Cache-Control: no-transform`.

Hidden static files are excluded except for files under the root `.well-known` directory. Add `.well-known` to the static plug's `:only` list when serving it.

### Generating image sources

Run `mix phoenix_asset_pipeline.images` to regenerate **all** of `assets/img`
from originals in `artwork`. This explicit task does not start or compile the
application. It prepares every PNG before replacing the directory and preserves
existing exports if scanning or conversion fails. Originals are never modified.

Sizes come from literal `<.picture src="hero" width="640" height="480" />`
attributes or `image_attrs("hero", 480)` calls in `.ex` / `.heex` sources under
`lib`. The helper form takes a displayed height or `{width, height}` bounding box;
it is supplied by the application. Literal map and keyword spreads are supported.
For conditional images, put literal `image_attrs` calls directly in each branch
of a `case`, `cond`, `if` or `unless` inside the picture spread. Unresolved assign
or variable spreads fail before replacing exports; dimensions cannot override
an `image_attrs` result. Explicit attributes take precedence over literal spreads.
Dynamic paths and dimensions must be expressed as separate literal calls. Exports
preserve aspect ratio at **2x** resolution and strip embedded metadata. When a
path appears at several sizes, the largest requested scale is used.

Optional `artwork/images.exs` (or `--config PATH`) returns keyword options:

```elixir
[
  source: "artwork",
  output: "assets/img",
  templates: ["lib/**/*.{ex,heex}"],
  resolve: fn src, false -> [{src <> ".png", src <> ".png"}] end
]
```

The resolver maps a component source to `{export, original}` PNG paths relative
to their respective directories. A non-nil/non-false third `image_attrs` argument
passes `true` to the resolver, so applications can enumerate holiday variants.
Configuration contains mappings, not sizes. Paths cannot traverse directories or
follow symlinks; the output must stay inside the project's `assets` directory and
must not overlap the originals. Originals and templates are also checked against
the staging and backup directories, including filesystem aliases on macOS.
Paths with repeated separators and output names that resolve to the same file
are rejected before replacing exports, including case and Unicode aliases on
filesystems that treat them as equivalent. The generated paths must match the
declared paths exactly, including the spelling of every parent directory. An
empty scan fails instead of erasing exports.
Concurrent runs wait for the project's Mix build lock. The lock is released even
when its owner terminates; a subsequent run discards partial output and restores
an interrupted directory replacement before reading templates or checking original
files. Invalid references and missing originals therefore leave the restored
exports available.

### Generated static files

For files such as `robots.txt` and `sitemap.xml` that need the endpoint's runtime
URL, register generators in the pipeline configuration:

```elixir
config :phoenix_asset_pipeline,
  generated: %{
    "robots.txt" => {MyAppWeb.Crawlers, :robots, []},
    "sitemap.xml" => {MyAppWeb.Crawlers, :sitemap, []}
  }
```

Include both filenames in `static_paths/0`. Each generator returns iodata and
runs during pipeline startup, before the endpoint accepts requests. Generated
files are added to the manifest's `:static_files` section with the same contents,
compression, ETags, and HTTP handling as files from disk. Lookups only read ready
assets; the production manifest is stored in `persistent_term`.

With the startup order above, generators may read runtime application configuration
and call `MyAppWeb.Endpoint.url/0`. Generated content must be shared by all requests
and use the configured endpoint URL.

Development rebuilds generated files when the manifest changes, including when
a generator module is recompiled. Runtime configuration changes require restarting
the application. Generated paths take precedence over files with the same path.
A generator failure prevents startup or leaves the previous development manifest
intact during a rebuild.

### SVG sprites

Each directory `assets/svg/sprites/<name>` builds `<name>.svg`; `app` builds a stack sprite and other names build symbol sprites. SVG files directly in `assets/svg/sprites` fail the build.

Select external SVGs by basename with `svg_sprites`; paths are relative to the project root:

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

Internal SVG IDs are namespaced to prevent collisions. Use `namespace_ids: false` only for sources without internal IDs. Optional `metadata_file` text is escaped and inserted as root metadata; changes invalidate the cache.

Without `:names` or `:files`, sources are selected from literal icon references in
Elixir and HEEx, including `name={"hero-check"}`. Comments and documentation are
excluded. Remote `icon` components count by function name, since aliases are not
resolved, and string bodies of `icon_name` function clauses count as icon names.
List other dynamically constructed icon names, or the icons of another library's
components, explicitly with `:names`.

### Browser headers

Install the canonical policy in the endpoint, before the router, so error pages rendered before a router pipeline runs also carry it. HTML responses must contain exactly this one CSP header; missing, duplicate, or manually modified policies fail closed. Router errors such as unknown paths carry the policy. Exceptions raised by endpoint plugs, such as `Plug.Parsers.ParseError`, are rendered from the connection the endpoint received and carry no policy wherever the plugs are placed.

```elixir
import Phoenix.Controller, only: [put_secure_browser_headers: 2]

plug :put_secure_browser_headers, PhoenixAssetPipeline.Plug.secure_browser_headers()
```

Install the manifest-backed policy and report handling in the endpoint after
`:put_private_phoenix_assigns` and before body parsers and the router:

```elixir
plug PhoenixAssetPipeline.Plug, :put_content_security_policy
plug PhoenixAssetPipeline.Plug, :put_reporting_endpoints
plug PhoenixAssetPipeline.Plug, :csp_report
```

The policy enforces `require-trusted-types-for 'script'`, and LiveView assigns HTML strings without a policy of its own. Create the `default` Trusted Types policy in the application's JavaScript before the LiveSocket connects; without it, browsers that enforce Trusted Types reject DOM patches.

The `/csp-report` endpoint accepts bounded `application/reports+json` batches and never logs report contents. To allow DOMPurify, replace the Trusted Types policy list at compile time:

```elixir
config :phoenix_asset_pipeline, trusted_types: ~w(decodeHTMLEntitiesPolicy default dompurify)
```

Add application-specific directives at compile time instead of modifying the header:

```elixir
config :phoenix_asset_pipeline,
  csp_directives: %{
    "connect-src" => ["'self'", "https://challenges.cloudflare.com"],
    "frame-src" => ["'self'", "https://challenges.cloudflare.com"]
  }
```

Directive names must be lowercase, and values must be lists of ASCII tokens without
whitespace, commas, or semicolons. Empty lists support valueless directives.
The canonical directives and all `script-src`/`style-src` variants are reserved.
The configured policy and manifest-backed header share these directives and retain
the existing header cache.

Responses under `/dev` keep the header they were sent with, in every environment.
Change the skipped path prefixes or skip response statuses at compile time:

```elixir
config :phoenix_asset_pipeline,
  csp_skip_path_prefixes: [["dev"]],
  csp_skip_statuses: [500..599]
```

## Build

Rebuild the manifest before rendering reloaded code in `config/dev.exs`:

```elixir
config :my_app, MyAppWeb.Endpoint,
  reloadable_compilers: [
    :phoenix_live_view,
    :elixir,
    :app,
    :phoenix_asset_pipeline
  ]
```

Capture the manifest for each request after the code reloader in the endpoint, so
a rebuild that finishes during rendering cannot mix two manifests:

```elixir
if code_reloading? do
  plug Phoenix.CodeReloader
  plug PhoenixAssetPipeline.Plug, :put_asset_manifest_snapshot
end
```

Keep it above `:put_content_security_policy`: before-send callbacks run in reverse
order, and the policy must be built while the snapshot is still held.

```sh
# Watch and rebuild in development
mix phx.server

# Build the production manifest
MIX_ENV=prod mix release

# Rebuild the manifest manually
mix phoenix_asset_pipeline.manifest
```

Production uses `PhoenixAssetPipeline.Manifest.Precompiled`; no separate asset build or deploy task is needed.

## License

[MIT](./LICENSE).
