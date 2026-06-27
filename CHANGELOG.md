# Changelog

## 2.0.0 Unreleased

### Breaking Changes

- Require Elixir 1.18 or later.
- Require Erlang/OTP 28 or later.
- Replace the previous compiler/storage pipeline with a manifest-backed Phoenix asset pipeline.
- Use `PhoenixAssetPipeline.HTML.Engine` for HEEx class extraction and static minification.
- Serve digested assets and static files through `PhoenixAssetPipeline.Plug.Static`.
- Generate production manifests from the compile pipeline.
- Remove `phoenix_asset_pipeline.assets.build` and `phoenix_asset_pipeline.assets.deploy`.
- Remove packaged `priv/scripts/images.js` and `priv/scripts/svg.js`.
- Move dev asset rebuilds from `Phoenix.Endpoint` watchers into `PhoenixAssetPipeline.Watcher`.

### Added

- Asset helpers for scripts, styles, images, responsive sources, SVG sprites, and asset digests.
- Phoenix components for manifest-backed pictures and SVG sprite icons.
- CSP, reporting endpoint, private Phoenix assign, early hints, and manifest snapshot plugs.
- LiveView `on_mount` helper for redirecting stale clients after asset digest changes.
- Rust NIFs for Brotli compression and CSS parsing/minification.

### Changed

- Build app-side JS, Tailwind CSS, SVGO, and SVG sprites in memory through Bun.
- Build optimized PNG, AVIF, and WebP image variants in memory through `vix`.
- Download Bun directly from official GitHub releases, defaulting to `latest`.
- Support proxy environment variables and custom CA bundles for Bun downloads.
- Run `bun install` automatically after app-side package or Bun lockfile changes.
- Generate precompiled production manifests from the compile pipeline.
- Store development manifest cache outside `priv/static`.
