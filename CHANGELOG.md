# Changelog

## 2.0.0

### Breaking changes

- Require Elixir 1.18+ and Erlang/OTP 28+.
- Use `PhoenixAssetPipeline.HTML.Engine` for HEEx templates.
- Add `:phoenix_asset_pipeline_prepare` before Elixir and `:phoenix_asset_pipeline` after `:app`.
- Replace the previous asset tasks and storage with the manifest pipeline.
- Remove `phoenix_asset_pipeline.assets.build`, `phoenix_asset_pipeline.assets.deploy`, and packaged image/SVG scripts.
- Move development rebuilds from endpoint watchers to `PhoenixAssetPipeline.Watcher`.
- Default `:manifest_mode` to `:cached`; production builds must select `:precompiled` and provide an exact
  `:bun_version` plus `assets/bun.lock`.

### Highlights

- Build JS, Tailwind CSS, SVG sprites, optimized images, static files, and the manifest in one pipeline.
- Namespace internal sprite IDs by default and support cache-aware root metadata from `metadata_file`.
- Minify module-scope classes before Elixir compilation and reserve identical mappings during CSS rewriting.
- Resolve function and HEEx class expressions from the current manifest at runtime.
- Rewrite CSS selectors and Tailwind custom properties in native passes without Elixir byte scanning.
- Deduplicate content, cache build outputs, and compress production assets with four bounded workers.
- Serve sparse Brotli, gzip, deflate, and Zstandard representations with range and conditional request support.
- Store dynamic manifests in indexed ETS generations and generate precompiled production manifests.
- Provide manifest-backed HTML helpers, components, CSP helpers, early hints, LiveView integration, and static plugs.
