defmodule AssetPipeline.Compilers.Sass do
  @moduledoc false

  alias AssetPipeline.Exceptions.SassCompilerError

  def new(path) do
    compile(path)
  end

  defp compile(path) do
    opts = ~w(--embed-source-map --color --indented --style=compressed)
    %{cmd: cmd, args: args} = DartSass.detect_platform()

    case System.cmd(cmd, args ++ opts ++ ["assets/css/#{path}.sass"], stderr_to_stdout: true) do
      {css, 0} -> css
      {error, _} -> raise SassCompilerError, error
    end
  end
end
