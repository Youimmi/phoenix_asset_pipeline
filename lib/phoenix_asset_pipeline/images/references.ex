defmodule PhoenixAssetPipeline.Images.References do
  @moduledoc false

  alias PhoenixAssetPipeline.HTML.Entities
  alias PhoenixAssetPipeline.HTML.TemplateScanner

  def scan!(paths) do
    paths
    |> Enum.flat_map(fn path ->
      source = File.read!(path)

      try do
        case Path.extname(path) do
          ".heex" -> TemplateScanner.heex(source, [], scanner())
          ".ex" -> source |> Code.string_to_quoted!(file: path) |> TemplateScanner.ast([], scanner())
        end
      rescue
        error -> reraise ArgumentError, [message: "#{path}: #{Exception.message(error)}"], __STACKTRACE__
      end
    end)
    |> Enum.uniq()
  end

  defp collect_image([src, size], refs), do: collect_image([src, size, nil], refs)

  defp collect_image([src, size, variant], refs) when is_binary(src) do
    [{src, dimensions!(size), variant not in [nil, false]} | refs]
  end

  defp collect_image(_, _) do
    raise ArgumentError, "image_attrs requires a literal source and positive literal dimensions"
  end

  defp collect_picture(attrs, refs) do
    {spreads, explicit} = Map.pop(attrs, :root, [])

    {attrs, refs, resolved?} =
      Enum.reduce(Enum.reverse(spreads), {%{}, refs, false}, fn
        {:%{}, _, pairs}, {attrs, refs, resolved?} ->
          {Map.merge(attrs, literal_attributes!(pairs)), refs, resolved?}

        pairs, {attrs, refs, resolved?} when is_list(pairs) ->
          {Map.merge(attrs, literal_attributes!(pairs)), refs, resolved?}

        ast, {attrs, refs, _} ->
          {attrs, collect_spread(ast, refs), true}
      end)

    attrs = Map.merge(attrs, explicit)

    case {attrs, resolved?} do
      {%{"src" => _}, _} ->
        collect_static_picture(attrs, refs)

      {_, false} ->
        raise ArgumentError, "picture source cannot be resolved; use literal attributes or image_attrs calls"

      {_, true} ->
        if Map.has_key?(attrs, "width") or Map.has_key?(attrs, "height") do
          raise ArgumentError, "picture dimensions must be declared in image_attrs without attribute overrides"
        end

        refs
    end
  end

  defp collect_spread({:image_attrs, _, args}, refs), do: collect_image(args, refs)
  defp collect_spread({{:., _, [_, :image_attrs]}, _, args}, refs), do: collect_image(args, refs)

  defp collect_spread({:%{}, _, pairs}, refs), do: collect_static_picture(literal_attributes!(pairs), refs)
  defp collect_spread(pairs, refs) when is_list(pairs), do: collect_static_picture(literal_attributes!(pairs), refs)

  defp collect_spread({:__block__, _, nodes}, refs), do: collect_spread(List.last(nodes), refs)

  defp collect_spread({kind, _, args}, refs) when kind in [:case, :cond] do
    args
    |> List.last()
    |> Keyword.fetch!(:do)
    |> Enum.reduce(refs, fn {:->, _, [_, body]}, refs -> collect_spread(body, refs) end)
  end

  defp collect_spread({kind, _, [_, branches]}, refs) when kind in [:if, :unless] do
    refs = collect_spread(Keyword.fetch!(branches, :do), refs)
    collect_spread(Keyword.get(branches, :else), refs)
  end

  defp collect_spread(_, _) do
    raise ArgumentError, "picture spread cannot be resolved; use literal attributes or image_attrs calls in every branch"
  end

  defp collect_static_picture(%{"src" => src, "width" => width, "height" => height}, refs) when is_binary(src) do
    [{src, dimensions!({number(width), number(height)}), false} | refs]
  end

  defp collect_static_picture(_, _) do
    raise ArgumentError, "picture requires a literal source, width and height"
  end

  defp collect_tag(type, name, attrs, refs) do
    if type in [:local_component, :remote_component] and List.last(String.split(name, ".")) == "picture",
      do: collect_picture(Enum.reduce(attrs, %{}, &put_attribute/2), refs),
      else: refs
  end

  defp dimensions!(height) when is_integer(height) and height > 0, do: {nil, height}

  defp dimensions!({width, height}) when is_integer(width) and width > 0 and is_integer(height) and height > 0 do
    {width, height}
  end

  defp dimensions!(_) do
    raise ArgumentError, "image dimensions must be a positive literal height or {width, height} bounding box"
  end

  defp literal_attributes!(pairs) do
    Enum.reduce(pairs, %{}, fn
      {key, value}, attrs when key in [:src, :width, :height, "src", "width", "height"] ->
        Map.put(attrs, to_string(key), value)

      {key, _}, attrs when is_atom(key) or is_binary(key) ->
        attrs

      _, _ ->
        raise ArgumentError, "picture attribute maps require literal keys"
    end)
  end

  defp number(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _ -> nil
    end
  end

  defp number(value), do: value

  defp put_attribute({:root, {:expr, ast}}, attrs), do: Map.update(attrs, :root, [ast], &[ast | &1])
  defp put_attribute({key, {:expr, ast}}, attrs), do: Map.put(attrs, key, ast)
  defp put_attribute({key, {:string, value}}, attrs), do: Map.put(attrs, key, Entities.decode_attribute(value))
  defp put_attribute({key, nil}, attrs), do: Map.put(attrs, key, nil)

  defp scanner, do: %{tag: &collect_tag/4, visit: &visit/2}

  defp visit({:image_attrs, _, args}, refs) when is_list(args), do: {:ok, collect_image(args, refs)}
  defp visit({{:., _, [_, :image_attrs]}, _, args}, refs) when is_list(args), do: {:ok, collect_image(args, refs)}
  defp visit(_, _), do: :next
end
