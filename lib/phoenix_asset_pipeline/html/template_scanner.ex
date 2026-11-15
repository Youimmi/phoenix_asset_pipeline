defmodule PhoenixAssetPipeline.HTML.TemplateScanner do
  @moduledoc false

  # Walks Elixir source and HEEx templates for asset references. `visit` sees each Elixir node first
  # and returns `{:ok, acc}` when it consumed the node or `:next` to descend into it. `tag` sees each
  # HEEx tag with its attributes as `{key, {:expr, ast} | {:string, raw} | nil}`, after the
  # attribute expressions were scanned.

  alias Phoenix.LiveView.TagEngine.Parser

  @declarations [:callback, :doc, :macrocallback, :moduledoc, :opaque, :spec, :type, :typedoc, :typep]
  @definitions [:def, :defdelegate, :defmacro, :defmacrop, :defp]

  def ast(node, acc, scanner) do
    case scanner.visit.(node, acc) do
      {:ok, acc} -> acc
      :next -> children(node, acc, scanner)
    end
  end

  def heex(source, acc, scanner, file \\ "nofile") do
    source
    |> Parser.parse!(
      file: file,
      tag_handler: Phoenix.LiveView.HTMLEngine,
      skip_macro_components: true,
      strip_eex_comments: true,
      prune_text_after_slots: false
    )
    |> Map.fetch!(:nodes)
    |> Enum.reduce(acc, &node(&1, &2, scanner))
  end

  defp attribute({key, {:expr, expression, _}, _}, {attrs, acc}, scanner) do
    ast = Code.string_to_quoted!(expression)
    {[{key, {:expr, ast}} | attrs], ast(ast, acc, scanner)}
  end

  defp attribute({key, {:string, value, _}, _}, {attrs, acc}, _), do: {[{key, {:string, value}} | attrs], acc}
  defp attribute({key, _, _}, {attrs, acc}, _), do: {[{key, nil} | attrs], acc}

  # Documentation and type declarations name functions without calling them.
  defp children({:@, _, [{kind, _, _}]}, acc, _) when kind in @declarations, do: acc
  defp children({:quote, _, _}, acc, _), do: acc

  defp children({:sigil_H, _, [{:<<>>, _, [source]}, _]}, acc, scanner) when is_binary(source) do
    heex(source, acc, scanner)
  end

  # A definition's head only declares parameters, but its default values are evaluated.
  defp children({kind, _, [head | body]}, acc, scanner) when kind in @definitions do
    acc = head |> defaults() |> Enum.reduce(acc, &ast(&1, &2, scanner))
    ast(body, acc, scanner)
  end

  defp children({_, _, args}, acc, scanner) when is_list(args), do: ast(args, acc, scanner)
  defp children({left, right}, acc, scanner), do: ast(right, ast(left, acc, scanner), scanner)
  defp children([node | nodes], acc, scanner), do: ast(nodes, ast(node, acc, scanner), scanner)
  defp children(_, acc, _), do: acc

  defp defaults({:when, _, [head | _]}), do: defaults(head)
  defp defaults({_, _, args}) when is_list(args), do: for({:\\, _, [_, default]} <- args, do: default)
  defp defaults(_), do: []

  defp node({:block, type, name, attrs, children, _, _}, acc, scanner) do
    Enum.reduce(children, tag(type, name, attrs, acc, scanner), &node(&1, &2, scanner))
  end

  defp node({:self_close, type, name, attrs, _}, acc, scanner), do: tag(type, name, attrs, acc, scanner)

  defp node({type, expression, _}, acc, scanner) when type in [:eex, :body_expr] do
    expression |> Code.string_to_quoted!() |> ast(acc, scanner)
  end

  defp node({:eex_block, expression, clauses, _}, acc, scanner) do
    state = {acc, String.ends_with?(String.trim_trailing(expression), "->")}

    {clauses, {acc, _}} =
      Enum.map_reduce(clauses, state, fn {nodes, expression, _}, {acc, previous_clause?} ->
        clause? = String.ends_with?(String.trim_trailing(expression), "->")
        # The first case/cond clause has no preceding body; empty branches still need nil.
        body = if clause? and not previous_clause?, do: "\n", else: "\nnil\n"
        {[body, expression], {Enum.reduce(nodes, acc, &node(&1, &2, scanner)), clause?}}
      end)

    [expression | clauses] |> IO.iodata_to_binary() |> Code.string_to_quoted!() |> ast(acc, scanner)
  end

  defp node(_, acc, _), do: acc

  defp tag(type, name, attrs, acc, scanner) do
    {attrs, acc} = Enum.reduce(attrs, {[], acc}, &attribute(&1, &2, scanner))
    scanner.tag.(type, name, Enum.reverse(attrs), acc)
  end
end
