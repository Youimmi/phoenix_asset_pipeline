defmodule PhoenixAssetPipeline.Formatters.ClassFormatter do
  @moduledoc """
  Formatter plugin for class expressions handled by PhoenixAssetPipeline.
  """
  @behaviour Mix.Tasks.Format

  @class_regex ~r/(?:\[[^\]]*\]|\S)+/

  @impl true
  def features(_), do: [sigils: [:H], extensions: [".heex"]]

  @impl true
  def format(source, opts) do
    if opts[:sigil] == :H and opts[:modifiers] == ~c"noformat" do
      source
    else
      format_source(source, opts)
    end
  end

  defp attr_boundary?(prefix) do
    prefix == "" or :binary.last(prefix) in ~c"\s\t\r\n<"
  end

  defp current_indent(prefix) do
    prefix
    |> String.split("\n")
    |> List.last()
    |> String.replace(~r/\S.*$/, "")
  end

  defp format_attr_expr(expr, indent, opts) do
    trimmed = String.trim(expr)

    case Code.string_to_quoted(trimmed) do
      {:ok, list} when is_list(list) ->
        {:ok, "{" <> format_attr_list(list, indent, opts) <> "}"}

      {:ok, value} when is_binary(value) ->
        {:ok, "{" <> format_attr_string(value, indent, opts) <> "}"}

      _ ->
        :error
    end
  end

  defp format_attr_list(list, indent, opts) do
    items = process_items(list)

    cond do
      match?([_, _ | _], items) ->
        item_indent = indent <> "  "
        inner = Enum.join(items, ",\n" <> item_indent)
        "[\n" <> item_indent <> inner <> "\n" <> indent <> "]"

      items == [] ->
        "[]"

      true ->
        str = "[" <> Enum.join(items, ", ") <> "]"

        str
        |> Code.format_string!(opts)
        |> IO.iodata_to_binary()
        |> String.replace("\n", "\n" <> indent)
    end
  end

  defp format_attr_string(class, indent, opts) do
    case grouped_class_items(class) do
      [item] ->
        item

      items ->
        format_attr_items(items, indent, opts)
    end
  end

  defp format_attr_value(<<?", _::binary>> = source, indent) do
    with {:ok, value, rest} <- take_double_quoted(source) do
      case grouped_class_items(value) do
        [item] -> {:ok, item, rest}
        items -> {:ok, "{" <> format_attr_items(items, indent, []) <> "}", rest}
      end
    end
  end

  defp format_attr_value(<<?{, _::binary>> = source, indent) do
    with {:ok, expr, rest} <- take_braced(source),
         {:ok, value} <- format_attr_expr(expr, indent, []) do
      {:ok, value, rest}
    end
  end

  defp format_attr_value(_, _), do: :error

  defp format_class_args(args, indent, opts, pre, start) do
    case String.trim_leading(args) do
      "[" <> _ ->
        case Code.string_to_quoted("class(" <> args <> ")") do
          {:ok, {:class, _, [list]}} when is_list(list) ->
            format_valid_node(list, start, indent, pre, opts)

          _ ->
            original_class(args, indent, pre, start)
        end

      _ ->
        original_class(args, indent, pre, start)
    end
  end

  defp format_class_attributes(source, opts, acc \\ "")

  defp format_class_attributes("", _, acc), do: acc

  defp format_class_attributes(source, opts, acc) do
    case :binary.match(source, "class=") do
      :nomatch -> acc <> source
      {index, length} -> format_class_attribute_match(source, opts, acc, index, length)
    end
  end

  defp format_class_attribute_match(source, opts, acc, index, length) do
    prefix = binary_part(source, 0, index)

    if attr_boundary?(prefix) do
      offset = index + length
      rest = binary_part(source, offset, byte_size(source) - offset)
      indent = current_indent(acc <> prefix)

      format_class_attribute_value(source, opts, acc, prefix, rest, indent, offset)
    else
      consume_class_match(source, opts, acc, index + byte_size("class"))
    end
  end

  defp format_class_attribute_value(source, opts, acc, prefix, rest, indent, offset) do
    case format_attr_value(rest, indent) do
      {:ok, value, rest} -> format_class_attributes(rest, opts, acc <> prefix <> "class=" <> value)
      :error -> consume_class_match(source, opts, acc, offset)
    end
  end

  defp format_class_macros(source, opts) do
    Regex.replace(~r/(^|\n)([ \t]*)(.*?)\{class\(([\s\S]*?)\)\}/, source, fn
      _, start, indent, pre, args ->
        format_class_args(args, indent, opts, pre, start)
    end)
  end

  defp format_attr_items(items, indent, opts) do
    items
    |> Enum.map_join(", ", & &1)
    |> then(&("[" <> &1 <> "]"))
    |> Code.format_string!(opts)
    |> IO.iodata_to_binary()
    |> String.replace("\n", "\n" <> indent)
  end

  defp format_source(source, opts) do
    source
    |> format_class_macros(opts)
    |> format_class_attributes(opts)
  end

  defp format_valid_node(list, start, indent, pre, opts) do
    items = process_items(list)

    if match?([_, _ | _], items) do
      item_indent = indent <> "  "
      inner = Enum.join(items, ",\n" <> item_indent)
      start <> indent <> pre <> "{class([\n" <> item_indent <> inner <> "\n" <> indent <> "])}"
    else
      inner = Enum.join(items, ", ")
      str = "class([" <> inner <> "])"
      formatted = str |> Code.format_string!(opts) |> IO.iodata_to_binary()
      start <> indent <> pre <> "{" <> String.replace(formatted, "\n", "\n" <> indent) <> "}"
    end
  end

  defp consume_class_match(source, opts, acc, length) do
    head = binary_part(source, 0, length)
    tail = binary_part(source, length, byte_size(source) - length)

    format_class_attributes(tail, opts, acc <> head)
  end

  defp grouped_classes(classes) do
    classes
    |> Enum.reject(&(&1 == ""))
    |> Enum.group_by(&score/1)
    |> Enum.sort()
    |> Enum.map(fn {_, tokens} ->
      tokens |> Enum.sort() |> Enum.join(" ")
    end)
  end

  defp grouped_class_items(class) do
    class
    |> split_classes()
    |> grouped_classes()
    |> Enum.map(&inspect/1)
  end

  defp original_class(args, indent, pre, start) do
    start <> indent <> pre <> "{class(" <> args <> ")}"
  end

  defp process_items(list) do
    {binaries, others} = Enum.split_with(list, &is_binary/1)
    classes = Enum.flat_map(binaries, &split_classes/1)

    grouped =
      classes
      |> grouped_classes()
      |> Enum.map(&inspect/1)

    other_strings = Enum.map(others, &Macro.to_string/1)

    grouped ++ other_strings
  end

  defp scan_braced(<<?{, rest::binary>>, depth, acc, state) do
    scan_braced(rest, depth + 1, acc <> "{", state)
  end

  defp scan_braced(<<?}, rest::binary>>, 1, acc, nil), do: {:ok, acc, rest}

  defp scan_braced(<<?}, rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth - 1, acc <> "}", nil)
  end

  defp scan_braced(<<?", rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth, acc <> <<?">>, :double)
  end

  defp scan_braced(<<?', rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth, acc <> <<?'>>, :single)
  end

  defp scan_braced(<<"\\", char::utf8, rest::binary>>, depth, acc, state) when state in [:double, :single] do
    scan_braced(rest, depth, acc <> "\\" <> <<char::utf8>>, state)
  end

  defp scan_braced(<<?", rest::binary>>, depth, acc, :double) do
    scan_braced(rest, depth, acc <> <<?">>, nil)
  end

  defp scan_braced(<<?', rest::binary>>, depth, acc, :single) do
    scan_braced(rest, depth, acc <> <<?'>>, nil)
  end

  defp scan_braced(<<char::utf8, rest::binary>>, depth, acc, state) do
    scan_braced(rest, depth, acc <> <<char::utf8>>, state)
  end

  defp scan_braced("", _, _, _), do: :error

  defp score(class) do
    prefixes = variant_prefixes(class)

    {section, prefixes} =
      cond do
        "light" in prefixes -> {2, List.delete(prefixes, "light")}
        "dark" in prefixes -> {1, List.delete(prefixes, "dark")}
        true -> {0, prefixes}
      end

    group =
      cond do
        "after" in prefixes ->
          4

        "before" in prefixes ->
          3

        prefixes != [] ->
          1

        true ->
          0
      end

    variant =
      if group == 1, do: Enum.join(prefixes, ":")

    {section, group, variant}
  end

  defp split_class(<<"[", rest::binary>>, current, depth, parts) do
    split_class(rest, current <> "[", depth + 1, parts)
  end

  defp split_class(<<"]", rest::binary>>, current, depth, parts) do
    split_class(rest, current <> "]", max(depth - 1, 0), parts)
  end

  defp split_class(<<":", rest::binary>>, current, 0, parts) do
    split_class(rest, "", 0, [current | parts])
  end

  defp split_class(<<"\\", char::utf8, rest::binary>>, current, depth, parts) do
    split_class(rest, current <> "\\" <> <<char::utf8>>, depth, parts)
  end

  defp split_class(<<char::utf8, rest::binary>>, current, depth, parts) do
    split_class(rest, current <> <<char::utf8>>, depth, parts)
  end

  defp split_class("", current, _, parts) do
    Enum.reverse([current | parts])
  end

  defp split_classes(class) do
    @class_regex
    |> Regex.scan(class)
    |> List.flatten()
  end

  defp take_braced(<<?{, rest::binary>>) do
    scan_braced(rest, 1, "", nil)
  end

  defp take_braced(_), do: :error

  defp take_double_quoted(<<?", rest::binary>>) do
    take_double_quoted(rest, "")
  end

  defp take_double_quoted(_), do: :error

  defp take_double_quoted(<<?", rest::binary>>, acc), do: {:ok, acc, rest}

  defp take_double_quoted(<<"\\", char::utf8, rest::binary>>, acc) do
    take_double_quoted(rest, acc <> "\\" <> <<char::utf8>>)
  end

  defp take_double_quoted(<<char::utf8, rest::binary>>, acc) do
    take_double_quoted(rest, acc <> <<char::utf8>>)
  end

  defp take_double_quoted("", _), do: :error

  defp variant_prefixes(class) do
    case split_class(class, "", 0, []) do
      [_] -> []
      parts -> Enum.drop(parts, -1)
    end
  end
end
