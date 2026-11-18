defmodule PhoenixAssetPipeline.HTML.Formatter do
  @moduledoc """
  Formatter plugin for class expressions handled by PhoenixAssetPipeline.

  Set `tailwind: "assets/css/app.css"` in `.formatter.exs` to canonicalize classes
  using the project's installed Tailwind CSS. Requires `@tailwindcss/node` 4.3+.
  """
  @behaviour Mix.Tasks.Format

  alias Phoenix.LiveView.HTMLFormatter
  alias PhoenixAssetPipeline.HTML.Entities
  alias PhoenixAssetPipeline.HTML.Minifier
  alias PhoenixAssetPipeline.HTML.RawText
  alias PhoenixAssetPipeline.HTML.Tailwind

  @class_regex ~r/(?:\[[^\]]*\]|[^ \t\n\f\r])+/

  @impl true
  def features(_), do: [sigils: [:H], extensions: [".heex"]]

  @impl true
  def format(source, opts) do
    if (opts[:sigil] == :H and opts[:modifiers] == ~c"noformat") or not String.valid?(source) do
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

  defp attr_chunk_id(line) do
    trimmed = String.trim_leading(line)

    cond do
      String.starts_with?(trimmed, "{") -> {:spread, trimmed}
      match = Regex.run(~r/^(:?[A-Za-z0-9_.-]+)(?=[\s=]|$)/, trimmed) -> {:attr, List.last(match)}
      true -> nil
    end
  end

  defp attr_sort_key({:attr, ":" <> _ = name}), do: {0, String.downcase(name)}
  defp attr_sort_key({:attr, name}), do: {1, String.downcase(name)}

  defp attr_start_line?(line, attr_indent) do
    leading_indent(line) == attr_indent and not is_nil(attr_chunk_id(line))
  end

  defp attribute?(<<char, rest::binary>>, name) when char in ~c"\s\t\r\n/", do: attribute?(rest, name)
  defp attribute?(<<?>, _::binary>>, _), do: false
  defp attribute?("", _), do: false

  defp attribute?(<<?{, _::binary>> = source, name) do
    case take_braced(source) do
      {:ok, _, rest} -> attribute?(rest, name)
      :error -> false
    end
  end

  defp attribute?(source, name) do
    {attribute, rest} = attribute_name(source)
    attribute == name or attribute?(skip_attribute_value(rest), name)
  end

  defp attribute_name(source) do
    case :binary.match(source, [" ", "\t", "\r", "\n", "=", "/", ">"]) do
      {0, _} -> {"", binary_part(source, 1, byte_size(source) - 1)}
      {index, _} -> {binary_part(source, 0, index), binary_part(source, index, byte_size(source) - index)}
      :nomatch -> {source, ""}
    end
  end

  defp attribute_value(class) do
    escaped =
      Regex.replace(~r/&(?=#[0-9]|#[xX][0-9A-Fa-f]|[A-Za-z])|["<]/, class, fn
        "&" -> "&amp;"
        "\"" -> "&quot;"
        "<" -> "&lt;"
      end)

    ~s("#{escaped}")
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

  defp class_attribute_match(<<?\\, char, rest::binary>>, index, depth, quote)
       when depth > 0 and (quote in [?", ?'] or char in [?{, ?}]) do
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

  defp class_attribute_size(original, <<char, _::binary>> = rest, size) when char in ~c"=\s\t\r\n" do
    name = binary_part(original, 0, size)
    if name == "class" or String.ends_with?(name, "_class"), do: equals_size(rest, size, false)
  end

  defp class_attribute_size(original, <<char, rest::binary>>, size)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in ~c"_.:-" do
    class_attribute_size(original, rest, size + 1)
  end

  defp class_attribute_size(_, _, _), do: nil

  defp consume_class_match(source, opts, acc, line, length) do
    head = binary_part(source, 0, length)
    tail = binary_part(source, length, byte_size(source) - length)

    format_tag_class_attributes(tail, opts, [head | acc], append_line(line, head))
  end

  defp consume_element(tag, rest, opts, acc, line, mode) do
    braces? = mode == nil

    case {markup_element(tag), raw_text_tag(tag)} do
      {{name, true, no_curly?}, _} ->
        index = element_close_index(rest, {name, braces? and not no_curly?}, 0, 0)
        kept = binary_part(rest, 0, index)

        format_markup(
          binary_part(rest, index, byte_size(rest) - index),
          opts,
          [kept | acc],
          append_line(line, kept),
          mode
        )

      {_, {name, raw_braces?}} ->
        format_markup(rest, opts, acc, line, {name, braces? and raw_braces?, mode})

      {{name, false, true}, _} when braces? ->
        index = element_close_index(rest, {name, false}, 0, 0)
        inner = rest |> binary_part(0, index) |> format_markup(opts, [], line, :no_curly)

        format_markup(
          binary_part(rest, index, byte_size(rest) - index),
          opts,
          [inner | acc],
          append_line(line, inner),
          nil
        )

      _ ->
        format_markup(rest, opts, acc, line, mode)
    end
  end

  defp consume_markup(source, opts, acc, line, 0, mode) do
    case take_markup_tag(source) do
      {:ok, tag, rest} ->
        formatted = format_markup_tag(tag, opts, line)
        consume_element(tag, rest, opts, [formatted | acc], append_line(line, formatted), mode)

      :error ->
        format_markup("", opts, [source | acc], append_line(line, source), mode)
    end
  end

  defp consume_markup(source, opts, acc, line, index, mode) do
    prefix = binary_part(source, 0, index)
    rest = binary_part(source, index, byte_size(source) - index)
    format_markup(rest, opts, [prefix | acc], append_line(line, prefix), mode)
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

  defp element_close_index(source, {name, braces?} = element, offset, depth) do
    case :binary.match(source, if(braces?, do: ["<", "{"], else: ["<"]), scope: {offset, byte_size(source) - offset}) do
      :nomatch ->
        byte_size(source)

      {index, 1} ->
        rest = binary_part(source, index, byte_size(source) - index)

        cond do
          :binary.at(source, index) == ?{ ->
            skip_markup(source, element, depth, take_braced(rest))

          element_tag?(rest, "</" <> name) and depth == 0 ->
            index

          element_tag?(rest, "</" <> name) ->
            element_close_index(source, element, index + 1, depth - 1)

          true ->
            skip_markup_tag(source, element, depth, rest)
        end
    end
  end

  defp element_tag?(source, prefix) do
    size = byte_size(prefix)

    byte_size(source) >= size and String.downcase(binary_part(source, 0, size), :ascii) == prefix and
      RawText.boundary?(source, size)
  end

  defp equals_size(<<char, rest::binary>>, size, equals?) when char in ~c"\s\t\r\n" do
    equals_size(rest, size + 1, equals?)
  end

  defp equals_size(<<?=, rest::binary>>, size, false), do: equals_size(rest, size + 1, true)
  defp equals_size(_, size, true), do: size
  defp equals_size(_, _, false), do: nil

  defp format_attr_expr(expr, indent, opts) do
    trimmed = String.trim(expr)

    case Code.string_to_quoted_with_comments(trimmed) do
      {:ok, list, []} when is_list(list) ->
        {classes, others} = Enum.split_with(list, &is_binary/1)

        if Enum.all?(classes, &String.valid?/1) and not preserved_literals?(others),
          do: {:ok, "{" <> format_attr_items(process_items(list, opts), indent, opts) <> "}"},
          else: :error

      {:ok, value, []} when is_binary(value) ->
        if String.valid?(value), do: {:ok, "{" <> format_attr_string(value, indent, opts) <> "}"}, else: :error

      {:ok, quoted, comments} ->
        if preserved_literals?(quoted), do: :error, else: format_dynamic_classes(trimmed, indent, opts, comments != [])

      _ ->
        :error
    end
  end

  defp format_attr_items([], _, _), do: "[]"

  defp format_attr_items([_, _ | _] = items, indent, _) do
    item_indent = indent <> "  "
    inner = Enum.map_join(items, ",\n" <> item_indent, &String.replace(&1, "\n", "\n" <> item_indent))
    "[\n" <> item_indent <> inner <> "\n" <> indent <> "]"
  end

  defp format_attr_items([item], indent, opts) do
    ("[" <> item <> "]")
    |> Code.format_string!(opts)
    |> IO.iodata_to_binary()
    |> String.replace("\n", "\n" <> indent)
  end

  defp format_attr_string(class, indent, opts) do
    case grouped_class_items(class, opts) do
      [item] ->
        item

      items ->
        format_attr_items(items, indent, opts)
    end
  end

  defp format_attr_value(<<quote, rest::binary>>, indent, opts) when quote in [?", ?'] do
    case :binary.match(rest, <<quote>>) do
      {index, 1} ->
        value = binary_part(rest, 0, index)
        rest = binary_part(rest, index + 1, byte_size(rest) - index - 1)

        case value |> Entities.decode_attribute() |> split_classes() |> grouped_classes(opts) do
          [class] ->
            {:ok, attribute_value(class), rest}

          classes ->
            items = Enum.map(classes, &literal/1)
            {:ok, "{" <> format_attr_items(items, indent, opts) <> "}", rest}
        end

      :nomatch ->
        :error
    end
  end

  defp format_attr_value(<<?{, _::binary>> = source, indent, opts) do
    with {:ok, expr, rest} <- take_braced(source),
         {:ok, value} <- format_attr_expr(expr, indent, opts) do
      {:ok, value, rest}
    end
  end

  defp format_attr_value(_, _, _), do: :error

  defp format_class_attribute_match(source, opts, acc, line, index, length) do
    prefix = binary_part(source, 0, index)
    attribute = binary_part(source, index, length)
    offset = index + length
    rest = binary_part(source, offset, byte_size(source) - offset)
    line = append_line(line, prefix)

    format_class_attribute_value(source, opts, acc, line, prefix, attribute, rest, offset)
  end

  defp format_class_attribute_value(source, opts, acc, line, prefix, attribute, rest, offset) do
    case format_attr_value(rest, elem(line, 0), opts) do
      {:ok, value, rest} ->
        attribute = String.replace(attribute, ~r/\s/, "")
        line = line |> append_line(attribute) |> append_line(value)
        format_tag_class_attributes(rest, opts, [value, attribute, prefix | acc], line)

      :error ->
        consume_class_match(source, opts, acc, line, offset)
    end
  end

  defp format_class_attributes(source, opts) do
    format_markup(source, opts, [], {"", true}, nil)
  end

  defp format_class_expression(quoted, nil), do: quoted

  defp format_class_expression({:__block__, meta, [value]}, stylesheet) do
    {:__block__, meta, [format_class_expression(value, stylesheet)]}
  end

  defp format_class_expression(value, stylesheet) when is_binary(value) do
    value |> split_classes() |> Tailwind.canonicalize(stylesheet) |> Enum.join(" ")
  end

  defp format_class_expression(values, stylesheet) when is_list(values) do
    Enum.map(values, &format_class_expression(&1, stylesheet))
  end

  defp format_class_expression({classes, condition}, stylesheet) do
    {format_class_expression(classes, stylesheet), condition}
  end

  defp format_class_expression({:{}, meta, [truthy, falsy, condition]}, stylesheet) do
    {:{}, meta, [format_class_expression(truthy, stylesheet), format_class_expression(falsy, stylesheet), condition]}
  end

  defp format_class_expression({:&&, meta, [condition, classes]}, stylesheet) do
    {:&&, meta, [condition, format_class_expression(classes, stylesheet)]}
  end

  defp format_class_expression({:||, meta, [left, right]}, stylesheet) do
    {:||, meta, [format_class_expression(left, stylesheet), format_class_expression(right, stylesheet)]}
  end

  defp format_class_expression({form, meta, [condition, branches]}, stylesheet) when form in [:if, :unless] do
    {form, meta,
     [condition, Enum.map(branches, fn {key, value} -> {key, format_class_expression(value, stylesheet)} end)]}
  end

  defp format_class_expression(quoted, _), do: quoted

  defp format_dynamic_classes(expr, indent, opts, comments?) do
    if comments? or opts[:tailwind] do
      {quoted, comments} =
        Code.string_to_quoted_with_comments!(expr,
          literal_encoder: &{:ok, {:__block__, &2, [&1]}},
          token_metadata: true
        )

      formatted = format_class_expression(quoted, opts[:tailwind])

      if formatted == quoted and comments == [] do
        :error
      else
        value =
          formatted
          |> Code.quoted_to_algebra(Keyword.put(opts, :comments, comments))
          |> Inspect.Algebra.format(Keyword.get(opts, :line_length, 98))
          |> IO.iodata_to_binary()
          |> String.replace("\n", "\n" <> indent)

        {:ok, "{" <> value <> "}"}
      end
    else
      :error
    end
  end

  defp format_markup("", _, acc, _, _), do: reverse_iodata_to_binary(acc)

  defp format_markup(source, opts, acc, line, {name, braces?, mode} = raw_tag) do
    case raw_text_end(source, {name, braces?}, 0) do
      nil -> format_markup("", opts, [source | acc], append_line(line, source), raw_tag)
      index -> consume_markup(source, opts, acc, line, index, mode)
    end
  end

  defp format_markup(source, opts, acc, line, mode) do
    case :binary.match(source, if(mode == nil, do: ["<", "{"], else: ["<"])) do
      :nomatch ->
        format_markup("", opts, [source | acc], append_line(line, source), mode)

      {index, 1} ->
        if :binary.at(source, index) == ?{,
          do: consume_markup_expression(source, opts, acc, line, index),
          else: consume_markup(source, opts, acc, line, index, mode)
    end
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

  defp format_source(source, opts) do
    case format_class_attributes(source, opts) do
      ^source ->
        source

      formatted ->
        formatted
        |> HTMLFormatter.format(opts)
        |> format_class_attributes(Keyword.delete(opts, :tailwind))
    end
  end

  defp format_tag_class_attributes("", _, acc, _), do: reverse_iodata_to_binary(acc)

  defp format_tag_class_attributes(source, opts, acc, line) do
    case class_attribute_match(source) do
      :nomatch -> reverse_iodata_to_binary([source | acc])
      {index, length} -> format_class_attribute_match(source, opts, acc, line, index, length)
    end
  end

  defp grouped_class_items(class, opts) do
    class
    |> split_classes()
    |> grouped_classes(opts)
    |> Enum.map(&literal/1)
  end

  defp grouped_classes(classes, opts) do
    classes
    |> Tailwind.canonicalize(opts[:tailwind])
    |> Enum.reject(&(&1 == ""))
    |> Enum.group_by(&score/1)
    |> Enum.sort()
    |> Enum.map(fn {_, tokens} ->
      tokens |> Enum.sort() |> Enum.join(" ")
    end)
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

  defp line_state(line) do
    indent = leading_indent(line)
    {indent, byte_size(indent) == byte_size(line)}
  end

  defp literal(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  defp markup_element(<<"<", first, _::binary>> = tag) when first in ?a..?z or first in ?A..?Z or first in [?., ?:] do
    {name, attributes} = split_tag(tag)
    name = String.downcase(name, :ascii)

    if not Minifier.void_tag?(name) and not String.ends_with?(String.trim_trailing(tag), "/>"),
      do: {name, attribute?(attributes, "phx-no-format"), attribute?(attributes, "phx-no-curly-interpolation")}
  end

  defp markup_element(_), do: nil

  defp preserved_literals?(quoted) do
    quoted
    |> Macro.prewalk(false, fn
      value, true -> {value, true}
      value, false when is_binary(value) -> {value, String.contains?(value, "\n") or not String.valid?(value)}
      value, false -> {value, false}
    end)
    |> elem(1)
  end

  defp process_items(list, opts) do
    {binaries, others} = Enum.split_with(list, &is_binary/1)
    classes = Enum.flat_map(binaries, &split_classes/1)

    grouped =
      classes
      |> grouped_classes(opts)
      |> Enum.map(&literal/1)

    other_strings = Enum.map(others, &(&1 |> format_class_expression(opts[:tailwind]) |> Macro.to_string()))

    grouped ++ other_strings
  end

  # HEEx evaluates EEx tags in raw text elements and {...} unless the element is <script>, <style>
  # or has phx-no-curly-interpolation, so a closing tag inside them is text. Returns the index of
  # the closing tag or nil.
  defp raw_text_end(source, {_, braces?} = raw, offset) do
    patterns = if braces?, do: ["{", "<%", "</"], else: ["<%", "</"]

    case :binary.match(source, patterns, scope: {offset, byte_size(source) - offset}) do
      {index, _} -> raw_text_end_at(source, raw, index, binary_part(source, index, byte_size(source) - index))
      :nomatch -> nil
    end
  end

  defp raw_text_end_at(source, raw, index, "{" <> _ = rest), do: raw_text_skip(source, raw, index, take_braced(rest))
  defp raw_text_end_at(source, raw, index, "<%" <> _ = rest), do: raw_text_skip(source, raw, index, take_markup_tag(rest))

  defp raw_text_end_at(source, {tag, _} = raw, index, rest) do
    if RawText.closing_tag?(rest, tag), do: index, else: raw_text_end(source, raw, index + 2)
  end

  defp raw_text_skip(source, raw, _, {:ok, _, rest}), do: raw_text_end(source, raw, byte_size(source) - byte_size(rest))
  defp raw_text_skip(source, {tag, _}, index, :error), do: raw_text_end(source, {tag, false}, index + 1)

  defp raw_text_tag(<<"<", first, _::binary>> = tag) when first in [?p, ?P, ?s, ?S, ?t, ?T] do
    {name, attributes} = split_tag(tag)
    name = String.downcase(name, :ascii)

    if RawText.tag?(name) and not String.ends_with?(String.trim_trailing(tag), "/>"),
      do: {name, name not in ["script", "style"] and not attribute?(attributes, "phx-no-curly-interpolation")}
  end

  defp raw_text_tag(_), do: nil

  defp reverse_iodata_to_binary(acc) do
    acc
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp scan_attribute_context(<<?{, rest::binary>>, {depth, nil}) do
    scan_attribute_context(rest, {depth + 1, nil})
  end

  defp scan_attribute_context(<<?}, rest::binary>>, {depth, nil}) when depth > 0 do
    scan_attribute_context(rest, {depth - 1, nil})
  end

  defp scan_attribute_context(<<quote, rest::binary>>, {depth, nil}) when quote in [?', ?"] do
    scan_attribute_context(rest, {depth, quote})
  end

  defp scan_attribute_context(<<?\\, _, rest::binary>>, {depth, quote}) when depth > 0 do
    scan_attribute_context(rest, {depth, quote})
  end

  defp scan_attribute_context(<<quote, rest::binary>>, {depth, quote}) do
    scan_attribute_context(rest, {depth, nil})
  end

  defp scan_attribute_context(<<_, rest::binary>>, context), do: scan_attribute_context(rest, context)
  defp scan_attribute_context("", context), do: context

  defp scan_braced(<<?{, rest::binary>>, depth, acc, nil) do
    scan_braced(rest, depth + 1, ["{" | acc], nil)
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

  defp scan_braced(<<"\\", char::utf8, rest::binary>>, depth, acc, state)
       when state in [:double, :single] or char in [?{, ?}] do
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

  defp skip_attribute_value(source) do
    case String.trim_leading(source) do
      "=" <> value -> value |> String.trim_leading() |> skip_value()
      rest -> rest
    end
  end

  defp skip_markup(source, _, _, :error), do: byte_size(source)

  defp skip_markup(source, element, depth, {:ok, _, rest}) do
    element_close_index(source, element, byte_size(source) - byte_size(rest), depth)
  end

  defp skip_markup_tag(source, {name, braces?} = element, depth, rest) do
    case take_markup_tag(rest) do
      {:ok, tag, after_tag} ->
        offset = byte_size(source) - byte_size(after_tag)

        cond do
          raw_tag = raw_text_tag(tag) ->
            {raw_name, raw_braces?} = raw_tag
            raw_size = raw_text_end(after_tag, {raw_name, braces? and raw_braces?}, 0) || byte_size(after_tag)
            element_close_index(source, element, offset + raw_size, depth)

          element_tag?(rest, "<" <> name) and not String.ends_with?(String.trim_trailing(tag), "/>") ->
            element_close_index(source, element, offset, depth + 1)

          true ->
            element_close_index(source, element, offset, depth)
        end

      :error ->
        byte_size(source)
    end
  end

  defp skip_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    case :binary.split(rest, <<quote>>) do
      [_, rest] -> rest
      [_] -> ""
    end
  end

  defp skip_value(<<?{, _::binary>> = source) do
    case take_braced(source) do
      {:ok, _, rest} -> rest
      :error -> ""
    end
  end

  defp skip_value(source) do
    case :binary.match(source, [" ", "\t", "\r", "\n", ">"]) do
      {index, _} -> binary_part(source, index, byte_size(source) - index)
      :nomatch -> ""
    end
  end

  defp sort_attr_chunks(chunks) do
    chunks
    |> Enum.with_index()
    |> Enum.sort_by(fn {{id, _}, index} -> {attr_sort_key(id), index} end)
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

  defp sort_tag_attributes(source) do
    case :binary.match(source, "\n") do
      :nomatch -> source
      _ -> source |> String.split("\n", trim: false) |> sort_tag_attribute_lines([]) |> Enum.join("\n")
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
      split_attr_chunks(lines, attr_indent, [], [], {0, nil})
    else
      :error
    end
  end

  defp split_attr_chunks([], _, [], chunks, {0, nil}), do: {:ok, Enum.reverse(chunks)}

  defp split_attr_chunks([], _, {id, lines}, chunks, {0, nil}) do
    {:ok, Enum.reverse([{id, Enum.reverse(lines)} | chunks])}
  end

  defp split_attr_chunks([], _, _, _, _), do: :error

  defp split_attr_chunks([line | rest], attr_indent, current, chunks, context) do
    next_context = scan_attribute_context(line, context)

    if context == {0, nil} and attr_start_line?(line, attr_indent) do
      id = attr_chunk_id(line)

      chunks =
        case current do
          [] -> chunks
          {id, lines} -> [{id, Enum.reverse(lines)} | chunks]
        end

      split_attr_chunks(rest, attr_indent, {id, [line]}, chunks, next_context)
    else
      case current do
        [] -> :error
        {id, lines} -> split_attr_chunks(rest, attr_indent, {id, [line | lines]}, chunks, next_context)
      end
    end
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

  defp split_tag("<" <> tag) do
    case :binary.match(tag, [" ", "\t", "\r", "\n", "/", ">"]) do
      {index, _} -> {binary_part(tag, 0, index), binary_part(tag, index, byte_size(tag) - index)}
      :nomatch -> {tag, ""}
    end
  end

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

  defp take_braced(<<?{, rest::binary>>) do
    scan_braced(rest, 1, [], nil)
  end

  defp take_braced(_), do: :error

  defp take_markup_tag("<!--" <> _ = source), do: take_markup_until(source, "-->")
  defp take_markup_tag("<%!--" <> _ = source), do: take_markup_until(source, "--%>")
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

  defp take_markup_tag(original, <<?\\, char, rest::binary>>, index, depth, quote)
       when depth > 0 and (quote in [?", ?'] or char in [?{, ?}]) do
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

  defp take_tag_lines(lines, acc), do: take_tag_lines(lines, acc, {0, nil})

  defp take_tag_lines([], _, _), do: :error

  defp take_tag_lines([line | rest], acc, context) do
    acc = [line | acc]

    if context == {0, nil} and tag_close_line?(line) do
      {:ok, Enum.reverse(acc), rest}
    else
      take_tag_lines(rest, acc, scan_attribute_context(line, context))
    end
  end

  defp variant_prefixes(class) do
    case split_class(class, [], 0, []) do
      [_] -> []
      parts -> Enum.drop(parts, -1)
    end
  end
end
