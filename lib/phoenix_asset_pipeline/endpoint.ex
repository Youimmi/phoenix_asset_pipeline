defmodule PhoenixAssetPipeline.Endpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :phoenix_asset_pipeline

  alias PhoenixAssetPipeline.Plug.Assets

  @config [
    adapter: Bandit.PhoenixAdapter,
    url: [host: "localhost"]
  ]

  @dev_config [
    http: [ip: {0, 0, 0, 0}, port: 4001]
  ]

  @test_config [
    http: [ip: {127, 0, 0, 1}, port: 4003],
    server: false
  ]

  @prod_config [
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}, port: 4001]
  ]

  plug Assets
  plug :not_found

  def runtime_config(env) do
    Keyword.merge(
      config_for(env),
      Application.get_env(:phoenix_asset_pipeline, PhoenixAssetPipeline.Endpoint, [])
    )
  end

  defp config_for(:dev), do: Keyword.merge(@config, @dev_config)
  defp config_for(:test), do: Keyword.merge(@config, @test_config)

  defp config_for(:prod) do
    config = Keyword.merge(@config, @prod_config)

    if System.get_env("PHX_SERVER"),
      do: Keyword.put(config, :server, true),
      else: config
  end

  defp not_found(conn, _) do
    send_resp(conn, 404, "Not found")
    |> halt()
  end
end
