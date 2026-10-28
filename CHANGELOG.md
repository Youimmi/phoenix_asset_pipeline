# Changelog

## 5.0.1

- Preserve CSS comments while rewriting selectors and custom properties
- Parse Elixir and HEEx for SVG sprite references, including braced literal attributes, without treating comments or documentation as dependencies
- Preserve whitespace-sensitive HEEx text and honor `phx-no-format` in inline and file templates
- Share short-class allocation and prefix normalization, avoiding repeated suffix scans for module-scope classes
- Update native dependencies, including fearless_simd 1.2.0, and require mbrotli 0.5.17 or later
- Ignore byte ranges when `If-Range` cannot match a strong ETag, including digested assets without ETags
- Accept `If-None-Match: *` only as a standalone value, preserving weak ETag and list matching
- Reject ETag matches followed by invalid suffixes or missing list separators
- Share range validation without scanning `If-Range` on requests without a byte range

## 5.0.0

- Replace Brotli with compression-only mbrotli and reuse bounded encoder workspaces per dirty scheduler thread
- Preload only explicitly selected JavaScript entries in early hints, include their integrity hashes, and cache each selection independently
- Require Elixir 1.20, Erlang/OTP 29, and Phoenix LiveView 1.2; update the Rustler crate to 0.39
- Require the oriented source pixel width in `<.picture source_width={...}>`, emit accurate width descriptors for every image format, and support responsive `sizes`
- Keep the highest-density candidate when generated widths coincide, and match libvips rounding for nonuniform density configurations
- Update the managed Bun runtime to 1.4.3, verify archives and executables with pinned SHA-256 checksums, and type-check TypeScript builds
- Use OTP's system CA certificates for Bun downloads, with an explicit custom CA bundle option
- Allow GitHub release redirects with response headers up to 64 KiB when installing Bun
- Replace MD5 content identities with SHA-256 and reject symlink traversal or duplicate asset output paths
- Require one canonical CSP header with compile-time application-specific directives, accept bounded Reporting API batches and parameterized CSP report content types without logging report contents, and remove manifest race fallbacks
- Track JavaScript dependencies, package metadata, and inherited compiler configs without rebuilding on unrelated file events
- Scope Bun caches by asset root and track type-only imports, new module-resolution candidates, Tailwind source/import dependencies, and source-directory retargeting; reject unsupported binary bundle outputs
- Confirm stable dependency snapshots before caching Bun output, retry only changed build groups, and fail after three unstable attempts
- Keep `id` attribute values quoted, preserve HTML attribute backslashes, quoted HEEx attribute values, HTML5 entities, class-expression comments, and SVG self-closing tags, safely reduce redundant whitespace, and sort multiline attributes without altering their contents
- Preserve class attribute selectors, grouped style-query custom-property references, URL tokens, and unknown or invalid feature-test guards during CSS rewriting; match only exact Tailwind legacy conditions and reject unsupported class-selector matching modes
- Serve all manifest image extensions and use linear short-class allocation
- Validate complete cached static assets and use canonical CORS origins for endpoints with path prefixes
- Preserve raw HEEx text across dynamic expressions and rename CSS custom properties consistently in transitions, including Unicode names
- Remove all application dependency cycles
- Reduce NIF allocation overhead for Brotli and CSS output
- Isolate Bun temporary directories between processes, bound parallel compression, and remove redundant SVG source fields and legacy descriptor records
- Let configured SVG sprite modes override directory naming, and omit a shared root viewBox in stacked sprites
- Keep nested and overlapping compiler-disable scopes balanced
- Update dependencies, including Plug Crypto 2.2.1 to fix CVE-2026-105963

## 4.2.0

- Canonicalize Tailwind classes through the HEEx formatter with an optional stylesheet setting
- Load the generated manifest immediately so the first production startup succeeds
- Reduce memory use when compiling production manifests

## 4.1.0

- Add generated files to the shared manifest

## 4.0.1

- Rebuild Bun assets when imported dependencies outside configured asset sources change
- Allow LiveView to update `<.picture>` and remove its required `id`
- Update Vix to 0.42.0 and bundled libvips to 8.18.7

## 4.0.0

- Remove image placeholders from `<.picture>`
- Strip metadata from generated images, including PNG resolution (`pHYs`)
- Preserve SVG transforms and their precision during optimization of standalone files and sprites
- Update Brotli to 9.0 and Bun to 1.4.2
- Replace `:manifest_mode` with `:precompiled_manifest` (default `false`); enable it for production
- Fix development reloads, HTTP ranges and conditional requests, HEEx `noformat`, and class formatting
- Reduce Bun hashing, module-class scans, numeric-entity parsing costs, and temporary allocations

## 3.0.2

- Render image placeholders at 80% opacity

## 3.0.1

- Preserve updated adapter state after sending 103 Early Hints

## 3.0.0

- Extract, obfuscate, and format component attributes ending in `_class` like standard `class` attributes
- Require Rust 1.98 and use buffered integer formatting for CSS marker generation
- Compress high-density AVIF variants more aggressively while preserving 1x quality
- Serve monotone light-gray image placeholders as content-addressed PNG assets with inset masks that preserve transparency
- Remove generated placeholder CSS and `data:` from the default image CSP

## 2.1.1

- Generate monotone light-gray image placeholders constrained to the solid inset silhouette of transparent masters
- Remove the image placeholder cleanup runtime from generated JavaScript bundles

## 2.1.0

- Upgrade the managed Bun runtime to 1.4.0.
- Accept JPEG image masters, auto-orient them, enforce a configurable pixel limit, and generate configurable density
  variants.
- Generate obfuscated Bun ThumbHash placeholders, render them through a configured stylesheet and the
  manifest-backed `picture` component, and remove their backgrounds after images load.

## 2.0.2

- Include non-hidden files under the root `.well-known` static directory automatically.

## 2.0.1

- Add Hex package links and README badges for the changelog and documentation.

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
