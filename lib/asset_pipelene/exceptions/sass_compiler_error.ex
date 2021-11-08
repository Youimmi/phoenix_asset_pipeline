defmodule AssetPipeline.Exceptions.SassCompilerError do
  @moduledoc false

  require Logger

  defexception [:message]

  @impl true
  def exception(msg) do
    Logger.error(msg)

    [msg | _] = String.split(strip_ansi(msg), "\n ")
    %__MODULE__{message: msg}
  end

  defp strip_ansi(content) when is_binary(content) do
    Regex.replace(~r/(\x9B|\x1B\[)[0-?]*[ -\/]*[@-~]/, content, "")
  end
end
