defmodule PhoenixAssetPipeline.Compiler.Sass do
  @moduledoc false

  import PhoenixAssetPipeline.Obfuscator, only: [obfuscate_css: 1]
  import PhoenixAssetPipeline.Utils, only: [cmd: 3, integrity: 1]

  @bin_paths DartSass.bin_paths()

  def compile(bin_paths, args, opts, root_dir) do
    case cmd(bin_paths, args, opts) do
      {["WARNING", " " <> msg | _], 0} ->
        {:error, [root_dir, msg]}

      {css, 0} ->
        css = obfuscate_css(css)
        {css, integrity(css)}

      {msg, _} ->
        {:error, [root_dir, msg]}
    end
  end

  def new(path) do
    path = path(path, Path.extname(path))
    root_dir = Path.join([File.cwd!(), "assets/css"])

    args =
      [
        "--load-path=#{root_dir}",
        "--stop-on-error",
        path
      ]

    args =
      if Mix.env() == :prod,
        do: ["--no-source-map", "--style=compressed" | args],
        else: ["--embed-source-map", "--embed-sources" | args]

    args =
      if Path.extname(path) == ".sass",
        do: ["--indented" | args],
        else: args

    opts = [
      cd: root_dir,
      into: [],
      stderr_to_stdout: true
    ]

    compile(@bin_paths, args, opts, root_dir)
  end

  defp path(path, ""), do: path <> ".css"
  defp path(path, _), do: path
end
