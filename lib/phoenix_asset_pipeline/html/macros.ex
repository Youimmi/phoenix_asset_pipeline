defmodule PhoenixAssetPipeline.HTML.Macros do
  @moduledoc """
  HEEx macros for class extraction, class obfuscation, and static minification.

  Use this module in Phoenix HTML contexts instead of importing it directly:

      use PhoenixAssetPipeline.HTML.Macros
  """

  alias Mix.Tasks.Compile.PhoenixAssetPipeline, as: PhoenixAssetPipelineCompiler
  alias PhoenixAssetPipeline.HTML.ClassAttrs
  alias PhoenixAssetPipeline.HTML.Minifier

  def __after_compile__(_, _) do
    if Code.ensure_loaded?(PhoenixAssetPipelineCompiler) do
      PhoenixAssetPipelineCompiler.after_compile()
    else
      if Process.whereis(PhoenixAssetPipeline.Manifest), do: PhoenixAssetPipeline.run()
    end

    :ok
  end

  defmacro __before_compile__(env) do
    descriptors =
      env.module
      |> Module.get_attribute(:class_descriptors)
      |> List.wrap()
      |> Enum.sort_by(&elem(&1, 0))

    quote do
      def class_names, do: @class_names
      def __class_descriptors__, do: unquote(Macro.escape(descriptors))
    end
  end

  defmacro __using__(_) do
    quote do
      import PhoenixAssetPipeline.Helpers
      import unquote(__MODULE__)

      @after_compile unquote(__MODULE__)
      @before_compile unquote(__MODULE__)
      Module.register_attribute(__MODULE__, :class_descriptor_count, accumulate: false)
      Module.register_attribute(__MODULE__, :class_descriptors, accumulate: true)
      Module.register_attribute(__MODULE__, :class_names, accumulate: true)
    end
  end

  @doc false
  def __class_value_ast__(classes, env) do
    classes = if is_list(classes), do: classes, else: [classes]

    if literal_class_list?(classes),
      do: class_ast(classes, nil, env)
  end

  @doc """
  Declares a class expression that can be extracted into the asset manifest.
  """
  defmacro class(classes, key \\ :class) when is_atom(key) do
    {classes, attr_key} = class_args(classes, key)

    class_ast(classes, attr_key, __CALLER__)
  end

  @doc """
  Embeds templates using `PhoenixAssetPipeline.HTML.Engine` for HEEx files.
  """
  defmacro embed_templates(pattern, opts \\ []) do
    engines =
      Phoenix.Template.engines()
      |> Map.put(:heex, PhoenixAssetPipeline.HTML.Engine)
      |> Macro.escape()

    quote bind_quoted: [engines: engines, opts: opts, pattern: pattern] do
      Phoenix.Template.compile_all(
        &Phoenix.Component.__embed__(&1, opts[:suffix]),
        Path.expand(opts[:root] || __DIR__, __DIR__),
        pattern,
        engines
      )
    end
  end

  @doc """
  Compiles HEEx with class extraction and static minification.

  Use the `noformat` modifier to skip static HTML minification for a template.
  """
  defmacro sigil_H({:<<>>, meta, [expr]}, modifiers)
           when modifiers == [] or modifiers == ~c"noformat" do
    if not Macro.Env.has_var?(__CALLER__, {:assigns, nil}) do
      raise "~H requires a variable named \"assigns\" to exist and be set to a map"
    end

    expr
    |> ClassAttrs.compile(
      file: __CALLER__.file,
      line: __CALLER__.line + 1,
      caller: __CALLER__,
      indentation: meta[:indentation] || 0,
      tag_handler: Phoenix.LiveView.HTMLEngine
    )
    |> Minifier.minify_rendered_static()
  end

  defp class_args(classes, key) when is_list(classes), do: {classes, key}
  defp class_args(classes, _), do: {[classes], nil}

  defp class_ast(classes, attr_key, env) do
    with {descriptor, conditions} <- class_descriptor(classes, env) do
      {id, descriptor_hash} = put_class_descriptor(env.module, descriptor)
      descriptor_key = {Atom.to_string(env.module), id, descriptor_hash}
      quote_class(descriptor_key, descriptor, conditions, attr_key)
    end
  end

  defp class_condition(true), do: true
  defp class_condition({_, _, _} = condition), do: condition
  defp class_condition(_), do: :skip

  defp choice_condition(true), do: true
  defp choice_condition(value) when value in [false, nil], do: false
  defp choice_condition({_, _, _} = condition), do: condition
  defp choice_condition(_), do: :skip

  defp class_descriptor(classes, env) do
    stacktrace = Macro.Env.stacktrace(env)

    {static_class_names, dynamic_class_groups, conditions, _, duplicates, count} =
      Enum.reduce(
        classes,
        {[], [], [], MapSet.new(), MapSet.new(), 0},
        &handle_class(&1, env.module, stacktrace, &2)
      )

    with [_ | _] = duplicates <- MapSet.to_list(duplicates) do
      IO.warn("Remove duplicates: #{inspect(Enum.join(duplicates, ", "))}", stacktrace)
    end

    if count == 0 do
      nil
    else
      {
        {Enum.reverse(static_class_names), Enum.reverse(dynamic_class_groups)},
        Enum.reverse(conditions)
      }
    end
  end

  defp condition_mask_ast(conditions), do: condition_mask_ast(conditions, 0, 0)

  defp condition_mask_ast([condition | rest], index, mask) do
    bit = Bitwise.bsl(1, index)

    condition_mask_ast(
      rest,
      index + 1,
      quote do
        unquote(mask) + if(unquote(condition), do: unquote(bit), else: 0)
      end
    )
  end

  defp condition_mask_ast([], _, mask), do: mask

  defp descriptor_hash(descriptor) do
    :crypto.hash(:sha256, :erlang.term_to_binary(descriptor))
  end

  defp handle_class({:{}, _, [truthy_classes, falsy_classes, condition]}, module, stacktrace, acc) do
    handle_class({truthy_classes, falsy_classes, condition}, module, stacktrace, acc)
  end

  defp handle_class({truthy_classes, falsy_classes, condition}, module, stacktrace, acc) do
    truthy_class_group = class_group(truthy_classes)
    falsy_class_group = class_group(falsy_classes)

    handle_choice_class(
      truthy_class_group,
      falsy_class_group,
      choice_condition(condition),
      module,
      stacktrace,
      acc
    )
  end

  defp handle_class({classes, condition}, module, stacktrace, acc) do
    classes
    |> class_group()
    |> handle_conditional_class(class_condition(condition), module, stacktrace, acc)
  end

  defp handle_class(value, _, _, acc) when value in [false, nil], do: acc

  defp handle_class(classes, module, stacktrace, acc) do
    classes
    |> class_group()
    |> handle_conditional_class(true, module, stacktrace, acc)
  end

  defp handle_conditional_class(
         {:ok, class_list, extra_whitespace?},
         condition,
         module,
         stacktrace,
         {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}
       ) do
    if extra_whitespace? do
      IO.warn("Remove extra whitespaces", stacktrace)
    end

    cond do
      class_list == [] ->
        {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}

      condition == :skip ->
        {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}

      true ->
        {seen, duplicates} = put_class_names(class_list, module, seen, duplicates)

        if condition == true do
          {
            prepend_all(class_list, static_class_names),
            dynamic_class_groups,
            conditions,
            seen,
            duplicates,
            count + 1
          }
        else
          {
            static_class_names,
            [class_list | dynamic_class_groups],
            [condition | conditions],
            seen,
            duplicates,
            count + 1
          }
        end
    end
  end

  defp handle_conditional_class(:error, _, _, stacktrace, acc) do
    IO.warn(
      "Invalid class. Expected a binary, a list of binaries, or a conditional tuple",
      stacktrace
    )

    acc
  end

  defp handle_choice_class(
         {:ok, truthy_class_list, truthy_extra_whitespace?},
         {:ok, falsy_class_list, falsy_extra_whitespace?},
         condition,
         module,
         stacktrace,
         {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}
       ) do
    if truthy_extra_whitespace? or falsy_extra_whitespace? do
      IO.warn("Remove extra whitespaces", stacktrace)
    end

    cond do
      truthy_class_list == [] and falsy_class_list == [] ->
        {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}

      condition == :skip ->
        {static_class_names, dynamic_class_groups, conditions, seen, duplicates, count}

      condition == true ->
        {seen, duplicates} = put_class_names(truthy_class_list, module, seen, duplicates)

        {
          prepend_all(truthy_class_list, static_class_names),
          dynamic_class_groups,
          conditions,
          seen,
          duplicates,
          count + 1
        }

      condition == false ->
        {seen, duplicates} = put_class_names(falsy_class_list, module, seen, duplicates)

        {
          prepend_all(falsy_class_list, static_class_names),
          dynamic_class_groups,
          conditions,
          seen,
          duplicates,
          count + 1
        }

      true ->
        class_list = truthy_class_list ++ falsy_class_list
        {seen, duplicates} = put_class_names(class_list, module, seen, duplicates)

        {
          static_class_names,
          [{:choice, truthy_class_list, falsy_class_list} | dynamic_class_groups],
          [condition | conditions],
          seen,
          duplicates,
          count + 1
        }
    end
  end

  defp handle_choice_class(:error, _, _, _, stacktrace, acc) do
    IO.warn("Invalid choice class. Expected binaries or lists of binaries", stacktrace)
    acc
  end

  defp handle_choice_class(_, :error, _, _, stacktrace, acc) do
    IO.warn("Invalid choice class. Expected binaries or lists of binaries", stacktrace)
    acc
  end

  defp class_list(<<>>), do: {[], true}

  defp class_list(classes) do
    class_list(classes, 0, 0, byte_size(classes), [], false)
  end

  defp class_list(classes, index, start, size, acc, extra_whitespace?) when index < size do
    if :binary.at(classes, index) == ?\s do
      next = skip_space_bytes(classes, index + 1, size)

      acc =
        if index == start,
          do: acc,
          else: [binary_part(classes, start, index - start) | acc]

      extra_whitespace? =
        extra_whitespace? or index == start or next > index + 1 or next == size

      class_list(classes, next, next, size, acc, extra_whitespace?)
    else
      class_list(classes, index + 1, start, size, acc, extra_whitespace?)
    end
  end

  defp class_list(classes, size, start, size, acc, extra_whitespace?) do
    class_list_done(classes, start, size, acc, extra_whitespace?)
  end

  defp class_list_done(_, size, size, acc, extra_whitespace?) do
    {:lists.reverse(acc), extra_whitespace?}
  end

  defp class_list_done(classes, start, size, acc, extra_whitespace?) do
    {:lists.reverse([binary_part(classes, start, size - start) | acc]), extra_whitespace?}
  end

  defp class_group(value) when value in [false, nil], do: {:ok, [], false}

  defp class_group(<<classes::binary>>) do
    {class_list, extra_whitespace?} = class_list(classes)
    {:ok, class_list, extra_whitespace?}
  end

  defp class_group(classes) when is_list(classes) do
    classes
    |> Enum.reduce_while({[], false}, fn class, {acc, extra_whitespace?} ->
      case class_group(class) do
        {:ok, class_list, extra?} ->
          {:cont, {prepend_all(class_list, acc), extra_whitespace? or extra?}}

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {class_list, extra_whitespace?} -> {:ok, :lists.reverse(class_list), extra_whitespace?}
      :error -> :error
    end
  end

  defp class_group(_), do: :error

  defp literal_class?({:{}, _, [truthy_classes, falsy_classes, _]}) do
    literal_class_group?(truthy_classes) and literal_class_group?(falsy_classes)
  end

  defp literal_class?({truthy_classes, falsy_classes, _}) do
    literal_class_group?(truthy_classes) and literal_class_group?(falsy_classes)
  end

  defp literal_class?({classes, _}), do: literal_class_group?(classes)
  defp literal_class?(classes), do: literal_class_group?(classes)

  defp literal_class_group?(value) when value in [false, nil], do: true
  defp literal_class_group?(classes) when is_binary(classes), do: true

  defp literal_class_group?(classes) when is_list(classes) do
    Enum.all?(classes, &literal_class_group?/1)
  end

  defp literal_class_group?(_), do: false

  defp literal_class_list?([class | rest]), do: literal_class?(class) and literal_class_list?(rest)

  defp literal_class_list?([]), do: true

  defp skip_space_bytes(classes, index, size) when index < size do
    if :binary.at(classes, index) == ?\s do
      skip_space_bytes(classes, index + 1, size)
    else
      index
    end
  end

  defp skip_space_bytes(_, index, _), do: index

  defp prepend_all([item | rest], acc), do: prepend_all(rest, [item | acc])
  defp prepend_all([], acc), do: acc

  defp put_class_descriptor(module, descriptor) do
    id = Module.get_attribute(module, :class_descriptor_count) || 0
    descriptor_hash = descriptor_hash(descriptor)

    Module.put_attribute(module, :class_descriptor_count, id + 1)
    Module.put_attribute(module, :class_descriptors, {id, descriptor_hash, descriptor})

    {id, descriptor_hash}
  end

  defp put_class_names([class_name | rest], module, seen, duplicates) do
    Module.put_attribute(module, :class_names, class_name)

    duplicates =
      if MapSet.member?(seen, class_name),
        do: MapSet.put(duplicates, class_name),
        else: duplicates

    seen = MapSet.put(seen, class_name)

    put_class_names(rest, module, seen, duplicates)
  end

  defp put_class_names([], _, seen, duplicates), do: {seen, duplicates}

  defp quote_class(descriptor_key, descriptor, conditions, nil) do
    quote do
      PhoenixAssetPipeline.Helpers.resolve_class(
        unquote(Macro.escape(descriptor_key)),
        unquote(Macro.escape(descriptor)),
        unquote(condition_mask_ast(conditions))
      )
    end
  end

  defp quote_class(descriptor_key, descriptor, conditions, attr_key) do
    quote do
      PhoenixAssetPipeline.Helpers.resolve_class_attr(
        unquote(Macro.escape(descriptor_key)),
        unquote(Macro.escape(descriptor)),
        unquote(condition_mask_ast(conditions)),
        unquote(attr_key)
      )
    end
  end
end
