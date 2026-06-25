# Changelog

## 2.0.0 (2026-06-25)

### Breaking Changes

- Require Elixir 1.18 or later.
- Require Erlang/OTP 28 or later.
- Replace the previous compiler/storage pipeline with a manifest-backed Phoenix asset pipeline.
- Use `PhoenixAssetPipeline.HTML.Engine` for HEEx class extraction and static minification.
- Serve digested assets and static files through `PhoenixAssetPipeline.Plug.Static`.
- Generate production manifests with `mix phoenix_asset_pipeline.manifest`.

### Added

- Asset helpers for scripts, styles, images, responsive sources, SVG sprites, and asset digests.
- Phoenix components for manifest-backed pictures and SVG sprite icons.
- CSP, reporting endpoint, private Phoenix assign, early hints, and manifest snapshot plugs.
- LiveView `on_mount` helper for redirecting stale clients after asset digest changes.
- Bun-backed `phoenix_asset_pipeline.assets.build` and `phoenix_asset_pipeline.assets.deploy` tasks.
- Rust NIFs for Brotli compression and CSS parsing/minification.
- Release helper for stripping static files after a precompiled manifest is generated.
