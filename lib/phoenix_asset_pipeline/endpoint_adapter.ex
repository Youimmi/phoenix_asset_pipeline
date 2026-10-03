defmodule PhoenixAssetPipeline.EndpointAdapter do
  @moduledoc """
  Starts the asset pipeline after endpoint configuration and before the HTTP server.

  Set the endpoint's `:adapter` to this module and `:server_adapter` to the
  underlying Phoenix adapter, such as `Bandit.PhoenixAdapter`.
  """

  @doc false
  def child_specs(endpoint, config) do
    [PhoenixAssetPipeline | Keyword.fetch!(config, :server_adapter).child_specs(endpoint, config)]
  end

  @doc false
  def server_info(endpoint, scheme) do
    endpoint.config(:server_adapter).server_info(endpoint, scheme)
  end
end
