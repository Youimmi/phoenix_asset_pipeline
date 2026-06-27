[
  import_deps: [:plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib}/**/*.{ex,exs}"],
  plugins: [Phoenix.LiveView.HTMLFormatter, PhoenixAssetPipeline.HTML.Formatter, Styler]
]
