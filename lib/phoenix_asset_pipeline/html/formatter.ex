defmodule PhoenixAssetPipeline.HTML.Formatter do
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
    |> last_line()
    |> leading_indent()
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
    |> format_class_attributes(opts)
    |> sort_tag_attributes()
  end

  defp attr_name(line) do
    trimmed = String.trim_leading(line)

    case Regex.run(~r/^(:?[A-Za-z0-9_.-]+)(?=[\s=]|$)/, trimmed) do
      [_, name] -> name
      _ -> nil
    end
  end

  defp attr_chunk_id(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "{") ->
        {:spread, trimmed}

      name = attr_name(line) ->
        {:attr, name}

      true ->
        nil
    end
  end

  defp attr_sort_key({:attr, ":" <> _ = name}, _) do
    {0, String.downcase(name)}
  end

  defp attr_sort_key({:attr, name}, _) do
    {1, String.downcase(name)}
  end

  defp attr_sort_key({:spread, expr}, _) do
    {2, String.downcase(expr)}
  end

  defp attr_start_line?(line, attr_indent) do
    leading_indent(line) == attr_indent and not is_nil(attr_chunk_id(line))
  end

  defp last_line(binary), do: last_line(binary, byte_size(binary) - 1, byte_size(binary))

  defp last_line(binary, index, size) when index >= 0 do
    if :binary.at(binary, index) == ?\n do
      binary_part(binary, index + 1, size - index - 1)
    else
      last_line(binary, index - 1, size)
    end
  end

  defp last_line(binary, _, _), do: binary

  defp leading_indent(line), do: leading_indent(line, 0, byte_size(line))

  defp leading_indent(line, index, size) when index < size do
    case :binary.at(line, index) do
      char when char in [?\s, ?\t, ?\r] -> leading_indent(line, index + 1, size)
      _ -> binary_part(line, 0, index)
    end
  end

  defp leading_indent(line, size, size), do: line

  defp sort_attr_chunks(chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.sort_by(fn {{name, lines}, index} -> {attr_sort_key(name, lines), index} end)
    |> Enum.flat_map(fn {{_, lines}, _} -> lines end)
  end

  defp sort_tag(tag_lines) do
    {open_line, rest} = List.pop_at(tag_lines, 0)
    {close_line, attr_lines} = List.pop_at(rest, -1)

    with [_ | _] <- attr_lines,
         {:ok, chunks} <- split_attr_chunks(attr_lines) do
      [open_line | sort_attr_chunks(chunks)] ++ [close_line]
    else
      _ -> tag_lines
    end
  end

  defp sort_tag_attributes(source) do
    source
    |> String.split("\n", trim: false)
    |> sort_tag_attribute_lines([])
    |> Enum.join("\n")
  end

  defp sort_tag_attribute_lines([], acc), do: Enum.reverse(acc)

  defp sort_tag_attribute_lines([line | rest], acc) do
    if tag_open_line?(line) and not tag_close_line?(line) do
      case take_tag_lines([line | rest], []) do
        {:ok, tag_lines, rest} ->
          sort_tag_attribute_lines(rest, Enum.reverse(sort_tag(tag_lines), acc))

        :error ->
          sort_tag_attribute_lines(rest, [line | acc])
      end
    else
      sort_tag_attribute_lines(rest, [line | acc])
    end
  end

  defp split_attr_chunks(lines) do
    attr_indent =
      lines
      |> Enum.find(&(String.trim(&1) != ""))
      |> case do
        nil -> nil
        line -> leading_indent(line)
      end

    if is_binary(attr_indent) do
      split_attr_chunks(lines, attr_indent, [], [])
    else
      :error
    end
  end

  defp split_attr_chunks([], _, [], chunks), do: {:ok, Enum.reverse(chunks)}
  defp split_attr_chunks([], _, {name, lines}, chunks), do: {:ok, Enum.reverse([{name, Enum.reverse(lines)} | chunks])}

  defp split_attr_chunks([line | rest], attr_indent, current, chunks) do
    if attr_start_line?(line, attr_indent) do
      id = attr_chunk_id(line)
      chunks = if current == [], do: chunks, else: [finish_attr_chunk(current) | chunks]

      split_attr_chunks(rest, attr_indent, {id, [line]}, chunks)
    else
      case current do
        [] -> :error
        {id, lines} -> split_attr_chunks(rest, attr_indent, {id, [line | lines]}, chunks)
      end
    end
  end

  defp finish_attr_chunk({name, lines}), do: {name, Enum.reverse(lines)}

  defp tag_close_line?(line) do
    line
    |> String.trim()
    |> String.starts_with?(["/>", ">"])
  end

  defp tag_open_line?(line) do
    trimmed = String.trim_leading(line)

    String.starts_with?(trimmed, "<") and
      not String.starts_with?(trimmed, ["</", "<!", "<%", "<!--"]) and
      not String.contains?(trimmed, ">")
  end

  defp take_tag_lines([], _), do: :error

  defp take_tag_lines([line | rest], acc) do
    acc = [line | acc]

    if tag_close_line?(line) do
      {:ok, Enum.reverse(acc), rest}
    else
      take_tag_lines(rest, acc)
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

  defp reverse_iodata_to_binary(acc) do
    acc
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp scan_braced(<<?{, rest::binary>>, depth, acc, state) do
    scan_braced(rest, depth + 1, ["{" | acc], state)
  end

  defp scan_braced(<<?}, rest::binary>>, 1, acc, nil), do: {:ok, reverse_iodata_to_binary(acc), rest}

  defp scan_braced(<<?}, rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth - 1, ["}" | acc], nil)
  end

  defp scan_braced(<<?", rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth, [<<?">> | acc], :double)
  end

  defp scan_braced(<<?', rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth, [<<?'>> | acc], :single)
  end

  defp scan_braced(<<"\\", char::utf8, rest::binary>>, depth, acc, state) when state in [:double, :single] do
    scan_braced(rest, depth, [<<char::utf8>>, "\\" | acc], state)
  end

  defp scan_braced(<<?", rest::binary>>, depth, acc, :double) do
    scan_braced(rest, depth, [<<?">> | acc], nil)
  end

  defp scan_braced(<<?', rest::binary>>, depth, acc, :single) do
    scan_braced(rest, depth, [<<?'>> | acc], nil)
  end

  defp scan_braced(<<char::utf8, rest::binary>>, depth, acc, state) do
    scan_braced(rest, depth, [<<char::utf8>> | acc], state)
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
    split_class(rest, ["[" | current], depth + 1, parts)
  end

  defp split_class(<<"]", rest::binary>>, current, depth, parts) do
    split_class(rest, ["]" | current], max(depth - 1, 0), parts)
  end

  defp split_class(<<":", rest::binary>>, current, 0, parts) do
    split_class(rest, [], 0, [reverse_iodata_to_binary(current) | parts])
  end

  defp split_class(<<"\\", char::utf8, rest::binary>>, current, depth, parts) do
    split_class(rest, [<<char::utf8>>, "\\" | current], depth, parts)
  end

  defp split_class(<<char::utf8, rest::binary>>, current, depth, parts) do
    split_class(rest, [<<char::utf8>> | current], depth, parts)
  end

  defp split_class("", current, _, parts) do
    Enum.reverse([reverse_iodata_to_binary(current) | parts])
  end

  defp split_classes(class) do
    for [class] <- Regex.scan(@class_regex, class), do: class
  end

  defp take_braced(<<?{, rest::binary>>) do
    scan_braced(rest, 1, [], nil)
  end

  defp take_braced(_), do: :error

  defp take_double_quoted(<<?", rest::binary>>) do
    take_double_quoted(rest, [])
  end

  defp take_double_quoted(_), do: :error

  defp take_double_quoted(<<?", rest::binary>>, acc), do: {:ok, reverse_iodata_to_binary(acc), rest}

  defp take_double_quoted(<<"\\", char::utf8, rest::binary>>, acc) do
    take_double_quoted(rest, [<<char::utf8>>, "\\" | acc])
  end

  defp take_double_quoted(<<char::utf8, rest::binary>>, acc) do
    take_double_quoted(rest, [<<char::utf8>> | acc])
  end

  defp take_double_quoted("", _), do: :error

  defp variant_prefixes(class) do
    case split_class(class, [], 0, []) do
      [_] -> []
      parts -> Enum.drop(parts, -1)
    end
  end
end
