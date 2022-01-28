defmodule PhoenixAssetPipeline do
  @moduledoc """
  Asset pipeline for Phoenix app
  """

  import PhoenixAssetPipeline.Utils

  # alias Phoenix.Endpoint.{Cowboy2Adapter, Cowboy2Handler}

  def start(_type, _args) do
    install_esbuild()
    install_sass()
    # upgrade_dispatch()

    children = []

    Supervisor.start_link(children, strategy: :one_for_one)
  end

  # defp config do
  #   [
  #     http: [
  #       port: 4001,
  #       protocol_options: [
  #         {:env, %{dispatch: {:persistent_term, :phoenix_asset_pipeline_dispatch}}}
  #       ]
  #     ],
  #     otp_app: :phoenix_asset_pipeline
  #   ]
  # end

  # Store the routes in persistent_term. This may give a performance improvement
  # when there are a large number of routes
  # See https://ninenines.eu/docs/en/cowboy/2.7/guide/routing
  # defp upgrade_dispatch do
  #   :persistent_term.put(
  #     :phoenix_asset_pipeline_dispatch,
  #     :cowboy_router.compile([{:_, [{:_, Cowboy2Handler, {Endpoint, []}}]}])
  #   )
  # end
end
