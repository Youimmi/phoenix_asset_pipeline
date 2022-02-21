defmodule PhoenixAssetPipeline.Obfuscator do
  @moduledoc false

  alias PhoenixAssetPipeline.Utils

  def obfuscate(class_name, count \\ 0) when is_binary(class_name) and is_integer(count) do
    dets_file = Utils.dets_file(__MODULE__) |> String.to_charlist()
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

  def obfuscate_css(css) when is_binary(css) do
    # Matches a valid CSS class name. Read more https://rgxdb.com/r/3SSUL9QL
    Regex.replace(~r{\.(-?[_a-zA-Z]+[_a-zA-Z0-9-]*)}, css, fn _, class_name, _ ->
      "." <> obfuscate(class_name)
    end)
  end

  defp inc(class_name, count), do: obfuscate(class_name, count + 1)
  defp minify(class_name, 0), do: String.at(class_name, 0)
  defp minify(class_name, count), do: "#{minify(class_name, 0)}#{count}"
end
