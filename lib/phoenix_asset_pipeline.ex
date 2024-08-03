defmodule PhoenixAssetPipeline do
  @moduledoc """
  Phoenix asset pipeline application
  """
  use Application

  alias __MODULE__.Endpoint

  @compile_env Mix.env()

  @impl true
  def start(_, _) do
    Application.put_env(:phoenix_asset_pipeline, Endpoint, Endpoint.runtime_config(env()))

    Supervisor.start_link([Endpoint],
      name: PhoenixAssetPipeline.Supervisor,
      strategy: :one_for_one
    )
  end

  @impl true
  def config_change(changed, _, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end

  def env do
    if function_exported?(Mix, :env, 0),
      do: Mix.env(),
      else: @compile_env
  end
end
