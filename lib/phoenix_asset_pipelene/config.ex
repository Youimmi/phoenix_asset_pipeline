defmodule PhoenixAssetPipeline.Config do
  @moduledoc false

  @app :phoenix_asset_pipeline

  def obfuscate_class_names? do
    case Application.get_env(@app, :obfuscate_class_names, true) do
      bool when is_boolean(bool) ->
        bool

      _ ->
        raise ArgumentError, """
        Invalid :obfuscate_class_names key value.

        Make sure the value is defined in your config/config.exs file, as boolean:

           config :phoenix_asset_pipeline, obfuscate_class_names: true

        """
    end
  end

  def sri_hash_algoritm do
    case Application.get_env(@app, :subresource_integrity_length, 512) do
      length when is_integer(length) ->
        hash_algoritm(length)

      _ ->
        raise ArgumentError, """
        Invalid :subresource_integrity_length key value.

        Make sure the Subresource Integrity algorithm length is defined in your config/config.exs file, as integer:

           config :phoenix_asset_pipeline, subresource_integrity_length: 256 # 384, 512

        """
    end
  end

  # https://developer.mozilla.org/en-US/docs/Web/Security/Subresource_Integrity
  #
  # Allowed sha256, sha384, and sha512 algorithms
  defp hash_algoritm(256), do: "sha256"
  defp hash_algoritm(384), do: "sha384"
  defp hash_algoritm(512), do: "sha512"
end
