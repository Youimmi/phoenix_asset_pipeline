defmodule PhoenixAssetPipeline.Compiler.Tailwind do
  @moduledoc false

  import PhoenixAssetPipeline.Compiler.Sass, only: [compile: 4]
  import PhoenixAssetPipeline.Utils, only: [cmd: 3]

  @dart_sass_bin_paths DartSass.bin_paths()
  @tailwind_bin_path Tailwind.bin_path()

  def new(path) do
    cwd = File.cwd!()
    path = path(path, Path.extname(path))
    extname = Path.extname(path)
    root_dir = Path.join([cwd, "assets/css"])
    tailwind_path = "#{cwd}/_build/tailwind/#{Path.rootname(path)}.css"

    case compile_input_css(path, extname, root_dir, tailwind_path) do
      {["WARNING", " " <> msg | _], 0} ->
        {:error, [root_dir, msg]}

      {_, 0} ->
        input_path =
          if extname != ".css",
            do: tailwind_path,
            else: Path.join([root_dir, path])

        args = [
          "--config=tailwind.config.js",
          "--input=" <> input_path,
          "--output=" <> tailwind_path
        ]

        args =
          if Mix.env() == :prod,
            do: ["--minify" | args],
            else: args

        opts = [
          cd: Path.join([cwd, "assets"]),
          stderr_to_stdout: true
        ]

        cmd(@tailwind_bin_path, args, opts)

        args =
          [
            "--load-path=#{root_dir}",
            "--stop-on-error",
            tailwind_path
          ]

        args =
          if Mix.env() == :prod,
            do: ["--no-source-map", "--style=compressed" | args],
            else: ["--embed-source-map", "--embed-sources" | args]

        opts = [
          cd: root_dir,
          into: [],
          stderr_to_stdout: true
        ]

        compile(@dart_sass_bin_paths, args, opts, root_dir)

      {msg, _} ->
        {:error, [root_dir, msg]}
    end
  end

  defp compile_input_css(path, extname, root_dir, tailwind_path)
       when extname in ~w(.sass .scss) do
    args =
      [
        "--no-source-map",
        path,
        tailwind_path
      ]

    args =
      if extname == ".sass",
        do: ["--indented" | args],
        else: args

    opts = [
      cd: root_dir,
      into: [],
      stderr_to_stdout: true
    ]

    cmd(@dart_sass_bin_paths, args, opts)
  end

  defp compile_input_css(_, _, _, _), do: {[], 0}

  defp path(path, ""), do: path <> ".css"
  defp path(path, _), do: path
end
