defmodule PhoenixAssetPipeline do
  @moduledoc """
  Asset pipeline for Phoenix app
  """

  alias __MODULE__.Endpoint
  alias Phoenix.Endpoint.{Cowboy2Adapter, Cowboy2Handler}

  @before_compile PhoenixAssetPipeline.Utils

  def start(_, _) do
    case iex_running?() do
      false ->
        upgrade_dispatch()
        Cowboy2Adapter.child_specs(Endpoint, config())

      _ ->
        []
    end
    |> Supervisor.start_link(strategy: :one_for_one)
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

  defp iex_running? do
    Code.ensure_loaded?(IEx) and IEx.started?()
  end

  # Store the routes in persistent_term. This may give a performance improvement
  # when there are a large number of routes
  # See https://ninenines.eu/docs/en/cowboy/2.9/guide/routing
  defp upgrade_dispatch do
    dispatch = :cowboy_router.compile([{:_, [{:_, Cowboy2Handler, {Endpoint, []}}]}])
    :persistent_term.put(:phoenix_asset_pipeline_dispatch, dispatch)
  end
end
