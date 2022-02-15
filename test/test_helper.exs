ExUnit.start()

defmodule TestHelper do
  defmacro __using__(_) do
    quote do
      @application_started? List.keymember?(
                              Application.started_applications(),
                              :phoenix_asset_pipeline,
                              0
                            )
    end
  end
end
