defmodule PhoenixAssetPipeline.HTML.Formatter do
  @moduledoc """
  Formatter plugin for class expressions handled by PhoenixAssetPipeline.
  """
  @behaviour Mix.Tasks.Format

  @class_regex ~r/(?:\[[^\]]*\]|\S)+/
  @raw_text_tags MapSet.new(~w(pre script style textarea title))

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

  defp append_line(state, chunk) do
    case :binary.match(chunk, "\n") do
      :nomatch -> append_same_line(state, chunk)
      _ -> line_state(last_line(chunk))
    end
  end

  defp append_same_line({_indent, false} = state, _), do: state

  defp append_same_line({indent, true}, chunk) do
    chunk_indent = leading_indent(chunk)
    {indent <> chunk_indent, byte_size(chunk_indent) == byte_size(chunk)}
  end

  defp line_state(line) do
    indent = leading_indent(line)
    {indent, byte_size(indent) == byte_size(line)}
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

  defp format_class_attributes(source, opts) do
    format_markup(source, opts, [], {"", true}, nil)
  end

  defp format_markup("", _, acc, _, _) do
    acc
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp format_markup(source, opts, acc, line, raw_tag) when is_binary(raw_tag) do
    case raw_text_close_index(source, raw_tag) do
      nil -> format_markup("", opts, [source | acc], append_line(line, source), raw_tag)
      index -> consume_markup(source, opts, acc, line, index, nil)
    end
  end

  defp format_markup(source, opts, acc, line, nil) do
    case :binary.match(source, ["<", "{"]) do
      :nomatch ->
        format_markup("", opts, [source | acc], append_line(line, source), nil)

      {index, 1} ->
        if :binary.at(source, index) == ?{,
          do: consume_markup_expression(source, opts, acc, line, index),
          else: consume_markup(source, opts, acc, line, index, nil)
    end
  end

  defp consume_markup_expression(source, opts, acc, line, 0) do
    case take_braced(source) do
      {:ok, _, rest} ->
        size = byte_size(source) - byte_size(rest)
        expression = binary_part(source, 0, size)
        format_markup(rest, opts, [expression | acc], append_line(line, expression), nil)

      :error ->
        format_markup("", opts, [source | acc], append_line(line, source), nil)
    end
  end

  defp consume_markup_expression(source, opts, acc, line, index) do
    prefix = binary_part(source, 0, index)
    rest = binary_part(source, index, byte_size(source) - index)
    format_markup(rest, opts, [prefix | acc], append_line(line, prefix), nil)
  end

  defp consume_markup(source, opts, acc, line, 0, raw_tag) do
    case take_markup_tag(source) do
      {:ok, tag, rest} ->
        formatted = format_markup_tag(tag, opts, line)
        raw_tag = raw_text_tag(tag) || raw_tag
        format_markup(rest, opts, [formatted | acc], append_line(line, formatted), raw_tag)

      :error ->
        format_markup("", opts, [source | acc], append_line(line, source), raw_tag)
    end
  end

  defp consume_markup(source, opts, acc, line, index, raw_tag) do
    prefix = binary_part(source, 0, index)
    rest = binary_part(source, index, byte_size(source) - index)
    format_markup(rest, opts, [prefix | acc], append_line(line, prefix), raw_tag)
  end

  defp format_markup_tag("<!--" <> _ = tag, _, _), do: tag
  defp format_markup_tag("<!" <> _ = tag, _, _), do: tag
  defp format_markup_tag("</" <> _ = tag, _, _), do: tag
  defp format_markup_tag("<%" <> _ = tag, _, _), do: tag

  defp format_markup_tag(tag, opts, line) do
    tag
    |> format_tag_class_attributes(opts, [], line)
    |> sort_tag_attributes()
  end

  defp format_tag_class_attributes("", _, acc, _) do
    acc
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp format_tag_class_attributes(source, opts, acc, line) do
    case class_attribute_match(source) do
      :nomatch ->
        [source | acc]
        |> :lists.reverse()
        |> IO.iodata_to_binary()

      {index, length} ->
        format_class_attribute_match(source, opts, acc, line, index, length)
    end
  end

  defp format_class_attribute_match(source, opts, acc, line, index, length) do
    prefix = binary_part(source, 0, index)
    attribute = binary_part(source, index, length)
    offset = index + length
    rest = binary_part(source, offset, byte_size(source) - offset)
    line = append_line(line, prefix)

    format_class_attribute_value(source, opts, acc, line, prefix, attribute, rest, offset)
  end

  defp format_class_attribute_value(source, opts, acc, line, prefix, attribute, rest, offset) do
    case format_attr_value(rest, elem(line, 0)) do
      {:ok, value, rest} ->
        line = line |> append_line(attribute) |> append_line(value)
        format_tag_class_attributes(rest, opts, [value, attribute, prefix | acc], line)

      :error ->
        consume_class_match(source, opts, acc, line, offset)
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
    format_class_attributes(source, opts)
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
         {:ok, chunks} <- split_attr_chunks(attr_lines),
         false <- Enum.any?(chunks, &match?({{:spread, _}, _}, &1)) do
      [open_line | sort_attr_chunks(chunks)] ++ [close_line]
    else
      _ -> tag_lines
    end
  end

  defp sort_tag_attributes(source) do
    case :binary.match(source, "\n") do
      :nomatch -> source
      _ -> source |> String.split("\n", trim: false) |> sort_tag_attribute_lines([]) |> Enum.join("\n")
    end
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

  defp consume_class_match(source, opts, acc, line, length) do
    head = binary_part(source, 0, length)
    tail = binary_part(source, length, byte_size(source) - length)

    format_tag_class_attributes(tail, opts, [head | acc], append_line(line, head))
  end

  defp class_attribute_match(source), do: class_attribute_match(source, 0, 0, nil)

  defp class_attribute_match(<<char, rest::binary>>, index, 0, nil) when char in ~c"\s\t\r\n" do
    case class_attribute_size(rest) do
      nil -> class_attribute_match(rest, index + 1, 0, nil)
      size -> {index + 1, size}
    end
  end

  defp class_attribute_match(<<?{, rest::binary>>, index, depth, nil) do
    class_attribute_match(rest, index + 1, depth + 1, nil)
  end

  defp class_attribute_match(<<?}, rest::binary>>, index, depth, nil) when depth > 0 do
    class_attribute_match(rest, index + 1, depth - 1, nil)
  end

  defp class_attribute_match(<<quote, rest::binary>>, index, depth, nil) when quote in [?", ?'] do
    class_attribute_match(rest, index + 1, depth, quote)
  end

  defp class_attribute_match(<<?\\, _, rest::binary>>, index, depth, quote) when quote in [?", ?'] do
    class_attribute_match(rest, index + 2, depth, quote)
  end

  defp class_attribute_match(<<quote, rest::binary>>, index, depth, quote) do
    class_attribute_match(rest, index + 1, depth, nil)
  end

  defp class_attribute_match(<<_, rest::binary>>, index, depth, quote) do
    class_attribute_match(rest, index + 1, depth, quote)
  end

  defp class_attribute_match("", _, _, _), do: :nomatch

  defp class_attribute_size(source), do: class_attribute_size(source, source, 0)

  defp class_attribute_size(original, <<?=, _::binary>>, size) do
    name = binary_part(original, 0, size)
    if name == "class" or String.ends_with?(name, "_class"), do: size + 1
  end

  defp class_attribute_size(original, <<char, rest::binary>>, size)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"_.:-" do
    class_attribute_size(original, rest, size + 1)
  end

  defp class_attribute_size(_, _, _), do: nil

  defp raw_text_close_index(source, tag) do
    closing = "</" <> tag
    raw_text_close_index(source, closing, byte_size(closing), 0)
  end

  defp raw_text_close_index(source, closing, closing_size, offset) do
    case :binary.match(source, "<", scope: {offset, byte_size(source) - offset}) do
      :nomatch ->
        nil

      {index, 1} ->
        candidate = binary_part(source, index, min(closing_size, byte_size(source) - index))

        if candidate == closing or String.downcase(candidate) == closing do
          index
        else
          raw_text_close_index(source, closing, closing_size, index + 1)
        end
    end
  end

  defp raw_text_tag(<<"<", first, _::binary>> = tag) when first in [?p, ?P, ?s, ?S, ?t, ?T] do
    case Regex.run(~r/^<([A-Za-z][^\s\/>]*)/, tag) do
      [_, name] ->
        name = String.downcase(name)

        if MapSet.member?(@raw_text_tags, name) and not String.ends_with?(String.trim_trailing(tag), "/>"),
          do: name

      _ ->
        nil
    end
  end

  defp raw_text_tag(_), do: nil

  defp take_markup_tag("<!--" <> _ = source), do: take_markup_until(source, "-->")
  defp take_markup_tag("<%" <> _ = source), do: take_markup_until(source, "%>")
  defp take_markup_tag(source), do: take_markup_tag(source, source, 0, 0, nil)

  defp take_markup_tag(original, <<?>, rest::binary>>, index, 0, nil) do
    {:ok, binary_part(original, 0, index + 1), rest}
  end

  defp take_markup_tag(original, <<?{, rest::binary>>, index, depth, nil) do
    take_markup_tag(original, rest, index + 1, depth + 1, nil)
  end

  defp take_markup_tag(original, <<?}, rest::binary>>, index, depth, nil) when depth > 0 do
    take_markup_tag(original, rest, index + 1, depth - 1, nil)
  end

  defp take_markup_tag(original, <<quote, rest::binary>>, index, depth, nil) when quote in [?", ?'] do
    take_markup_tag(original, rest, index + 1, depth, quote)
  end

  defp take_markup_tag(original, <<?\\, _, rest::binary>>, index, depth, quote) when quote in [?", ?'] do
    take_markup_tag(original, rest, index + 2, depth, quote)
  end

  defp take_markup_tag(original, <<quote, rest::binary>>, index, depth, quote) do
    take_markup_tag(original, rest, index + 1, depth, nil)
  end

  defp take_markup_tag(original, <<_, rest::binary>>, index, depth, quote) do
    take_markup_tag(original, rest, index + 1, depth, quote)
  end

  defp take_markup_tag(_, "", _, _, _), do: :error

  defp take_markup_until(source, suffix) do
    case :binary.match(source, suffix) do
      {index, size} ->
        stop = index + size
        {:ok, binary_part(source, 0, stop), binary_part(source, stop, byte_size(source) - stop)}

      :nomatch ->
        :error
    end
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
