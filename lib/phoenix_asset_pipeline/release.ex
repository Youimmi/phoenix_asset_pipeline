defmodule PhoenixAssetPipeline.Release do
  @moduledoc """
  Release helpers for applications using a precompiled manifest.
  """

  alias PhoenixAssetPipeline.Config

  @doc """
  Removes the host application's `priv/static` directory from an assembled release.
  """
  def strip_static(release) do
    app = Config.otp_app()
    app_config = Map.fetch!(release.applications, app)
    vsn = Keyword.fetch!(app_config, :vsn)

    release.path
    |> Path.join("lib/#{app}-#{vsn}/priv/static")
    |> File.rm_rf!()

    release
  end
end
