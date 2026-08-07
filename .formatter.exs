[
  import_deps: [:phoenix, :plug],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  plugins: [Phoenix.LiveView.HTMLFormatter, PhoenixAssetPipeline.HTML.Formatter, Styler]
]
