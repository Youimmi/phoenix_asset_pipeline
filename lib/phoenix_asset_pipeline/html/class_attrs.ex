defmodule PhoenixAssetPipeline.HTML.ClassAttrs do
  @moduledoc false

  alias Phoenix.LiveView.TagEngine.Compiler
  alias Phoenix.LiveView.TagEngine.Parser
  alias PhoenixAssetPipeline.HTML.Entities
  alias PhoenixAssetPipeline.HTML.Minifier

  def compile(source, options, class_value_ast) when is_function(class_value_ast, 2) do
    if String.contains?(source, <<0>>) do
      raise ArgumentError, "HEEx cannot contain null bytes"
    end

    {minify?, options} = Keyword.pop(options, :minify, true)

    options =
      options
      |> Keyword.validate!([
        :caller,
        :tag_handler,
        :trim,
        line: 1,
        indentation: 0,
        file: "nofile",
        engine: Phoenix.LiveView.Engine
      ])
      |> Keyword.merge(source: source, trim_eex: false, strip_eex_comments: true)

    env = Keyword.fetch!(options, :caller)
    file = Keyword.fetch!(options, :file)
    context = {env, class_value_ast, minify?}

    ast =
      source
      |> Parser.parse!(options)
      |> rewrite(context, file)
      |> Compiler.compile(options)

    if minify?, do: Minifier.minify_rendered_static(ast), else: ast
  end

  defp class_attribute?("class"), do: true
  defp class_attribute?(name) when is_atom(name), do: name |> Atom.to_string() |> class_attribute?()
  defp class_attribute?(name), do: String.ends_with?(name, "_class")

  defp class_value_ast(classes, {env, class_value_ast, _}) do
    case class_value_ast.(classes, env) do
      nil -> :error
      ast -> {:ok, ast}
    end
  end

  defp expression_meta(value_meta, attr_meta) do
    %{
      column: value_meta[:column] || attr_meta[:column] || 1,
      line: value_meta[:line] || attr_meta[:line] || 1
    }
  end

  defp normalize_eex_whitespace([
         {:text, left, _} = left_node,
         {:eex_block, value, clauses, meta} = block,
         {:text, right, right_meta} | rest
       ]) do
    if text_ends_whitespace?(left) and text_starts_whitespace?(right) and simple_eex_block?(value) and
         meta[:opt] == ~c"=" and Enum.all?(clauses, &trailing_clause_whitespace?/1) do
      block = {:eex_block, value, Enum.map(clauses, &trim_clause_leading_whitespace/1), meta}
      right_node = {:text, trim_leading_whitespace(right), right_meta}
      [left_node, block | normalize_eex_whitespace([right_node | rest])]
    else
      [left_node | normalize_eex_whitespace([block, {:text, right, right_meta} | rest])]
    end
  end

  defp normalize_eex_whitespace([node | rest]), do: [node | normalize_eex_whitespace(rest)]
  defp normalize_eex_whitespace([]), do: []

  defp parse_expression!(value, meta, file) do
    Code.string_to_quoted!(value,
      column: meta[:column] || 1,
      file: file,
      line: meta[:line] || 1
    )
  end

  defp rewrite(%Parser{} = parser, context, file) do
    %{parser | nodes: rewrite_nodes(parser.nodes, context, file)}
  end

  defp rewrite_attribute({name, {:expr, value, value_meta}, attr_meta} = attribute, context, file) when is_binary(name) do
    if class_attribute?(name) do
      ast = parse_expression!(value, value_meta, file)

      case class_value_ast(ast, context) do
        {:ok, rewritten_ast} ->
          {name, {:expr, Macro.to_string(rewritten_ast), value_meta}, attr_meta}

        :error ->
          attribute
      end
    else
      attribute
    end
  end

  defp rewrite_attribute({name, {:string, value, value_meta}, attr_meta} = attribute, context, _) when is_binary(name) do
    if class_attribute?(name) do
      case class_value_ast(Entities.decode_attribute(value), context) do
        {:ok, ast} ->
          {name, {:expr, Macro.to_string(ast), expression_meta(value_meta, attr_meta)}, attr_meta}

        :error ->
          attribute
      end
    else
      attribute
    end
  end

  defp rewrite_attribute({:root, {:expr, value, value_meta}, attr_meta}, context, file) do
    ast = parse_expression!(value, value_meta, file)

    case rewrite_root_expression(ast, context) do
      {:ok, rewritten_ast} ->
        {:root, {:expr, Macro.to_string(rewritten_ast), value_meta}, attr_meta}

      :error ->
        {:root, {:expr, value, value_meta}, attr_meta}
    end
  end

  defp rewrite_attribute(attribute, _, _), do: attribute

  defp rewrite_attributes(attrs, context, file) do
    Enum.map(attrs, &rewrite_attribute(&1, context, file))
  end

  defp rewrite_eex_clauses(clauses, context, file) do
    Enum.map(clauses, fn {nodes, expression, meta} ->
      {rewrite_nodes(nodes, context, file), expression, meta}
    end)
  end

  defp rewrite_node({:block, type, name, attrs, children, meta, close_meta}, context, file) do
    child_context =
      if type == :tag and elem(context, 2) != false and
           String.downcase(name) in ~w(pre script style textarea title),
         do: put_elem(context, 2, :preserve),
         else: context

    {:block, type, name, rewrite_attributes(attrs, context, file), rewrite_nodes(children, child_context, file), meta,
     close_meta}
  end

  defp rewrite_node({:self_close, type, name, attrs, meta}, context, file) do
    {:self_close, type, name, rewrite_attributes(attrs, context, file), meta}
  end

  defp rewrite_node({:eex_block, value, clauses, meta}, context, file) do
    {:eex_block, value, rewrite_eex_clauses(clauses, context, file), meta}
  end

  defp rewrite_node({:text, text, meta}, {_, _, :preserve}, _) do
    # Keep raw text intact when HEEx merges and splits static fragments around expressions.
    {:text, <<0, text::binary, 0>>, meta}
  end

  defp rewrite_node(node, _, _), do: node

  defp rewrite_nodes(nodes, context, file) do
    nodes = if elem(context, 2) == true, do: normalize_eex_whitespace(nodes), else: nodes
    Enum.map(nodes, &rewrite_node(&1, context, file))
  end

  defp rewrite_root_entries(entries, context) do
    {entries, changed?} =
      Enum.map_reduce(entries, false, fn entry, changed? ->
        case rewrite_root_entry(entry, context) do
          {:changed, entry} -> {entry, true}
          {:same, entry} -> {entry, changed?}
        end
      end)

    if changed?, do: {:ok, entries}, else: :error
  end

  defp rewrite_root_entry({key, value} = entry, context) when is_atom(key) or is_binary(key) do
    if class_attribute?(key) do
      case class_value_ast(value, context) do
        {:ok, ast} -> {:changed, {key, ast}}
        :error -> {:same, entry}
      end
    else
      {:same, entry}
    end
  end

  defp rewrite_root_entry(entry, _), do: {:same, entry}

  defp rewrite_root_expression({:%{}, meta, entries}, context) do
    with {:ok, entries} <- rewrite_root_entries(entries, context) do
      {:ok, {:%{}, meta, entries}}
    end
  end

  defp rewrite_root_expression(entries, context) when is_list(entries) do
    rewrite_root_entries(entries, context)
  end

  defp rewrite_root_expression(_, _), do: :error

  defp simple_eex_block?(value) do
    case Code.string_to_quoted(value <> "\nend") do
      {:ok, {form, _, args}} when form in [:if, :unless, :for] -> match?([do: _], List.last(args))
      _ -> false
    end
  end

  defp text_ends_whitespace?(text) when byte_size(text) > 0, do: :binary.last(text) in ~c"\s\t\n\r\f"
  defp text_ends_whitespace?(_), do: false
  defp text_starts_whitespace?(<<byte, _::binary>>), do: byte in ~c"\s\t\n\r\f"
  defp text_starts_whitespace?(_), do: false

  defp trailing_clause_whitespace?({nodes, _, _}) do
    case List.last(nodes) do
      {:text, text, _} -> text_ends_whitespace?(text)
      _ -> false
    end
  end

  defp trim_clause_leading_whitespace({[{:text, text, meta} | rest], expression, clause_meta}) do
    {[{:text, trim_leading_whitespace(text), meta} | rest], expression, clause_meta}
  end

  defp trim_clause_leading_whitespace(clause), do: clause

  defp trim_leading_whitespace(<<byte, rest::binary>>) when byte in ~c"\s\t\n\r\f", do: trim_leading_whitespace(rest)
  defp trim_leading_whitespace(text), do: text
end
