defmodule AssetPipeline.Compilers.Sass do
  def new(path) do
    compile(path)
  end

  defp compile(path) do
    config = DartSass.config_for!(:default)
    args = config[:args] || ["--load-path=assets/css", "--indented", "--style=compressed"]

    opts = [
      cd: config[:cd] || File.cwd!(),
      env: config[:env] || %{},
      stderr_to_stdout: true
    ]

    {path, args} = sass(args ++ ["assets/css/#{path}.sass"])
    {result, 0} = System.cmd(Path.expand(path), args, opts)

    result
  end

  defp sass(args) do
    case DartSass.bin_paths() do
      {sass, nil} -> {sass, args}
      {vm, snapshot} -> {vm, [snapshot] ++ args}
    end
  end
end
