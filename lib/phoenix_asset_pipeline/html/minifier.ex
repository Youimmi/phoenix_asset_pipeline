defmodule PhoenixAssetPipeline.HTML.Minifier do
  @moduledoc """
  Static HTML and rendered HEEx minifier used by PhoenixAssetPipeline.
  """

  alias PhoenixAssetPipeline.HTML.RawText

  @boolean_attrs MapSet.new(~w(
    allowfullscreen async autofocus autoplay checked controls default defer disabled formnovalidate
    hidden inert ismap itemscope loop multiple muted nomodule novalidate open playsinline readonly
    required reversed selected
  ))

  # Elements that may appear before <body>; any other element or text starts the body implicitly.
  @head_content_tags MapSet.new(~w(base basefont bgsound head html link meta noframes script style template title))
  # Whitespace-only text is not rendered at the document level or directly inside these elements.
  @unrendered_whitespace_containers MapSet.new(~w(colgroup datalist head html optgroup select table tbody tfoot thead tr))
  @trimmed_raw_text_tags MapSet.new(~w(script style title))
  @void_tags MapSet.new(~w(area base br col embed hr img input link meta param source track wbr))

  @doc false
  def minify_rendered_static(ast) do
    Macro.postwalk(ast, &minify_static_node/1)
  end

  @doc false
  def minify_static_html(html) when is_binary(html) do
    minified = minify_markup(html)
    {html, _} = drop_unrendered_whitespace(minified, initial_containers(minified))
    IO.iodata_to_binary(html)
  end

  @doc false
  def void_tag?(tag_name), do: MapSet.member?(@void_tags, tag_name)

  defp ascii_equal?(left, right) when byte_size(left) == byte_size(right), do: ascii_prefix?(left, right)

  defp ascii_equal?(_, _), do: false

  defp ascii_equal_byte?(byte, byte), do: true
  defp ascii_equal_byte?(left, right) when left in ?A..?Z, do: left + 32 == right
  defp ascii_equal_byte?(left, right) when right in ?A..?Z, do: left == right + 32
  defp ascii_equal_byte?(_, _), do: false

  defp ascii_prefix?(_, <<>>), do: true

  defp ascii_prefix?(<<byte, rest::binary>>, <<expected, expected_rest::binary>>) do
    ascii_equal_byte?(byte, expected) and ascii_prefix?(rest, expected_rest)
  end

  defp ascii_prefix?(_, _), do: false

  defguardp ascii_whitespace?(byte) when byte in [?\s, ?\t, ?\n, ?\r, ?\f]

  defp ascii_whitespace_only?(<<byte, rest::binary>>) when ascii_whitespace?(byte), do: ascii_whitespace_only?(rest)
  defp ascii_whitespace_only?(<<>>), do: true
  defp ascii_whitespace_only?(_), do: false

  defp attr_name_start_byte?(byte), do: byte in ?A..?Z or byte in ?a..?z or byte in [?_, ?:]
  defp attr_name_stop_byte?(byte), do: ascii_whitespace?(byte) or byte in [?=, ?/, ?>]

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

  defp attr_quote_entity_at(value, index, size) do
    rest = binary_part(value, index, size - index)

    case rest do
      <<"&quot;", _::binary>> -> {:ok, "\"", index + 6}
      <<"&QUOT;", _::binary>> -> {:ok, "\"", index + 6}
      <<"&apos;", _::binary>> -> {:ok, "'", index + 6}
      <<"&#", rest::binary>> -> numeric_attr_quote_entity_at(rest, index + 2)
      _ -> :error
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

  defp binary_list?([item | rest]) when is_binary(item), do: binary_list?(rest)
  defp binary_list?([]), do: true
  defp binary_list?(_), do: false

  defp body_containers(containers, "body"), do: close_head(containers)

  defp body_containers(containers, name) do
    if MapSet.member?(@head_content_tags, name), do: containers, else: implied_body(containers)
  end

  defp boolean_attr?(name), do: MapSet.member?(@boolean_attrs, String.downcase(name, :ascii))

  # Closing an element opened before the fragment leaves the container unknown.
  defp close_container([name | containers], name), do: containers
  defp close_container([:unknown] = containers, _), do: containers
  defp close_container([], _), do: [:unknown]
  defp close_container([_ | containers], name), do: close_container(containers, name)

  defp close_head(["head" | containers]), do: containers
  defp close_head(containers), do: containers

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
    if ascii_whitespace?(:binary.at(binary, index)) do
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

  defp contains_ascii_whitespace?(<<byte, _::binary>>) when ascii_whitespace?(byte), do: true
  defp contains_ascii_whitespace?(<<_, rest::binary>>), do: contains_ascii_whitespace?(rest)
  defp contains_ascii_whitespace?(<<>>), do: false

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

  defp digit_value(byte, 10) when byte in ?0..?9, do: byte - ?0
  defp digit_value(byte, 16) when byte in ?0..?9, do: byte - ?0
  defp digit_value(byte, 16) when byte in ?a..?f, do: byte - ?a + 10
  defp digit_value(byte, 16) when byte in ?A..?F, do: byte - ?A + 10
  defp digit_value(_, _), do: :error

  # Containers carry over between fragments only across dynamic attribute values and raw text,
  # which cannot change them.
  defp drop_unrendered_fragment_whitespace([static | statics], [:text | contexts], containers, acc) do
    {static, tail} = split_dynamic_whitespace(static, contexts)
    {html, containers} = drop_unrendered_whitespace(static, containers)
    acc = [IO.iodata_to_binary([html, tail]) | acc]
    drop_unrendered_fragment_whitespace(statics, contexts, next_containers(containers, contexts), acc)
  end

  defp drop_unrendered_fragment_whitespace([static | statics], [{:raw, tag_name} | contexts], containers, acc) do
    case RawText.close_index(static, tag_name) do
      index when is_integer(index) ->
        {rest, tail} = static |> binary_part(index, byte_size(static) - index) |> split_dynamic_whitespace(contexts)
        {html, containers} = drop_unrendered_whitespace(rest, containers)
        acc = [IO.iodata_to_binary([binary_part(static, 0, index), html, tail]) | acc]
        drop_unrendered_fragment_whitespace(statics, contexts, next_containers(containers, contexts), acc)

      nil ->
        drop_unrendered_fragment_whitespace(statics, contexts, containers, [static | acc])
    end
  end

  # The fragment continues the open tag `name`, possibly inside a quoted attribute value.
  defp drop_unrendered_fragment_whitespace([static | statics], [{name, quote} | contexts], containers, acc) do
    case tag_rest(static, quote) do
      {content, rest} ->
        tag = binary_part(static, 0, byte_size(static) - byte_size(rest))
        {rest, tail} = split_dynamic_whitespace(rest, contexts)
        {html, containers} = enter_tag(name <> " " <> content, rest, containers, [tag])
        acc = [IO.iodata_to_binary([html, tail]) | acc]
        drop_unrendered_fragment_whitespace(statics, contexts, next_containers(containers, contexts), acc)

      nil ->
        drop_unrendered_fragment_whitespace(statics, contexts, containers, [static | acc])
    end
  end

  defp drop_unrendered_fragment_whitespace([], [], _, acc), do: :lists.reverse(acc)

  defp drop_unrendered_whitespace(html, containers), do: drop_unrendered_whitespace(html, containers, [])

  defp drop_unrendered_whitespace(<<>>, containers, acc), do: {:lists.reverse(acc), containers}

  defp drop_unrendered_whitespace(<<0, rest::binary>>, containers, acc) do
    [text, rest] = :binary.split(rest, <<0>>)
    drop_unrendered_whitespace(rest, containers, [[0, text, 0] | acc])
  end

  defp drop_unrendered_whitespace("<!--" <> rest = html, containers, acc) do
    case :binary.match(rest, "-->") do
      {index, 3} ->
        size = index + 7
        rest = binary_part(html, size, byte_size(html) - size)
        drop_unrendered_whitespace(rest, containers, [binary_part(html, 0, size) | acc])

      :nomatch ->
        {:lists.reverse([html | acc]), containers}
    end
  end

  defp drop_unrendered_whitespace("<" <> rest = html, containers, acc) do
    case take_tag(rest) do
      {:ok, content, rest} -> enter_tag(content, rest, containers, [binary_part(html, 0, byte_size(content) + 2) | acc])
      :error -> {:lists.reverse([html | acc]), containers}
    end
  end

  defp drop_unrendered_whitespace(html, containers, acc) do
    {text, rest} = take_text(html)

    if unrendered_whitespace?(text, containers) do
      drop_unrendered_whitespace(rest, containers, acc)
    else
      containers = if ascii_whitespace_only?(text), do: containers, else: implied_body(containers)
      drop_unrendered_whitespace(rest, containers, [text | acc])
    end
  end

  defp enter_tag(<<?/, closing::binary>>, rest, containers, acc) do
    {name, _} = closing |> trim_ascii() |> take_name()
    drop_unrendered_whitespace(rest, close_container(containers, String.downcase(name, :ascii)), acc)
  end

  defp enter_tag(<<byte, _::binary>>, rest, containers, acc) when byte in [?!, ??] do
    drop_unrendered_whitespace(rest, containers, acc)
  end

  defp enter_tag(content, rest, containers, acc) do
    {content, self_closing?} = split_self_closing(content)
    {name, _} = take_name(content)
    name = String.downcase(name, :ascii)

    containers = body_containers(containers, name)

    cond do
      self_closing? or void_tag?(name) ->
        drop_unrendered_whitespace(rest, containers, acc)

      RawText.tag?(name) ->
        case RawText.close_index(rest, name) do
          index when is_integer(index) ->
            raw_text = binary_part(rest, 0, index)
            rest = binary_part(rest, index, byte_size(rest) - index)
            drop_unrendered_whitespace(rest, [name | containers], [raw_text | acc])

          nil ->
            {:lists.reverse([rest | acc]), [name | containers]}
        end

      true ->
        drop_unrendered_whitespace(rest, [name | containers], acc)
    end
  end

  defp escape_attr_quote(value, quote, replacement) do
    escape_attr_quote(value, quote, replacement, 0, 0, byte_size(value), [])
  end

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

  defp follows_dynamic_attr_name?(static) do
    {name, rest} = take_name(static)
    valid_attr_name?(name) and follows_dynamic_attr_tail?(rest)
  end

  defp follows_dynamic_attr_tail?(<<>>), do: false

  defp follows_dynamic_attr_tail?(<<first, _::binary>>) when ascii_whitespace?(first) or first in [?=, ?>], do: true

  defp follows_dynamic_attr_tail?(<<?/, ?>, _::binary>>), do: true
  defp follows_dynamic_attr_tail?(_), do: false

  defp follows_dynamic_attrs?(<<first, _::binary>>) when first in [?>, ?/], do: true

  defp follows_dynamic_attrs?(static) do
    static
    |> skip_ascii_whitespace()
    |> follows_dynamic_attr_name?()
  end

  defp format_attr({name, nil, _}), do: [" ", name]

  # LiveView reads root element ids from rendered HTML only when the value is quoted.
  defp format_attr({"id", value, _}) do
    [" id=\"", escape_attr_quote(value, ?", "&quot;"), ?"]
  end

  # An attribute without a value has the empty string as its value.
  defp format_attr({name, "", _}), do: [" ", name]

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

  defp format_attrs([], close), do: {[], close}

  defp format_attrs([attr], close) do
    attrs = [format_attr(attr)]
    {attrs, opening_tag_close(close, attrs)}
  end

  defp format_attrs(attrs, close) do
    attrs
    |> Enum.sort_by(fn {name, _, index} -> {String.downcase(name, :ascii), index} end)
    |> format_attrs([], close)
  end

  defp format_attrs([attr | rest], acc, close), do: format_attrs(rest, [format_attr(attr) | acc], close)
  defp format_attrs([], acc, close), do: {:lists.reverse(acc), opening_tag_close(close, acc)}

  defp heex_after_tag(content, rest) do
    case raw_text_open_tag(content) do
      nil -> heex_context(rest, :text)
      tag_name -> heex_context(rest, {:raw, tag_name})
    end
  end

  defp heex_context(static, {:raw, tag_name} = context) do
    case RawText.close_index(static, tag_name) do
      index when is_integer(index) -> heex_context(binary_part(static, index, byte_size(static) - index), :text)
      nil -> context
    end
  end

  defp heex_context(<<0, rest::binary>>, :text) do
    [_, rest] = :binary.split(rest, <<0>>)
    heex_context(rest, :text)
  end

  defp heex_context("<!--" <> rest, :text) do
    case take_comment(rest) do
      {:remove, rest} -> heex_context(rest, :text)
      {:keep, _, rest} -> heex_context(rest, :text)
      :error -> :text
    end
  end

  defp heex_context("<" <> rest, :text) do
    case take_tag(rest) do
      {:ok, content, rest} ->
        heex_after_tag(content, rest)

      :error ->
        {name, _} = take_name(rest)
        heex_quote_context(rest, name, nil)
    end
  end

  defp heex_context(static, :text) do
    case :binary.match(static, ["<", <<0>>]) do
      {index, 1} -> heex_context(binary_part(static, index, byte_size(static) - index), :text)
      :nomatch -> :text
    end
  end

  defp heex_context(static, {name, nil}) do
    case take_tag(static) do
      {:ok, content, rest} -> heex_after_tag(name <> " " <> content, rest)
      :error -> heex_quote_context(static, name, nil)
    end
  end

  defp heex_context(static, {name, quote} = context) do
    case :binary.match(static, <<quote>>) do
      {index, 1} -> heex_context(binary_part(static, index + 1, byte_size(static) - index - 1), {name, nil})
      :nomatch -> context
    end
  end

  defp heex_quote_context(<<quote, rest::binary>>, name, nil) when quote in [?', ?"] do
    heex_quote_context(rest, name, quote)
  end

  defp heex_quote_context(<<quote, rest::binary>>, name, quote), do: heex_quote_context(rest, name, nil)
  defp heex_quote_context(<<_, rest::binary>>, name, quote), do: heex_quote_context(rest, name, quote)
  defp heex_quote_context("", name, quote), do: {name, quote}

  # Body content closes an open <head> and opens <body>, even when neither tag is written.
  defp implied_body([]), do: ["body"]
  defp implied_body(["html" | _] = containers), do: ["body" | containers]
  defp implied_body(["head" | containers]), do: implied_body(containers)
  defp implied_body(containers), do: containers

  defp initial_containers(html), do: if(ascii_prefix?(html, "<!doctype"), do: [], else: [:unknown])

  defp interleave_safe_iodata_parts([static | statics], [dynamic | dynamics]) do
    maybe_prepend_static(static, [dynamic | interleave_safe_iodata_parts(statics, dynamics)])
  end

  defp interleave_safe_iodata_parts([static | statics], []) do
    maybe_prepend_static(static, interleave_safe_iodata_parts(statics, []))
  end

  defp interleave_safe_iodata_parts([], []), do: []

  defp live_view_rendered_struct?({:__aliases__, _, [:Phoenix, :LiveView, struct]})
       when struct in [:Rendered, :Comprehension], do: true

  defp live_view_rendered_struct?(Phoenix.LiveView.Rendered), do: true
  defp live_view_rendered_struct?(Phoenix.LiveView.Comprehension), do: true
  defp live_view_rendered_struct?(_), do: false

  defp maybe_prepend_static("", acc), do: acc
  defp maybe_prepend_static(static, acc), do: [static | acc]

  defp minify_bang_tag(content) do
    tag = if ascii_equal?(content, "!doctype html"), do: "<!doctype html>", else: ["<", content, ">"]

    {:ok, tag, :other, true}
  end

  defp minify_closing_tag(<<?/, rest::binary>>) do
    rest = trim_ascii(rest)
    {name, rest} = take_name(rest)

    if name != "" and trim_ascii(rest) == "" do
      {:ok, ["</", name, ">"], {:close, String.downcase(name, :ascii)}, true}
    else
      :error
    end
  end

  defp minify_heex_fragments([static]), do: [minify_static_html(static)]

  defp minify_heex_fragments([first, _ | _] = statics) do
    {minified, contexts} = minify_heex_static_list(statics, [], [], :text)

    minified
    |> trim_dynamic_boundaries()
    |> drop_unrendered_fragment_whitespace(contexts, initial_containers(first), [])
  end

  defp minify_heex_static(static, {:raw, tag_name}) do
    case RawText.close_index(static, tag_name) do
      index when is_integer(index) ->
        rest = binary_part(static, index, byte_size(static) - index)
        binary_part(static, 0, index) <> minify_heex_static(rest, :text)

      nil ->
        static
    end
  end

  defp minify_heex_static(static, :text) do
    cond do
      :binary.match(static, <<0>>) != :nomatch ->
        minify_markup(static)

      open_tag_fragment?(static) and balanced_quotes?(static) ->
        minify_open_tag_fragment(static)

      true ->
        minify_markup(static)
    end
  end

  defp minify_heex_static(static, {name, nil}) do
    prefix = "<" <> name

    minified =
      case take_tag(static) do
        {:ok, _, _} -> minify_markup(prefix <> static)
        :error -> if balanced_quotes?(static), do: minify_open_tag_fragment(prefix <> static)
      end

    if minified,
      do: binary_part(minified, byte_size(prefix), byte_size(minified) - byte_size(prefix)),
      else: static
  end

  defp minify_heex_static(static, {name, quote}) do
    case :binary.match(static, <<quote>>) do
      {index, 1} ->
        prefix = binary_part(static, 0, index + 1)
        rest = binary_part(static, index + 1, byte_size(static) - index - 1)
        prefix <> minify_heex_static(rest, {name, nil})

      :nomatch ->
        static
    end
  end

  # Returns the minified statics and the context each one starts in.
  defp minify_heex_static_list([static | rest], acc, contexts, context) do
    minified = minify_heex_static(static, context)
    minify_heex_static_list(rest, [minified | acc], [context | contexts], heex_context(static, context))
  end

  defp minify_heex_static_list([], acc, contexts, _), do: {:lists.reverse(acc), :lists.reverse(contexts)}

  defp minify_heex_statics(statics) do
    statics
    |> minify_heex_fragments()
    |> Enum.map(&:binary.replace(&1, <<0>>, "", [:global]))
  end

  defp minify_html(<<>>, acc), do: :lists.reverse(acc)

  defp minify_html(<<0, rest::binary>>, acc) do
    [text, rest] = :binary.split(rest, <<0>>)
    minify_html(rest, [[0, text, 0] | acc])
  end

  defp minify_html("<!--" <> rest, acc) do
    case take_comment(rest) do
      {:remove, rest} -> minify_html(rest, acc)
      {:keep, comment, rest} -> minify_html(rest, [comment | acc])
      :error -> :lists.reverse(["<!--" <> rest | acc])
    end
  end

  defp minify_html("<" <> rest = html, acc) do
    case take_tag(rest) do
      {:ok, content, rest} ->
        minify_tag_content(content, rest, acc)

      :error ->
        :lists.reverse([html | acc])
    end
  end

  defp minify_html(html, acc) do
    {text, rest} = take_text(html)
    text = text |> collapse_ascii_whitespace() |> trim_adjacent_text_space(acc)

    if text == "" do
      minify_html(rest, acc)
    else
      minify_html(rest, [text | acc])
    end
  end

  defp minify_markup(html), do: html |> minify_html([]) |> IO.iodata_to_binary()

  defp minify_open_tag_content(tag, tag_name, closed?, rest, acc) do
    acc = [tag | acc]

    if RawText.tag?(tag_name) and not closed? do
      minify_raw_text(rest, tag_name, acc)
    else
      minify_html(rest, acc)
    end
  end

  defp minify_open_tag_fragment(static) do
    minified = minify_markup(trim_ascii_trailing(static) <> ">")
    size = byte_size(minified)

    if size > 0 and :binary.at(minified, size - 1) == ?> do
      binary_part(minified, 0, size - 1)
    else
      static
    end
  end

  defp minify_opening_tag(content) do
    {content, self_closing?} = split_self_closing(content)
    {name, rest} = take_name(content)

    if name == "" do
      :error
    else
      normalized_name = String.downcase(name, :ascii)
      void? = void_tag?(normalized_name)
      closed? = self_closing? or void?
      close = if self_closing? and not void?, do: "/>", else: ">"
      {attrs, close} = format_attrs(parse_attrs(rest), close)

      {:ok, ["<", name, attrs, close], {:open, normalized_name}, closed?}
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

        minify_html(rest, [closing_tag, raw_text | acc])

      # The element continues past this fragment, so its raw text is kept as written.
      :error ->
        :lists.reverse([rest | acc])
    end
  end

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

  defp minify_tag(content) do
    content
    |> trim_ascii()
    |> minify_trimmed_tag()
  end

  defp minify_tag_content(content, rest, acc) do
    case minify_tag(content) do
      {:ok, tag, {:open, tag_name}, closed?} ->
        minify_open_tag_content(tag, tag_name, closed?, rest, acc)

      {:ok, tag, _, _} ->
        minify_html(rest, [tag | acc])

      :error ->
        minify_html(rest, ["<" | acc])
    end
  end

  defp minify_trimmed_tag(<<>>), do: :error
  defp minify_trimmed_tag(<<?/, _::binary>> = content), do: minify_closing_tag(content)
  defp minify_trimmed_tag(<<?!, _::binary>> = content), do: minify_bang_tag(content)

  defp minify_trimmed_tag(<<??, _::binary>> = content), do: {:ok, ["<", content, ">"], :other, true}

  defp minify_trimmed_tag(content), do: minify_opening_tag(content)

  # Text-level dynamic parts may hold any markup, even unbalanced safe HTML.
  defp next_containers(_, [:text | _]), do: [:unknown]
  defp next_containers(containers, _), do: containers

  defp numeric_attr_quote_entity_at(<<?x, rest::binary>>, index), do: numeric_attr_quote_entity_at(rest, index + 1, 16, 0)

  defp numeric_attr_quote_entity_at(<<?X, rest::binary>>, index), do: numeric_attr_quote_entity_at(rest, index + 1, 16, 0)

  defp numeric_attr_quote_entity_at(rest, index), do: numeric_attr_quote_entity_at(rest, index, 10, 0)

  defp numeric_attr_quote_entity_at(<<?;, _::binary>>, index, _, 34), do: {:ok, "\"", index + 1}
  defp numeric_attr_quote_entity_at(<<?;, _::binary>>, index, _, 39), do: {:ok, "'", index + 1}

  defp numeric_attr_quote_entity_at(<<byte, rest::binary>>, index, base, value) when value <= 39 do
    case digit_value(byte, base) do
      :error -> :error
      digit -> numeric_attr_quote_entity_at(rest, index + 1, base, value * base + digit)
    end
  end

  defp numeric_attr_quote_entity_at(_, _, _, _), do: :error

  defp open_tag_fragment?(static), do: open_tag_fragment_name(static) != nil

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

  defp opening_tag_close("/>", [[_, _, _, value] | _]) when is_binary(value), do: " />"

  defp opening_tag_close(close, _), do: close

  defp parse_attrs(rest), do: parse_attrs(rest, 0, [])

  defp parse_attrs(rest, index, acc) do
    rest = skip_ascii_whitespace(rest)

    case rest do
      "" ->
        :lists.reverse(acc)

      <<?/, rest::binary>> ->
        parse_attrs(rest, index, acc)

      _ ->
        {name, rest} = take_name(rest)

        if name == "" do
          {_, rest} = take_byte(rest)
          parse_attrs(rest, index, acc)
        else
          {value, rest} = take_attr_value(rest)
          parse_attrs(rest, index + 1, [{name, value, index} | acc])
        end
    end
  end

  defp prepend_segment(acc, _, same, same), do: acc

  defp prepend_segment(acc, value, start, stop), do: [binary_part(value, start, stop - start) | acc]

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

  defp raw_text_open_tag(content) do
    {content, self_closing?} = split_self_closing(content)
    {name, _} = take_name(content)
    name = String.downcase(name, :ascii)
    if not self_closing? and RawText.tag?(name), do: name
  end

  defp self_closing_slash?(_, 1), do: true

  defp self_closing_slash?(content, size) do
    previous = :binary.at(content, size - 2)

    ascii_whitespace?(previous) or previous in [?", ?'] or
      self_closing_slash_token?(content, size - 2, false)
  end

  defp self_closing_slash_token?(_, index, _) when index < 0, do: true

  defp self_closing_slash_token?(content, index, whitespace?) do
    byte = :binary.at(content, index)

    cond do
      byte == ?= -> false
      ascii_whitespace?(byte) -> self_closing_slash_token?(content, index - 1, true)
      whitespace? -> true
      true -> self_closing_slash_token?(content, index - 1, false)
    end
  end

  defp skip_ascii_whitespace(<<byte, rest::binary>>) when ascii_whitespace?(byte) do
    skip_ascii_whitespace(rest)
  end

  defp skip_ascii_whitespace(rest), do: rest

  defp skip_ascii_whitespace_index(binary, index, size) when index < size do
    if ascii_whitespace?(:binary.at(binary, index)) do
      skip_ascii_whitespace_index(binary, index + 1, size)
    else
      index
    end
  end

  defp skip_ascii_whitespace_index(_, index, _), do: index

  defp special_comment?(content), do: special_comment_content?(skip_ascii_whitespace(content))

  defp special_comment_content?(<<"[if", _::binary>>), do: true
  defp special_comment_content?(<<"<![endif", _::binary>>), do: true
  defp special_comment_content?(_), do: false

  # Whitespace before a text-level dynamic part may end up next to its text, so it is kept.
  defp split_dynamic_whitespace(html, [:text | _]) do
    trimmed = trim_ascii_trailing(html)
    {trimmed, binary_part(html, byte_size(trimmed), byte_size(html) - byte_size(trimmed))}
  end

  defp split_dynamic_whitespace(html, _), do: {html, ""}

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

  defp split_self_closing(content) do
    content = trim_ascii(content)
    size = byte_size(content)

    if size > 0 and :binary.at(content, size - 1) == ?/ and self_closing_slash?(content, size) do
      {content |> binary_part(0, size - 1) |> trim_ascii(), true}
    else
      {content, false}
    end
  end

  defp static_binary([]), do: ""
  defp static_binary([binary]), do: binary
  defp static_binary(static), do: static |> :lists.reverse() |> IO.iodata_to_binary()

  defp tag_rest(static, nil) do
    case take_tag(static) do
      {:ok, content, rest} -> {content, rest}
      :error -> nil
    end
  end

  defp tag_rest(static, quote) do
    case :binary.split(static, <<quote>>) do
      [_, after_quote] -> tag_rest(after_quote, nil)
      [_] -> nil
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

  defp take_name(binary), do: take_name(binary, 0, byte_size(binary))

  defp take_name(binary, size, size), do: {binary, ""}

  defp take_name(binary, index, size) do
    if attr_name_stop_byte?(:binary.at(binary, index)) do
      {binary_part(binary, 0, index), binary_part(binary, index, size - index)}
    else
      take_name(binary, index + 1, size)
    end
  end

  defp take_quoted_attr_value(rest, quote), do: take_quoted_attr_value(rest, quote, 0, byte_size(rest))

  defp take_quoted_attr_value(binary, _, size, size), do: {binary, ""}

  defp take_quoted_attr_value(binary, quote, index, size) do
    if :binary.at(binary, index) == quote do
      {binary_part(binary, 0, index), binary_part(binary, index + 1, size - index - 1)}
    else
      take_quoted_attr_value(binary, quote, index + 1, size)
    end
  end

  defp take_raw_text(rest, tag_name) do
    case RawText.close_index(rest, tag_name) do
      index when is_integer(index) ->
        raw_text = binary_part(rest, 0, index)
        closing = binary_part(rest, index, byte_size(rest) - index)

        "<" <> closing_rest = closing

        case take_tag(closing_rest) do
          {:ok, closing_content, rest} -> {:ok, raw_text, closing_content, rest}
          :error -> :error
        end

      nil ->
        :error
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
    case :binary.match(html, ["<", <<0>>]) do
      {0, 1} ->
        {"", html}

      {index, 1} ->
        {binary_part(html, 0, index), binary_part(html, index, byte_size(html) - index)}

      :nomatch ->
        {html, ""}
    end
  end

  defp take_unquoted_attr_value(rest), do: take_unquoted_attr_value(rest, 0, byte_size(rest))

  defp take_unquoted_attr_value(binary, size, size), do: {binary, ""}

  defp take_unquoted_attr_value(binary, index, size) do
    if ascii_whitespace?(:binary.at(binary, index)) do
      {binary_part(binary, 0, index), binary_part(binary, index, size - index)}
    else
      take_unquoted_attr_value(binary, index + 1, size)
    end
  end

  defp trim_adjacent_text_space(" " <> rest = text, [previous | _])
       when is_binary(previous) and byte_size(previous) > 0 do
    if :binary.last(previous) == ?\s, do: rest, else: text
  end

  defp trim_adjacent_text_space(text, _), do: text

  defp trim_ascii(binary) do
    size = byte_size(binary)
    start = trim_ascii_leading_index(binary, 0, size)
    stop = trim_ascii_trailing_index(binary, start, size)

    trim_ascii_part(binary, start, stop, size)
  end

  defp trim_ascii_leading_index(binary, index, size) when index < size do
    if ascii_whitespace?(:binary.at(binary, index)) do
      trim_ascii_leading_index(binary, index + 1, size)
    else
      index
    end
  end

  defp trim_ascii_leading_index(_, index, _), do: index

  defp trim_ascii_part(_, same, same, _), do: ""
  defp trim_ascii_part(binary, 0, size, size), do: binary
  defp trim_ascii_part(binary, start, stop, _), do: binary_part(binary, start, stop - start)

  defp trim_ascii_trailing(binary) do
    size = byte_size(binary)
    stop = trim_ascii_trailing_index(binary, 0, size)

    if stop == size, do: binary, else: binary_part(binary, 0, stop)
  end

  defp trim_ascii_trailing_index(binary, start, size) when size > start do
    index = size - 1

    if ascii_whitespace?(:binary.at(binary, index)) do
      trim_ascii_trailing_index(binary, start, index)
    else
      size
    end
  end

  defp trim_ascii_trailing_index(_, start, _), do: start

  defp trim_dynamic_attr_boundary(left, right) do
    trimmed = trim_ascii_trailing(left)

    if trimmed != left and open_tag_fragment?(trimmed) and follows_dynamic_attrs?(right),
      do: trimmed,
      else: left
  end

  defp trim_dynamic_boundaries([left, right | rest]) do
    {left, right} = trim_dynamic_boundary(left, right)
    [left | trim_dynamic_boundaries([right | rest])]
  end

  defp trim_dynamic_boundaries([static]), do: [static]
  defp trim_dynamic_boundaries(parts), do: parts

  defp trim_dynamic_boundary(left, right) do
    left = trim_dynamic_attr_boundary(left, right)
    right = trim_void_self_closing_boundary(left, right)

    {left, right}
  end

  defp trim_raw_text(tag_name, raw_text) do
    if MapSet.member?(@trimmed_raw_text_tags, tag_name), do: trim_ascii(raw_text), else: raw_text
  end

  defp trim_void_self_closing_boundary(left, <<?/, ?>, rest::binary>>) do
    if void_open_tag_fragment?(left), do: ">" <> rest, else: "/>" <> rest
  end

  defp trim_void_self_closing_boundary(_, right), do: right

  defp unquoted_attr_value?(""), do: false
  defp unquoted_attr_value?(value), do: unquoted_attr_value_chars?(value)

  defp unquoted_attr_value_chars?(<<byte, _::binary>>) when ascii_whitespace?(byte), do: false

  defp unquoted_attr_value_chars?(<<byte, _::binary>>) when byte in [?", ?', ?=, ?<, ?>, 96], do: false

  defp unquoted_attr_value_chars?(<<_, rest::binary>>), do: unquoted_attr_value_chars?(rest)
  defp unquoted_attr_value_chars?(<<>>), do: true

  defp unrendered_container?([]), do: true
  defp unrendered_container?([name | _]) when is_binary(name), do: MapSet.member?(@unrendered_whitespace_containers, name)
  defp unrendered_container?(_), do: false

  defp unrendered_whitespace?(text, containers), do: unrendered_container?(containers) and ascii_whitespace_only?(text)

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

  defp void_open_tag_fragment?(static) do
    case open_tag_fragment_name(static) do
      nil -> false
      tag_name -> void_tag?(String.downcase(tag_name, :ascii))
    end
  end
end
