ExUnit.start()

defmodule TestHelper do
  defmacro __using__(_) do
    quote do
      alias PhoenixAssetPipeline.Utils

      @application_started? Utils.application_started?()
    end
  end
end
