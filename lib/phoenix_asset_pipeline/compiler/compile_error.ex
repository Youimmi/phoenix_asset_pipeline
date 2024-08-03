defmodule PhoenixAssetPipeline.Compiler.CompileError do
  @moduledoc false

  defexception [:message]

  @impl true
  def exception([root_dir, msg]) do
    msg = """
    Can't compile asset

    #{root_dir}

    #{msg}
    """

    %__MODULE__{message: msg}
  end
end
