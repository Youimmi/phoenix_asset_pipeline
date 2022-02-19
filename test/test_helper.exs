ExUnit.start()

defmodule TestHelper do
  defmacro __using__(_) do
    quote do
      import TestHelper

      @application_started? started?()
    end
  end

  def started? do
    List.keymember?(Application.started_applications(), :phoenix_asset_pipeline, 0)
  end
end
