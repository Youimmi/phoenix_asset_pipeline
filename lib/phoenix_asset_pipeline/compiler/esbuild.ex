defmodule PhoenixAssetPipeline.Compiler.Esbuild do
  @moduledoc false

  import PhoenixAssetPipeline.Obfuscator, only: [obfuscate_js: 1]
  import PhoenixAssetPipeline.Utils, only: [cmd: 3, integrity: 1]

  alias PhoenixAssetPipeline.Compiler.CompileError

  @bin_path Esbuild.bin_path()

  def new(path) do
    cwd = File.cwd!()
    path = path(path, Path.extname(path))
    root_dir = Path.join([cwd, "assets/js"])

    args = ["--bundle"]

    args =
      if Mix.env() == :prod,
        do: ["--minify", "--tree-shaking=true" | args],
        else: ["--sourcemap=inline" | args]

    opts = [
      cd: root_dir,
      env: %{"NODE_PATH" => Path.expand(Path.join(cwd, "deps"), __DIR__)},
      stderr_to_stdout: true
    ]

    case cmd([@bin_path, path], args, opts) do
      {js, 0} ->
        js = obfuscate_js(js)
        {js, integrity(js)}

      {msg, _} ->
        raise CompileError, [root_dir, msg]
    end
  end

  defp path(path, ""), do: path <> ".js"
  defp path(path, _), do: path
end
