defmodule PhoenixAssetPipeline.HTML.ClassAttrs do
  @moduledoc false

  alias Phoenix.LiveView.TagEngine.Compiler
  alias Phoenix.LiveView.TagEngine.Parser
  alias PhoenixAssetPipeline.HTML.Macros

  def compile(source, options) do
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

    source
    |> Parser.parse!(options)
    |> rewrite(env, file)
    |> Compiler.compile(options)
  end

  defp class_value_ast(classes, env) do
    case Macros.__class_value_ast__(classes, env) do
      nil -> :error
      ast -> {:ok, ast}
    end
  end

  defp parse_expression!(value, meta, file) do
    Code.string_to_quoted!(value,
      column: meta[:column] || 1,
      file: file,
      line: meta[:line] || 1
    )
  end

  defp expression_meta(value_meta, attr_meta) do
    %{
      column: value_meta[:column] || attr_meta[:column] || 1,
      line: value_meta[:line] || attr_meta[:line] || 1
    }
  end

  defp rewrite(%Parser{} = parser, env, file) do
    %{parser | nodes: rewrite_nodes(parser.nodes, env, file)}
  end

  defp rewrite_attribute({"class", {:expr, value, value_meta}, attr_meta}, env, file) do
    ast = parse_expression!(value, value_meta, file)

    case class_value_ast(ast, env) do
      {:ok, rewritten_ast} ->
        {"class", {:expr, Macro.to_string(rewritten_ast), value_meta}, attr_meta}

      :error ->
        {"class", {:expr, value, value_meta}, attr_meta}
    end
  end

  defp rewrite_attribute({"class", {:string, value, value_meta}, attr_meta}, env, _) do
    case class_value_ast(value, env) do
      {:ok, ast} ->
        {"class", {:expr, Macro.to_string(ast), expression_meta(value_meta, attr_meta)}, attr_meta}

      :error ->
        {"class", {:string, value, value_meta}, attr_meta}
    end
  end

  defp rewrite_attribute({:root, {:expr, value, value_meta}, attr_meta}, env, file) do
    ast = parse_expression!(value, value_meta, file)

    case rewrite_root_expression(ast, env) do
      {:ok, rewritten_ast} ->
        {:root, {:expr, Macro.to_string(rewritten_ast), value_meta}, attr_meta}

      :error ->
        {:root, {:expr, value, value_meta}, attr_meta}
    end
  end

  defp rewrite_attribute(attribute, _, _), do: attribute

  defp rewrite_attributes(attrs, env, file) do
    Enum.map(attrs, &rewrite_attribute(&1, env, file))
  end

  defp rewrite_node({:block, type, name, attrs, children, meta, close_meta}, env, file) do
    {:block, type, name, rewrite_attributes(attrs, env, file), rewrite_nodes(children, env, file), meta, close_meta}
  end

  defp rewrite_node({:self_close, type, name, attrs, meta}, env, file) do
    {:self_close, type, name, rewrite_attributes(attrs, env, file), meta}
  end

  defp rewrite_node({:eex_block, value, clauses, meta}, env, file) do
    {:eex_block, value, rewrite_eex_clauses(clauses, env, file), meta}
  end

  defp rewrite_node(node, _, _), do: node

  defp rewrite_nodes(nodes, env, file) do
    Enum.map(nodes, &rewrite_node(&1, env, file))
  end

  defp rewrite_eex_clauses(clauses, env, file) do
    Enum.map(clauses, fn {nodes, expression, meta} ->
      {rewrite_nodes(nodes, env, file), expression, meta}
    end)
  end

  defp rewrite_root_entry({key, value}, env) when key in [:class, "class"] do
    case class_value_ast(value, env) do
      {:ok, ast} -> {:changed, {key, ast}}
      :error -> {:same, {key, value}}
    end
  end

  defp rewrite_root_entry(entry, _), do: {:same, entry}

  defp rewrite_root_expression({:%{}, meta, entries}, env) do
    with {:ok, entries} <- rewrite_root_entries(entries, env) do
      {:ok, {:%{}, meta, entries}}
    end
  end

  defp rewrite_root_expression(entries, env) when is_list(entries) do
    rewrite_root_entries(entries, env)
  end

  defp rewrite_root_expression(_, _), do: :error

  defp rewrite_root_entries(entries, env) do
    {entries, changed?} =
      Enum.map_reduce(entries, false, fn entry, changed? ->
        case rewrite_root_entry(entry, env) do
          {:changed, entry} -> {entry, true}
          {:same, entry} -> {entry, changed?}
        end
      end)

    if changed?, do: {:ok, entries}, else: :error
  end
end
