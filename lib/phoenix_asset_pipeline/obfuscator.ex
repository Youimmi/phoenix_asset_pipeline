defmodule PhoenixAssetPipeline.Obfuscator do
  @moduledoc """
  Provides obfuscatation for class names.
  """

  alias PhoenixAssetPipeline.Storage

  @pattern ~r/(?!\d)([-a-z)([[\]\()-,:#'"\.\w]*)/

  @doc """
  Obfuscates the class name string by replacing with unique short name.

  ## Examples

      "mt-1"
      "mt-2"

  ## Output

      "m"
      "m1"
  """
  def obfuscate(class_name, count \\ 0) when is_binary(class_name) and is_integer(count) do
    classes = Storage.get(:classes, [])
    short_name = minify(class_name, count)

    case Enum.find(classes, fn {s, _} -> s == short_name end) do
      {^short_name, ^class_name} -> short_name
      {^short_name, _} -> obfuscate(class_name, count + 1)
      _ -> store({short_name, class_name}, classes)
    end
  end

  @doc """
  Obfuscates the CSS content by replacing the class names with the obfuscated class names.
  ""
  ## Examples

      .mt-1 {
        margin-top: 0.25rem
      }

  ## Output

      .m {
        margin-top: 0.25rem
      }
  """
  def obfuscate_css(content) when is_list(content), do: to_string(content) |> obfuscate_css()

  def obfuscate_css(content) when is_binary(content) do
    {css, source_map} = split_css_and_source_map(content)
    css = String.replace(css, "\\", "")

    Regex.replace(~r/(\.)(?!phx-)#{@pattern.source}(\s*\{)/iu, css, fn
      _, head, class, tail -> head <> obfuscate(class) <> tail
    end) <> source_map
  end

  @doc """
  Obfuscates the JavaScript content by replacing the `obfuscate(<class_name>)` string with the obfuscated class name.

  ## Examples

      Document.getElementsByClassName("obfuscate(my-class)")

  ## Output

      Document.getElementsByClassName("m")
  """
  def obfuscate_js(content) when is_binary(content) do
    {js, source_map} = split_js_and_source_map(content)

    Regex.replace(~r/obfuscate\((?!phx-)#{@pattern.source}\)/iu, js, fn
      _, head, class, tail -> head <> obfuscate(class) <> tail
    end) <> source_map
  end

  @doc """
  Checks if the class name is valid css class name.

  Read https://www.w3.org/TR/CSS21/syndata.html#characters
  """
  def valid?(class) when is_binary(class), do: Regex.match?(~r/^#{@pattern.source}$/iu, class)
  def valid?(_), do: false

  defp minify("[" <> _, count), do: minify("u", count)
  defp minify("-" <> _, count), do: minify("u", count)
  defp minify(class_name, 0), do: String.at(class_name, 0)
  defp minify(class_name, count), do: "#{minify(class_name, 0)}#{count}"

  defp split_css_and_source_map(content) do
    case String.split(content, ~r"/\*# sourceMappingURL=") do
      [css, source_map] -> {css, "/*# sourceMappingURL=" <> source_map}
      [css] -> {css, ""}
    end
  end

  defp split_js_and_source_map(content) do
    case String.split(content, ~r"//# sourceMappingURL=") do
      [js, source_map] -> {js, "//# sourceMappingURL=" <> source_map}
      [js] -> {js, ""}
    end
  end

  defp store({short_name, _} = class, classes) do
    Storage.put(:classes, [class | classes])
    short_name
  end
end
