defmodule Mix.Tasks.PhoenixAssetPipeline.Images do
  @shortdoc "Regenerates assets/img from artwork at twice the picture dimensions"
  @moduledoc """
  Replaces the complete generated image directory using originals in `artwork`.

      mix phoenix_asset_pipeline.images
      mix phoenix_asset_pipeline.images --config artwork/images.exs

  The optional config file returns keyword options: `:source`, `:output`,
  `:templates` and `:resolve`. The resolver receives a picture source and a
  boolean indicating variant usage, and returns `{output_png, original_png}`
  paths relative to the output and source directories respectively.

  Dimensions come from literal `image_attrs(source, height_or_box, variant)`
  calls in `.ex` / `.heex` files, or literal `src`, `width`, `height` attributes
  on `<.picture>`. A box is `{width, height}`. Resizing preserves aspect ratio.
  Repeated sources use the largest requested size. Dynamic helper arguments
  must be replaced with literal calls at their declaration sites. Picture spreads
  support literal maps/keywords and inline branches of `image_attrs` calls;
  unresolved assign or variable spreads fail before replacing any exports.

  Originals are untouched. Generation completes in a temporary directory before
  replacing the output. An empty scan or failed conversion preserves the output.
  Original and template paths cannot overlap output, staging or backup directories.
  Repeated path separators and filesystem-equivalent output names are rejected.
  Generated paths must match declared paths, including the spelling of parent directories.
  Concurrent runs wait for the project's Mix build lock, which recovers after interruption.
  Interrupted replacement is restored before reading templates or original files.
  This task loads dependencies without compiling or starting the application.
  """
  use Mix.Task

  alias PhoenixAssetPipeline.Images.Generator

  @impl true
  def run(args) do
    {options, rest} = OptionParser.parse!(args, strict: [config: :string])
    if rest != [], do: Mix.raise("Unexpected arguments: #{Enum.join(rest, " ")}")
    Mix.Task.run("deps.loadpaths")
    config = Keyword.get(options, :config, "artwork/images.exs")

    options =
      if File.regular?(config) do
        {options, _} = Code.eval_file(config)
        options
      else
        if Keyword.has_key?(options, :config), do: Mix.raise("Image config not found: #{config}")
        []
      end

    count = Generator.generate!(options)
    Mix.shell().info("Generated #{count} images in #{Keyword.get(options, :output, "assets/img")} (2x).")
  end
end
