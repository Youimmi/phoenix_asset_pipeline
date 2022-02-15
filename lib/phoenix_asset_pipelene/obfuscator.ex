defmodule PhoenixAssetPipeline.Obfuscator do
  @moduledoc false

  # alias PhoenixAssetPipeline.Storage

  def obfuscate(class_name, count \\ 0) do
    dets_file = file_path() |> String.to_charlist()
    {:ok, table} = :dets.open_file(dets_file, type: :set)

    short = minify(class_name, count)
    key = {"class", short}

    short =
      case :dets.lookup(table, key) do
        [{{_, short}, value}] ->
          if value == class_name,
            do: short,
            else: inc(class_name, count)

        _ ->
          if :dets.insert_new(table, {key, class_name}),
            do: short,
            else: inc(class_name, count)
      end

    :dets.close(dets_file)
    short
  end

  defp file_path do
    file_name =
      Module.split(__MODULE__)
      |> Enum.map_join(".", &Macro.underscore(&1))

    if Code.ensure_loaded?(Mix.Project),
      do: Path.join(Path.dirname(Mix.Project.build_path()), file_name),
      else: Path.expand("_build/" <> file_name)
  end

  defp inc(class_name, count), do: obfuscate(class_name, count + 1)
  defp minify(class_name, 0), do: String.at(class_name, 0)
  defp minify(class_name, count), do: "#{minify(class_name, 0)}#{count}"
end
