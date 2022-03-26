defmodule PhoenixAssetPipeline do
  @moduledoc """
  Asset pipeline for Phoenix app
  """

  alias __MODULE__.{Endpoint, Utils}
  alias Phoenix.Endpoint.{Cowboy2Adapter, Cowboy2Handler}

  def start(_type, _args) do
    Utils.install_esbuild()
    Utils.install_sass()
    upgrade_dispatch()

    children = Cowboy2Adapter.child_specs(Endpoint, config())
    Supervisor.start_link(children, strategy: :one_for_one)
  end

  defp config do
    [
      http: [
        compress: false,
        port: 4001,
        protocol_options: [
          {:env, %{dispatch: {:persistent_term, :phoenix_asset_pipeline_dispatch}}}
        ]
      ],
      otp_app: :phoenix_asset_pipeline
    ]
  end

  # Store the routes in persistent_term. This may give a performance improvement
  # when there are a large number of routes
  # See https://ninenines.eu/docs/en/cowboy/2.9/guide/routing
  defp upgrade_dispatch do
    dispatch = :cowboy_router.compile([{:_, [{:_, Cowboy2Handler, {Endpoint, []}}]}])
    :persistent_term.put(:phoenix_asset_pipeline_dispatch, dispatch)
  end
end
