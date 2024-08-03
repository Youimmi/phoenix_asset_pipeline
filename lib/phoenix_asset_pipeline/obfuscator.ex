defmodule PhoenixAssetPipeline.Obfuscator do
  @moduledoc false

  @pattern ~r/(?!\d)([-a-z)([[\]\()-,:#'"\.\w]*)/
  @persistent_term {:phoenix_asset_pipeline, :classes}

  def obfuscate(class_name, count \\ 0) when is_binary(class_name) and is_integer(count) do
    classes = :persistent_term.get(@persistent_term, [])
    short_name = minify(class_name, count)

    case Enum.find(classes, fn {s, _} -> s == short_name end) do
      {^short_name, ^class_name} -> short_name
      {^short_name, _} -> obfuscate(class_name, count + 1)
      _ -> store({short_name, class_name}, classes)
    end
  end

  def obfuscate_css(content) when is_list(content), do: to_string(content) |> obfuscate_css()

  def obfuscate_css(content) when is_binary(content) do
    {css, source_map} = split_css_and_source_map(content)
    css = String.replace(css, "\\", "")

    Regex.replace(~r/(\.)(?!phx-)#{@pattern.source}(\s*\{)/iu, css, fn
      _, head, class, tail -> head <> obfuscate(class) <> tail
    end) <> source_map
  end

  def obfuscate_js(content) when is_binary(content) do
    Regex.replace(~r/obfuscate\((?!phx-)#{@pattern.source}\)/iu, content, fn _, class_name, _ ->
      obfuscate(class_name)
    end)
  end

  def valid?(class) when is_binary(class), do: Regex.match?(~r/^#{@pattern.source}$/iu, class)
  def valid?(_), do: false

  defp minify("[" <> _, count), do: minify("u", count)
  defp minify("-" <> _, count), do: minify("u", count)
  defp minify(class_name, 0), do: String.at(class_name, 0)
  defp minify(class_name, count), do: "#{minify(class_name, 0)}#{count}"

  defp split_css_and_source_map(content) do
    case String.split(content, ~r"/\*# sourceMappingURL") do
      [css, source_map] -> {css, "/*# sourceMappingURL" <> source_map}
      [css] -> {css, ""}
    end
  end

  defp store({short_name, _} = class, classes) do
    :persistent_term.put(@persistent_term, [class | classes])
    short_name
  end
end
