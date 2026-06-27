defmodule PhoenixAssetPipeline.HTML.Minifier do
  @moduledoc """
  Static HTML and rendered HEEx minifier used by PhoenixAssetPipeline.
  """

  @ascii_whitespace [?\s, ?\t, ?\n, ?\r, ?\f]

  @boolean_attrs MapSet.new(~w(
    allowfullscreen async autofocus autoplay checked controls default defer disabled formnovalidate
    hidden inert ismap itemscope loop multiple muted nomodule novalidate open playsinline readonly
    required reversed selected
  ))

  @raw_text_tags MapSet.new(~w(pre script style textarea title))
  @trimmed_raw_text_tags MapSet.new(~w(script style title))
  @void_tags MapSet.new(~w(area base br col embed hr img input link meta param source track wbr))

  defguardp ascii_whitespace?(byte) when byte in [?\s, ?\t, ?\n, ?\r, ?\f]

  @doc false
  def minify_rendered_static(ast) do
    Macro.postwalk(ast, &minify_static_node/1)
  end

  @doc false
  def minify_static_html(html) when is_binary(html) do
    html
    |> minify_html(:none, [])
    |> IO.iodata_to_binary()
  end

  defp binary_list?([item | rest]) when is_binary(item), do: binary_list?(rest)
  defp binary_list?([]), do: true
  defp binary_list?(_), do: false

  defp minify_html(<<>>, _, acc), do: :lists.reverse(acc)

  defp minify_html("<!--" <> rest, last, acc) do
    case take_comment(rest) do
      {:remove, rest} -> minify_html(rest, last, acc)
      {:keep, comment, rest} -> minify_html(rest, :other_tag, [comment | acc])
      :error -> :lists.reverse(["<!--" <> rest | acc])
    end
  end

  defp minify_html("<" <> rest = html, _, acc) do
    case take_tag(rest) do
      {:ok, content, rest} ->
        minify_tag_content(content, rest, acc)

      :error ->
        :lists.reverse([html | acc])
    end
  end

  defp minify_html(html, last, acc) do
    {text, rest} = take_text(html)
    text = minify_text(text, last, closing_tag?(rest), tag?(rest))

    if text == "" do
      minify_html(rest, last, acc)
    else
      minify_html(rest, :text, [text | acc])
    end
  end

  defp minify_tag_content(content, rest, acc) do
    case minify_tag(content) do
      {:ok, tag, {:open, tag_name}, closed?} ->
        minify_open_tag_content(tag, tag_name, closed?, rest, acc)

      {:ok, tag, kind, closed?} ->
        minify_html(rest, tag_last(kind, closed?), [tag | acc])

      :error ->
        minify_html(rest, :text, ["<" | acc])
    end
  end

  defp minify_open_tag_content(tag, tag_name, closed?, rest, acc) do
    acc = [tag | acc]

    if raw_text_tag?(tag_name) and not closed? do
      minify_raw_text(rest, tag_name, acc)
    else
      minify_html(rest, tag_last({:open, tag_name}, closed?), acc)
    end
  end

  defp minify_raw_text(rest, tag_name, acc) do
    case take_raw_text(rest, tag_name) do
      {:ok, raw_text, closing_content, rest} ->
        raw_text = trim_raw_text(tag_name, raw_text)

        closing_tag =
          case minify_tag(closing_content) do
            {:ok, tag, _, _} -> tag
            :error -> ["<", closing_content, ">"]
          end

        minify_html(rest, :close_tag, [closing_tag, raw_text | acc])

      :error ->
        minify_html(rest, :open_tag, acc)
    end
  end

  defp minify_text("", _, _, _), do: ""

  defp minify_text(text, last, next_closing?, next_tag?) do
    text = collapse_ascii_whitespace(text)

    if discard_text?(text, last, next_tag?) do
      ""
    else
      text
      |> maybe_trim_leading(last == :open_tag)
      |> maybe_trim_trailing(next_closing?)
    end
  end

  defp discard_text?("", _, _), do: true

  defp discard_text?(text, last, next_tag?), do: ascii_blank?(text) and discard_blank_text?(last, next_tag?)

  defp discard_blank_text?(last, _) when last in [:open_tag, :close_tag, :void_tag, :other_tag], do: true

  defp discard_blank_text?(:none, true), do: true
  defp discard_blank_text?(_, _), do: false

  defp minify_tag(content) do
    content
    |> trim_ascii()
    |> minify_trimmed_tag()
  end

  defp minify_trimmed_tag(<<>>), do: :error
  defp minify_trimmed_tag(<<?/, _::binary>> = content), do: minify_closing_tag(content)
  defp minify_trimmed_tag(<<?!, _::binary>> = content), do: minify_bang_tag(content)

  defp minify_trimmed_tag(<<??, _::binary>> = content), do: {:ok, ["<", content, ">"], :other, true}

  defp minify_trimmed_tag(content), do: minify_opening_tag(content)

  defp minify_bang_tag(content) do
    tag =
      if doctype_html?(content) do
        "<!doctype html>"
      else
        ["<", content, ">"]
      end

    {:ok, tag, :other, true}
  end

  defp minify_closing_tag(<<?/, rest::binary>>) do
    rest = trim_ascii(rest)
    {name, rest} = take_name(rest)

    if name != "" and trim_ascii(rest) == "" do
      {:ok, ["</", name, ">"], {:close, normalize_ascii_lower(name)}, true}
    else
      :error
    end
  end

  defp minify_opening_tag(content) do
    {content, self_closing?} = split_self_closing(content)
    {name, rest} = take_name(content)

    if name == "" do
      :error
    else
      normalized_name = normalize_ascii_lower(name)
      attrs = parse_attrs(rest)
      void? = void_tag?(normalized_name)
      closed? = self_closing? or void?
      close = if self_closing? and not void?, do: "/>", else: ">"

      {:ok, ["<", name, format_attrs(attrs), close], {:open, normalized_name}, closed?}
    end
  end

  defp format_attrs([]), do: []
  defp format_attrs([attr]), do: [format_attr(attr)]

  defp format_attrs(attrs) do
    attrs
    |> Enum.sort_by(fn {name, _, index} -> {normalize_ascii_lower(name), index} end)
    |> format_attrs([])
  end

  defp format_attrs([attr | rest], acc), do: format_attrs(rest, [format_attr(attr) | acc])
  defp format_attrs([], acc), do: :lists.reverse(acc)

  defp format_attr({name, nil, _}), do: [" ", name]

  defp format_attr({name, value, _}) do
    if boolean_attr?(name) and ascii_equal?(value, name) do
      [" ", name]
    else
      [" ", name, "=", format_attr_value(value)]
    end
  end

  defp format_attr_value(value) do
    value = decode_attr_quote_entities(value)

    if unquoted_attr_value?(value),
      do: value,
      else: quote_attr_value(value)
  end

  defp quote_attr_value(value) do
    case attr_quote_counts(value) do
      {0, _} ->
        [?\", value, ?\"]

      {_, 0} ->
        [?', value, ?']

      {double_quotes, single_quotes} when double_quotes * 5 <= single_quotes * 4 ->
        [?\", escape_attr_quote(value, ?", "&quot;"), ?\"]

      {_, _} ->
        [?', escape_attr_quote(value, ?', "&#39;"), ?']
    end
  end

  defp attr_quote_counts(value), do: attr_quote_counts(value, 0, 0)

  defp attr_quote_counts(<<?", rest::binary>>, double_quotes, single_quotes) do
    attr_quote_counts(rest, double_quotes + 1, single_quotes)
  end

  defp attr_quote_counts(<<?', rest::binary>>, double_quotes, single_quotes) do
    attr_quote_counts(rest, double_quotes, single_quotes + 1)
  end

  defp attr_quote_counts(<<_, rest::binary>>, double_quotes, single_quotes) do
    attr_quote_counts(rest, double_quotes, single_quotes)
  end

  defp attr_quote_counts(<<>>, double_quotes, single_quotes), do: {double_quotes, single_quotes}

  defp escape_attr_quote(value, quote, replacement),
    do: escape_attr_quote(value, quote, replacement, 0, 0, byte_size(value), [])

  defp escape_attr_quote(value, _, _, size, start, size, acc) do
    acc
    |> prepend_segment(value, start, size)
    |> :lists.reverse()
  end

  defp escape_attr_quote(value, quote, replacement, index, start, size, acc) do
    if :binary.at(value, index) == quote do
      acc =
        acc
        |> prepend_segment(value, start, index)
        |> then(&[replacement | &1])

      escape_attr_quote(value, quote, replacement, index + 1, index + 1, size, acc)
    else
      escape_attr_quote(value, quote, replacement, index + 1, start, size, acc)
    end
  end

  defp decode_attr_quote_entities(value) do
    if :binary.match(value, "&") == :nomatch do
      value
    else
      decode_attr_quote_entities(value, 0, 0, byte_size(value), [])
    end
  end

  defp decode_attr_quote_entities(value, size, start, size, []), do: binary_part(value, start, size - start)

  defp decode_attr_quote_entities(value, size, start, size, acc) do
    acc
    |> prepend_segment(value, start, size)
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp decode_attr_quote_entities(value, index, start, size, acc) do
    if :binary.at(value, index) == ?& do
      case attr_quote_entity_at(value, index, size) do
        {:ok, quote, next_index} ->
          acc =
            acc
            |> prepend_segment(value, start, index)
            |> then(&[quote | &1])

          decode_attr_quote_entities(value, next_index, next_index, size, acc)

        :error ->
          decode_attr_quote_entities(value, index + 1, start, size, acc)
      end
    else
      decode_attr_quote_entities(value, index + 1, start, size, acc)
    end
  end

  defp attr_quote_entity_at(value, index, size) do
    rest = binary_part(value, index, size - index)

    case rest do
      <<"&quot;", _::binary>> -> {:ok, "\"", index + 6}
      <<"&QUOT;", _::binary>> -> {:ok, "\"", index + 6}
      <<"&apos;", _::binary>> -> {:ok, "'", index + 6}
      <<"&APOS;", _::binary>> -> {:ok, "'", index + 6}
      <<"&#", rest::binary>> -> numeric_attr_quote_entity_at(rest, index + 2)
      _ -> :error
    end
  end

  defp numeric_attr_quote_entity_at(<<?x, rest::binary>>, index), do: numeric_attr_quote_entity_at(rest, index + 1, 16, 0)

  defp numeric_attr_quote_entity_at(<<?X, rest::binary>>, index), do: numeric_attr_quote_entity_at(rest, index + 1, 16, 0)

  defp numeric_attr_quote_entity_at(rest, index), do: numeric_attr_quote_entity_at(rest, index, 10, 0)

  defp numeric_attr_quote_entity_at(<<?;, _::binary>>, index, _, 34), do: {:ok, "\"", index + 1}
  defp numeric_attr_quote_entity_at(<<?;, _::binary>>, index, _, 39), do: {:ok, "'", index + 1}

  defp numeric_attr_quote_entity_at(<<byte, rest::binary>>, index, base, value) do
    case digit_value(byte, base) do
      :error -> :error
      digit -> numeric_attr_quote_entity_at(rest, index + 1, base, value * base + digit)
    end
  end

  defp numeric_attr_quote_entity_at(<<>>, _, _, _), do: :error

  defp digit_value(byte, 10) when byte in ?0..?9, do: byte - ?0
  defp digit_value(byte, 16) when byte in ?0..?9, do: byte - ?0
  defp digit_value(byte, 16) when byte in ?a..?f, do: byte - ?a + 10
  defp digit_value(byte, 16) when byte in ?A..?F, do: byte - ?A + 10
  defp digit_value(_, _), do: :error

  defp prepend_segment(acc, _, same, same), do: acc

  defp prepend_segment(acc, value, start, stop), do: [binary_part(value, start, stop - start) | acc]

  defp parse_attrs(rest), do: parse_attrs(rest, 0, [])

  defp parse_attrs(rest, index, acc) do
    rest = skip_ascii_whitespace(rest)

    case rest do
      "" ->
        :lists.reverse(acc)

      <<?/, rest::binary>> ->
        parse_attrs(rest, index, acc)

      _ ->
        {name, rest} = take_attr_name(rest)

        if name == "" do
          {_, rest} = take_byte(rest)
          parse_attrs(rest, index, acc)
        else
          {value, rest} = take_attr_value(rest)
          parse_attrs(rest, index + 1, [{name, value, index} | acc])
        end
    end
  end

  defp take_attr_value(rest) do
    rest = skip_ascii_whitespace(rest)

    case rest do
      <<?=, rest::binary>> ->
        rest
        |> skip_ascii_whitespace()
        |> take_attr_value_after_equals()

      _ ->
        {nil, rest}
    end
  end

  defp take_attr_value_after_equals(<<?", rest::binary>>), do: take_quoted_attr_value(rest, ?")

  defp take_attr_value_after_equals(<<?', rest::binary>>), do: take_quoted_attr_value(rest, ?')

  defp take_attr_value_after_equals(rest), do: take_unquoted_attr_value(rest)

  defp take_quoted_attr_value(rest, quote), do: take_quoted_attr_value(rest, quote, 0, byte_size(rest))

  defp take_quoted_attr_value(binary, _, size, size), do: {binary, ""}

  defp take_quoted_attr_value(binary, quote, index, size) do
    if :binary.at(binary, index) == quote do
      {binary_part(binary, 0, index), binary_part(binary, index + 1, size - index - 1)}
    else
      take_quoted_attr_value(binary, quote, index + 1, size)
    end
  end

  defp take_unquoted_attr_value(rest), do: take_unquoted_attr_value(rest, 0, byte_size(rest))

  defp take_unquoted_attr_value(binary, size, size), do: {binary, ""}

  defp take_unquoted_attr_value(binary, index, size) do
    if ascii_whitespace_byte?(:binary.at(binary, index)) do
      {binary_part(binary, 0, index), binary_part(binary, index, size - index)}
    else
      take_unquoted_attr_value(binary, index + 1, size)
    end
  end

  defp take_attr_name(rest), do: take_name(rest)

  defp take_name(binary), do: take_name(binary, 0, byte_size(binary))

  defp take_name(binary, size, size), do: {binary, ""}

  defp take_name(binary, index, size) do
    if attr_name_stop_byte?(:binary.at(binary, index)) do
      {binary_part(binary, 0, index), binary_part(binary, index, size - index)}
    else
      take_name(binary, index + 1, size)
    end
  end

  defp take_byte(<<byte, rest::binary>>), do: {byte, rest}
  defp take_byte(<<>>), do: {nil, ""}

  defp take_comment(rest) do
    case :binary.match(rest, "-->") do
      {index, 3} ->
        content = binary_part(rest, 0, index)
        rest = binary_part(rest, index + 3, byte_size(rest) - index - 3)

        if special_comment?(content) do
          {:keep, ["<!--", content, "-->"], rest}
        else
          {:remove, rest}
        end

      :nomatch ->
        :error
    end
  end

  defp take_raw_text(rest, tag_name) do
    case find_raw_text_close(rest, tag_name, 0) do
      {:ok, index} ->
        raw_text = binary_part(rest, 0, index)
        closing = binary_part(rest, index, byte_size(rest) - index)

        "<" <> closing_rest = closing

        case take_tag(closing_rest) do
          {:ok, closing_content, rest} -> {:ok, raw_text, closing_content, rest}
          :error -> :error
        end

      :error ->
        :error
    end
  end

  defp find_raw_text_close(<<"</", candidate::binary>> = current, tag_name, index) do
    if raw_text_close_at?(candidate, tag_name) do
      {:ok, index}
    else
      <<_, rest::binary>> = current
      find_raw_text_close(rest, tag_name, index + 1)
    end
  end

  defp find_raw_text_close(<<_, rest::binary>>, tag_name, index) do
    find_raw_text_close(rest, tag_name, index + 1)
  end

  defp find_raw_text_close(<<>>, _, _), do: :error

  defp raw_text_close_at?(candidate, tag_name) do
    size = byte_size(tag_name)

    byte_size(candidate) > size and
      ascii_prefix?(candidate, tag_name) and
      raw_text_close_boundary?(candidate, size)
  end

  defp raw_text_close_boundary?(candidate, size) do
    case :binary.at(candidate, size) do
      byte when ascii_whitespace?(byte) or byte in [?>, ?/] -> true
      _ -> false
    end
  end

  defp take_tag(rest), do: take_tag(rest, rest, 0, nil)

  defp take_tag(_, <<>>, _, _), do: :error

  defp take_tag(original, <<byte, rest::binary>>, index, nil) when byte in [?", ?'] do
    take_tag(original, rest, index + 1, byte)
  end

  defp take_tag(original, <<quote, rest::binary>>, index, quote) do
    take_tag(original, rest, index + 1, nil)
  end

  defp take_tag(original, <<?>, rest::binary>>, index, nil) do
    {:ok, binary_part(original, 0, index), rest}
  end

  defp take_tag(original, <<_, rest::binary>>, index, quote) do
    take_tag(original, rest, index + 1, quote)
  end

  defp take_text(html) do
    case :binary.match(html, "<") do
      {0, 1} ->
        {"", html}

      {index, 1} ->
        {binary_part(html, 0, index), binary_part(html, index, byte_size(html) - index)}

      :nomatch ->
        {html, ""}
    end
  end

  defp split_self_closing(content) do
    content = trim_ascii(content)
    size = byte_size(content)

    if size > 0 and :binary.at(content, size - 1) == ?/ and self_closing_slash?(content, size) do
      {content |> binary_part(0, size - 1) |> trim_ascii(), true}
    else
      {content, false}
    end
  end

  defp self_closing_slash?(_, 1), do: true

  defp self_closing_slash?(content, size) do
    previous = :binary.at(content, size - 2)

    ascii_whitespace_byte?(previous) or previous in [?", ?'] or
      not contains_ascii_whitespace?(binary_part(content, 0, size - 1))
  end

  defp collapse_ascii_whitespace(html) do
    if contains_ascii_whitespace?(html) do
      collapse_ascii_whitespace(html, 0, byte_size(html), 0, false, [])
    else
      html
    end
  end

  defp collapse_ascii_whitespace(binary, size, size, start, pending_space?, acc) do
    acc =
      if start < size,
        do: [binary_part(binary, start, size - start) | acc],
        else: acc

    acc =
      if pending_space?,
        do: [" " | acc],
        else: acc

    acc
    |> :lists.reverse()
    |> IO.iodata_to_binary()
  end

  defp collapse_ascii_whitespace(binary, index, size, start, pending_space?, acc) do
    if ascii_whitespace_byte?(:binary.at(binary, index)) do
      acc =
        if start < index,
          do: [binary_part(binary, start, index - start) | acc],
          else: acc

      index = skip_ascii_whitespace_index(binary, index + 1, size)
      collapse_ascii_whitespace(binary, index, size, index, true, acc)
    else
      acc =
        if pending_space?,
          do: [" " | acc],
          else: acc

      start = if pending_space?, do: index, else: start
      collapse_ascii_whitespace(binary, index + 1, size, start, false, acc)
    end
  end

  defp ascii_blank?(<<byte, rest::binary>>) when ascii_whitespace?(byte), do: ascii_blank?(rest)
  defp ascii_blank?(<<>>), do: true
  defp ascii_blank?(_), do: false

  defp ascii_whitespace_byte?(byte), do: byte in @ascii_whitespace
  defp attr_name_stop_byte?(byte), do: ascii_whitespace_byte?(byte) or byte in [?=, ?/, ?>]

  defp contains_ascii_whitespace?(<<byte, _::binary>>) when ascii_whitespace?(byte), do: true
  defp contains_ascii_whitespace?(<<_, rest::binary>>), do: contains_ascii_whitespace?(rest)
  defp contains_ascii_whitespace?(<<>>), do: false

  defp skip_ascii_whitespace(<<byte, rest::binary>>) when ascii_whitespace?(byte) do
    skip_ascii_whitespace(rest)
  end

  defp skip_ascii_whitespace(rest), do: rest

  defp skip_ascii_whitespace_index(binary, index, size) when index < size do
    if ascii_whitespace_byte?(:binary.at(binary, index)) do
      skip_ascii_whitespace_index(binary, index + 1, size)
    else
      index
    end
  end

  defp skip_ascii_whitespace_index(_, index, _), do: index

  defp trim_ascii(binary) do
    size = byte_size(binary)
    start = trim_ascii_leading_index(binary, 0, size)
    stop = trim_ascii_trailing_index(binary, start, size)

    trim_ascii_part(binary, start, stop, size)
  end

  defp trim_ascii_leading(binary) do
    size = byte_size(binary)
    start = trim_ascii_leading_index(binary, 0, size)

    if start == 0, do: binary, else: binary_part(binary, start, size - start)
  end

  defp trim_ascii_trailing(binary) do
    size = byte_size(binary)
    stop = trim_ascii_trailing_index(binary, 0, size)

    if stop == size, do: binary, else: binary_part(binary, 0, stop)
  end

  defp trim_ascii_leading_index(binary, index, size) when index < size do
    if ascii_whitespace_byte?(:binary.at(binary, index)) do
      trim_ascii_leading_index(binary, index + 1, size)
    else
      index
    end
  end

  defp trim_ascii_leading_index(_, index, _), do: index

  defp trim_ascii_trailing_index(binary, start, size) when size > start do
    index = size - 1

    if ascii_whitespace_byte?(:binary.at(binary, index)) do
      trim_ascii_trailing_index(binary, start, index)
    else
      size
    end
  end

  defp trim_ascii_trailing_index(_, start, _), do: start

  defp trim_ascii_part(_, same, same, _), do: ""
  defp trim_ascii_part(binary, 0, size, size), do: binary
  defp trim_ascii_part(binary, start, stop, _), do: binary_part(binary, start, stop - start)

  defp unquoted_attr_value?(""), do: false
  defp unquoted_attr_value?(value), do: unquoted_attr_value_chars?(value)

  defp unquoted_attr_value_chars?(<<byte, _::binary>>) when ascii_whitespace?(byte), do: false

  defp unquoted_attr_value_chars?(<<byte, _::binary>>) when byte in [?", ?', ?=, ?<, ?>, 96], do: false

  defp unquoted_attr_value_chars?(<<_, rest::binary>>), do: unquoted_attr_value_chars?(rest)
  defp unquoted_attr_value_chars?(<<>>), do: true

  defp maybe_trim_leading(text, true), do: trim_ascii_leading(text)
  defp maybe_trim_leading(text, false), do: text

  defp maybe_trim_trailing(text, true), do: trim_ascii_trailing(text)
  defp maybe_trim_trailing(text, false), do: text

  defp special_comment?(content), do: special_comment_content?(trim_ascii_leading(content))

  defp special_comment_content?(<<"[if", _::binary>>), do: true
  defp special_comment_content?(<<"<![endif", _::binary>>), do: true
  defp special_comment_content?(_), do: false

  defp tag?(<<"<", _::binary>>), do: true
  defp tag?(_), do: false

  defp closing_tag?(<<"</", _::binary>>), do: true
  defp closing_tag?(_), do: false

  defp tag_last({:open, _}, true), do: :void_tag
  defp tag_last({:open, _}, false), do: :open_tag
  defp tag_last({:close, _}, _), do: :close_tag
  defp tag_last(_, _), do: :other_tag

  defp raw_text_tag?(tag_name), do: MapSet.member?(@raw_text_tags, tag_name)
  defp void_tag?(tag_name), do: MapSet.member?(@void_tags, tag_name)
  defp boolean_attr?(name), do: MapSet.member?(@boolean_attrs, normalize_ascii_lower(name))

  defp trim_raw_text(tag_name, raw_text) do
    if MapSet.member?(@trimmed_raw_text_tags, tag_name) do
      trim_ascii(raw_text)
    else
      raw_text
    end
  end

  defp minify_heex_static(static) do
    cond do
      attribute_fragment?(static) ->
        static

      open_tag_fragment?(static) and balanced_quotes?(static) ->
        minify_open_tag_fragment(static)

      true ->
        minify_static_html(static)
    end
  end

  defp minify_heex_statics([static]), do: [minify_static_html(static)]

  defp minify_heex_statics([_, _ | _] = statics) do
    statics
    |> minify_heex_static_list([])
    |> trim_dynamic_boundaries()
  end

  defp minify_heex_static_list([static | rest], acc) do
    minify_heex_static_list(rest, [minify_heex_static(static) | acc])
  end

  defp minify_heex_static_list([], acc), do: :lists.reverse(acc)

  defp minify_safe_iodata_parts(parts) do
    {statics, dynamics} = split_safe_iodata_parts(parts)

    statics
    |> minify_heex_statics()
    |> interleave_safe_iodata_parts(dynamics)
  end

  defp minify_static_fields(fields) do
    minify_static_fields(fields, fields, [], nil)
  end

  defp minify_static_fields([{:static, [_ | _] = static} | rest], original, acc, nil) do
    if binary_list?(static) do
      minify_static_fields(rest, original, acc, minify_heex_statics(static))
    else
      original
    end
  end

  defp minify_static_fields([{:static, _} | _], original, _, nil), do: original

  defp minify_static_fields([{:static, _} | rest], original, acc, static) do
    minify_static_fields(rest, original, acc, static)
  end

  defp minify_static_fields([field | rest], original, acc, static) do
    minify_static_fields(rest, original, [field | acc], static)
  end

  defp minify_static_fields([], original, _, nil), do: original

  defp minify_static_fields([], _, acc, static) do
    [{:static, static} | :lists.reverse(acc)]
  end

  defp minify_static_node({:%, struct_meta, [module, {:%{}, map_meta, fields}]} = node) do
    if live_view_rendered_struct?(module) do
      {:%, struct_meta, [module, {:%{}, map_meta, minify_static_fields(fields)}]}
    else
      node
    end
  end

  defp minify_static_node({:safe, parts}) when is_list(parts) do
    {:safe, minify_safe_iodata_parts(parts)}
  end

  defp minify_static_node(node), do: node

  defp live_view_rendered_struct?({:__aliases__, _, [:Phoenix, :LiveView, struct]})
       when struct in [:Rendered, :Comprehension], do: true

  defp live_view_rendered_struct?(Phoenix.LiveView.Rendered), do: true
  defp live_view_rendered_struct?(Phoenix.LiveView.Comprehension), do: true
  defp live_view_rendered_struct?(_), do: false

  defp split_safe_iodata_parts(parts) do
    split_safe_iodata_parts(parts, [], [], [])
  end

  defp split_safe_iodata_parts([part | rest], static, statics, dynamics) when is_binary(part) do
    split_safe_iodata_parts(rest, [part | static], statics, dynamics)
  end

  defp split_safe_iodata_parts([part | rest], static, statics, dynamics)
       when is_integer(part) and part >= 0 and part <= 255 do
    split_safe_iodata_parts(rest, [<<part>> | static], statics, dynamics)
  end

  defp split_safe_iodata_parts([part | rest], static, statics, dynamics) do
    split_safe_iodata_parts(rest, [], [static_binary(static) | statics], [part | dynamics])
  end

  defp split_safe_iodata_parts([], static, statics, dynamics) do
    {:lists.reverse([static_binary(static) | statics]), :lists.reverse(dynamics)}
  end

  defp static_binary([]), do: ""
  defp static_binary([binary]), do: binary
  defp static_binary(static), do: static |> :lists.reverse() |> IO.iodata_to_binary()

  defp interleave_safe_iodata_parts([static | statics], [dynamic | dynamics]) do
    maybe_prepend_static(static, [dynamic | interleave_safe_iodata_parts(statics, dynamics)])
  end

  defp interleave_safe_iodata_parts([static | statics], []) do
    maybe_prepend_static(static, interleave_safe_iodata_parts(statics, []))
  end

  defp interleave_safe_iodata_parts([], []), do: []

  defp maybe_prepend_static("", acc), do: acc
  defp maybe_prepend_static(static, acc), do: [static | acc]

  defp trim_dynamic_boundaries([left, right | rest]) do
    {left, right} = trim_dynamic_boundary(left, right)
    [left | trim_dynamic_boundaries([right | rest])]
  end

  defp trim_dynamic_boundaries([static]), do: [trim_trailing_tag_gap(static)]
  defp trim_dynamic_boundaries(parts), do: parts

  defp trim_dynamic_boundary(left, right) do
    if ascii_blank?(left) and ascii_blank?(right) do
      {"", ""}
    else
      left =
        left
        |> trim_dynamic_attr_boundary(right)
        |> trim_dynamic_text_left()

      right =
        left
        |> trim_void_self_closing_boundary(right)
        |> trim_leading_tag_gap()
        |> trim_dynamic_text_right()

      {left, right}
    end
  end

  defp trim_dynamic_attr_boundary(left, right) do
    trimmed = trim_ascii_trailing(left)

    if trimmed != left and open_tag_fragment?(trimmed) and follows_dynamic_attrs?(right),
      do: trimmed,
      else: left
  end

  defp trim_dynamic_text_left(static) do
    trimmed = trim_ascii_trailing(static)

    if trimmed != static and ends_with_gt?(trimmed),
      do: trimmed,
      else: static
  end

  defp trim_dynamic_text_right(static) do
    trimmed = trim_ascii_leading(static)

    if trimmed != static and starts_with_closing_tag?(trimmed),
      do: trimmed,
      else: static
  end

  defp attribute_fragment?(static) do
    if contains_angle_bracket?(static) do
      false
    else
      case static do
        <<first, rest::binary>> when ascii_whitespace?(first) ->
          rest = skip_ascii_whitespace(rest)
          {name, _} = take_attr_name(rest)
          valid_attr_name?(name)

        _ ->
          false
      end
    end
  end

  defp minify_open_tag_fragment(static) do
    minified = minify_static_html(trim_ascii_trailing(static) <> ">")
    size = byte_size(minified)

    if size > 0 and :binary.at(minified, size - 1) == ?> do
      binary_part(minified, 0, size - 1)
    else
      static
    end
  end

  defp trim_void_self_closing_boundary(left, <<?/, ?>, rest::binary>>) do
    if void_open_tag_fragment?(left), do: ">" <> rest, else: "/>" <> rest
  end

  defp trim_void_self_closing_boundary(_, right), do: right

  defp trim_leading_tag_gap(<<?>, rest::binary>>) do
    case trim_gap_before_tag(rest) do
      {:ok, rest} -> <<?>, rest::binary>>
      :error -> <<?>, rest::binary>>
    end
  end

  defp trim_leading_tag_gap(<<?/, ?>, rest::binary>>) do
    case trim_gap_before_tag(rest) do
      {:ok, rest} -> <<?/, ?>, rest::binary>>
      :error -> <<?/, ?>, rest::binary>>
    end
  end

  defp trim_leading_tag_gap(<<?", ?>, rest::binary>> = static) do
    case trim_gap_before_tag(rest) do
      {:ok, rest} -> <<?", ?>, rest::binary>>
      :error -> static
    end
  end

  defp trim_leading_tag_gap(<<?', ?>, rest::binary>> = static) do
    case trim_gap_before_tag(rest) do
      {:ok, rest} -> <<?', ?>, rest::binary>>
      :error -> static
    end
  end

  defp trim_leading_tag_gap(static), do: static

  defp trim_gap_before_tag(<<byte, rest::binary>>) when ascii_whitespace?(byte) do
    trim_gap_before_tag(rest)
  end

  defp trim_gap_before_tag(<<"<", _::binary>> = rest), do: {:ok, rest}
  defp trim_gap_before_tag(_), do: :error

  defp trim_trailing_tag_gap(static) do
    trimmed = trim_ascii_trailing(static)

    if trimmed != static and ends_with_gt?(trimmed),
      do: trimmed,
      else: static
  end

  defp void_open_tag_fragment?(static) do
    case open_tag_fragment_name(static) do
      nil -> false
      tag_name -> void_tag?(normalize_ascii_lower(tag_name))
    end
  end

  defp balanced_quotes?(static), do: balanced_quotes?(static, nil)

  defp balanced_quotes?(<<>>, nil), do: true
  defp balanced_quotes?(<<>>, _), do: false

  defp balanced_quotes?(<<byte, rest::binary>>, nil) when byte in [?", ?'] do
    balanced_quotes?(rest, byte)
  end

  defp balanced_quotes?(<<quote, rest::binary>>, quote), do: balanced_quotes?(rest, nil)
  defp balanced_quotes?(<<_, rest::binary>>, quote), do: balanced_quotes?(rest, quote)

  defp open_tag_fragment?(static), do: open_tag_fragment_name(static) != nil

  defp follows_dynamic_attrs?(<<first, _::binary>>) when first in [?>, ?/], do: true

  defp follows_dynamic_attrs?(static) do
    static
    |> skip_ascii_whitespace()
    |> follows_dynamic_attr_name?()
  end

  defp follows_dynamic_attr_name?(static) do
    {name, rest} = take_attr_name(static)
    valid_attr_name?(name) and follows_dynamic_attr_tail?(rest)
  end

  defp follows_dynamic_attr_tail?(<<>>), do: false

  defp follows_dynamic_attr_tail?(<<first, _::binary>>) when ascii_whitespace?(first) or first in [?=, ?>], do: true

  defp follows_dynamic_attr_tail?(<<?/, ?>, _::binary>>), do: true
  defp follows_dynamic_attr_tail?(_), do: false

  defp doctype_html?(content), do: doctype_html?(content, "!doctype html")

  defp doctype_html?(<<>>, <<>>), do: true

  defp doctype_html?(<<byte, rest::binary>>, <<expected, expected_rest::binary>>) do
    ascii_equal_byte?(byte, expected) and doctype_html?(rest, expected_rest)
  end

  defp doctype_html?(_, _), do: false

  defp normalize_ascii_lower(binary) do
    if contains_ascii_uppercase?(binary), do: ascii_downcase(binary), else: binary
  end

  defp contains_ascii_uppercase?(<<byte, _::binary>>) when byte in ?A..?Z, do: true
  defp contains_ascii_uppercase?(<<_, rest::binary>>), do: contains_ascii_uppercase?(rest)
  defp contains_ascii_uppercase?(<<>>), do: false

  defp ascii_downcase(binary), do: ascii_downcase(binary, [])

  defp ascii_downcase(<<byte, rest::binary>>, acc) when byte in ?A..?Z do
    ascii_downcase(rest, [<<byte + 32>> | acc])
  end

  defp ascii_downcase(<<byte, rest::binary>>, acc), do: ascii_downcase(rest, [<<byte>> | acc])
  defp ascii_downcase(<<>>, acc), do: acc |> :lists.reverse() |> IO.iodata_to_binary()

  defp ascii_prefix?(_, <<>>), do: true

  defp ascii_prefix?(<<byte, rest::binary>>, <<expected, expected_rest::binary>>) do
    ascii_equal_byte?(byte, expected) and ascii_prefix?(rest, expected_rest)
  end

  defp ascii_prefix?(_, _), do: false

  defp ascii_equal?(left, right) when byte_size(left) == byte_size(right), do: ascii_prefix?(left, right)

  defp ascii_equal?(_, _), do: false

  defp ascii_equal_byte?(byte, byte), do: true
  defp ascii_equal_byte?(left, right) when left in ?A..?Z, do: left + 32 == right
  defp ascii_equal_byte?(left, right) when right in ?A..?Z, do: left == right + 32
  defp ascii_equal_byte?(_, _), do: false

  defp valid_attr_name?(<<first, rest::binary>>) when first in ?A..?Z or first in ?a..?z or first in [?_, ?:] do
    valid_attr_name_tail?(rest)
  end

  defp valid_attr_name?(_), do: false

  defp valid_attr_name_tail?(<<byte, rest::binary>>)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in [?_, ?:, ?., ?-] do
    valid_attr_name_tail?(rest)
  end

  defp valid_attr_name_tail?(<<>>), do: true
  defp valid_attr_name_tail?(_), do: false

  defp contains_angle_bracket?(<<"<", _::binary>>), do: true
  defp contains_angle_bracket?(<<">", _::binary>>), do: true
  defp contains_angle_bracket?(<<_, rest::binary>>), do: contains_angle_bracket?(rest)
  defp contains_angle_bracket?(<<>>), do: false

  defp open_tag_fragment_name(binary), do: open_tag_fragment_name(binary, 0, byte_size(binary), nil)

  defp open_tag_fragment_name(binary, index, size, candidate) when index < size do
    case :binary.at(binary, index) do
      ?< when index + 1 < size ->
        open_tag_fragment_name_after_lt(binary, index, size)

      ?> ->
        open_tag_fragment_name(binary, index + 1, size, nil)

      _ ->
        open_tag_fragment_name(binary, index + 1, size, candidate)
    end
  end

  defp open_tag_fragment_name(_, _, _, candidate), do: candidate

  defp open_tag_fragment_name_after_lt(binary, index, size) do
    next = :binary.at(binary, index + 1)

    if attr_name_start_byte?(next) do
      rest = binary_part(binary, index + 1, size - index - 1)
      {name, _} = take_name(rest)
      open_tag_fragment_name(binary, index + 1 + byte_size(name), size, name)
    else
      open_tag_fragment_name(binary, index + 1, size, nil)
    end
  end

  defp attr_name_start_byte?(byte), do: byte in ?A..?Z or byte in ?a..?z or byte in [?_, ?:]

  defp ends_with_gt?(binary), do: byte_size(binary) > 0 and :binary.at(binary, byte_size(binary) - 1) == ?>

  defp starts_with_closing_tag?(<<"</", _::binary>>), do: true
  defp starts_with_closing_tag?(_), do: false
end
