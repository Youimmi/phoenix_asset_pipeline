defmodule PhoenixAssetPipeline.HTML.Macros do
  @moduledoc """
  HEEx macros for class extraction, class obfuscation, and static minification.

  Use this module in Phoenix HTML contexts instead of importing it directly:

      use PhoenixAssetPipeline.HTML.Macros
  """

  alias PhoenixAssetPipeline.HTML.ClassAttrs
  alias PhoenixAssetPipeline.HTML.Minifier
  alias PhoenixAssetPipeline.HTML.ModuleClasses

  @fixed_mappings_attribute :phoenix_asset_pipeline_fixed_class_mappings
  @track_mapping_resource PhoenixAssetPipeline.Config.manifest_mode() == :precompiled

  defmacro __before_compile__(env) do
    descriptors =
      env.module
      |> Module.get_attribute(:class_descriptors)
      |> List.wrap()
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.sort_by(&elem(&1, 0))

    fixed_class_mappings = fixed_class_mappings!(env.module)

    quote do
      def class_names, do: @class_names
      def __class_descriptors__, do: unquote(Macro.escape(descriptors))
      def __fixed_class_mappings__, do: unquote(Macro.escape(fixed_class_mappings))
    end
  end

  defmacro __using__(_) do
    ModuleClasses.ensure_prepared!()

    Module.register_attribute(__CALLER__.module, :class_descriptors, accumulate: true)
    Module.register_attribute(__CALLER__.module, :class_names, accumulate: true)

    Module.register_attribute(__CALLER__.module, @fixed_mappings_attribute,
      accumulate: true,
      persist: true
    )

    if @track_mapping_resource do
      Module.put_attribute(__CALLER__.module, :external_resource, ModuleClasses.mapping_path())
    end

    quote do
      import PhoenixAssetPipeline.Helpers
      import unquote(__MODULE__)

      @before_compile unquote(__MODULE__)
    end
  end

  @doc false
  def __class_value_ast__(classes, env) do
    classes = if is_list(classes), do: classes, else: [classes]

    cond do
      literal_class_list?(classes) ->
        class_ast(classes, nil, env, false)

      mixed_literal_and_class_helper_list?(classes) ->
        raise ArgumentError,
              "mixed literal class strings and class helper calls are not supported in class attributes. " <>
                "Wrap literal strings with class(...), or move them into a helper that returns class(...)."

      true ->
        nil
    end
  end

  @doc """
  Declares a class expression that can be extracted into the asset manifest.

  Expressions in functions and templates resolve the current manifest at
  runtime, so a manifest update does not require recompiling the caller.

  At module scope the expression embeds a prepared short class value. The same
  fixed mapping is reserved when CSS is built, which keeps module attributes
  and component attribute defaults minified without a second Elixir
  compilation.
  """
  defmacro class(classes, key \\ :class) when is_atom(key) do
    {classes, attr_key} = class_args(classes, key)
    module_scope? = __CALLER__.function == nil
    prepare_module_scope!(module_scope?, __CALLER__.module)
    class_ast(classes, attr_key, __CALLER__, module_scope?)
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

  defp class_ast(classes, attr_key, env, module_scope?) do
    with {descriptor, conditions} <- class_descriptor(classes, env) do
      if module_scope? do
        fixed_mappings = put_fixed_class_mappings(env.module, descriptor)
        quote_literal_class(descriptor, conditions, attr_key, fixed_mappings)
      else
        descriptor_key = put_class_descriptor(env.module, descriptor_kind(attr_key), descriptor)
        quote_class(descriptor_key, conditions, attr_key)
      end
    end
  end

  defp descriptor_kind(nil), do: :string
  defp descriptor_kind(_), do: :attr

  if !@track_mapping_resource do
    @module_scope_prepared_attribute :phoenix_asset_pipeline_module_scope_prepared

    defp prepare_module_scope!(true, module) do
      if Module.get_attribute(module, @module_scope_prepared_attribute) != true do
        ModuleClasses.prepare!(:stable)
        Module.put_attribute(module, @module_scope_prepared_attribute, true)
      end
    end
  end

  defp prepare_module_scope!(_, _), do: :ok

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
    descriptor
    |> :erlang.term_to_iovec([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
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
    if class_whitespace?(:binary.at(classes, index)) do
      next = skip_class_whitespace(classes, index + 1, size)

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

  defp class_helper_call?({:class, _, _}), do: true

  defp class_helper_call?({name, _, args}) when is_atom(name) and is_list(args) do
    name
    |> to_string()
    |> String.ends_with?("_class")
  end

  defp class_helper_call?({{:., _, [_, name]}, _, args}) when is_atom(name) and is_list(args) do
    name
    |> to_string()
    |> String.ends_with?("_class")
  end

  defp class_helper_call?(_), do: false

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

  defp mixed_literal_and_class_helper_list?(classes) do
    Enum.any?(classes, &literal_class?/1) and Enum.any?(classes, &class_helper_call?/1)
  end

  defp class_whitespace?(byte), do: byte in [?\s, ?\t, ?\n, ?\r, ?\f]

  defp skip_class_whitespace(classes, index, size) when index < size do
    if class_whitespace?(:binary.at(classes, index)) do
      skip_class_whitespace(classes, index + 1, size)
    else
      index
    end
  end

  defp skip_class_whitespace(_, index, _), do: index

  defp prepend_all([item | rest], acc), do: prepend_all(rest, [item | acc])
  defp prepend_all([], acc), do: acc

  defp put_class_descriptor(module, kind, descriptor) do
    key = {kind, descriptor_hash(descriptor)}
    Module.put_attribute(module, :class_descriptors, {key, descriptor})
    key
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

  defp put_fixed_class_mappings(module, {static_class_names, dynamic_class_groups}) do
    class_names = put_dynamic_class_names(dynamic_class_groups, static_class_names)
    fixed_mappings = ModuleClasses.fixed_mappings!(class_names)

    Enum.each(fixed_mappings, fn mapping ->
      Module.put_attribute(module, @fixed_mappings_attribute, mapping)
    end)

    fixed_mappings
  end

  defp fixed_class_mappings!(module) do
    {mappings, _} =
      module
      |> Module.get_attribute(@fixed_mappings_attribute)
      |> List.wrap()
      |> Enum.reduce({%{}, %{}}, fn {class_name, short_name}, {mappings, short_names} ->
        case mappings do
          %{^class_name => other} when other != short_name ->
            raise "module class #{inspect(class_name)} maps both #{inspect(other)} and #{inspect(short_name)}"

          _ ->
            :ok
        end

        case short_names do
          %{^short_name => other} when other != class_name ->
            raise "module class name #{inspect(short_name)} is shared by #{inspect(other)} and #{inspect(class_name)}"

          _ ->
            {Map.put(mappings, class_name, short_name), Map.put(short_names, short_name, class_name)}
        end
      end)

    mappings |> Map.to_list() |> Enum.sort()
  end

  defp put_dynamic_class_names([{:choice, truthy_class_names, falsy_class_names} | rest], class_names) do
    class_names = prepend_all(falsy_class_names, prepend_all(truthy_class_names, class_names))
    put_dynamic_class_names(rest, class_names)
  end

  defp put_dynamic_class_names([group | rest], class_names) do
    put_dynamic_class_names(rest, prepend_all(group, class_names))
  end

  defp put_dynamic_class_names([], class_names), do: class_names

  defp quote_literal_class(descriptor, conditions, attr_key, fixed_mappings) do
    literal_descriptor =
      PhoenixAssetPipeline.Helpers.build_class_descriptor(descriptor_kind(attr_key), descriptor, fixed_mappings)

    quote do
      PhoenixAssetPipeline.Helpers.resolve_literal_class(
        unquote(Macro.escape(literal_descriptor)),
        unquote(condition_mask_ast(conditions)),
        unquote(attr_key)
      )
    end
  end

  defp quote_class(descriptor_key, conditions, nil) do
    quote do
      PhoenixAssetPipeline.Helpers.resolve_class(
        unquote(Macro.escape(descriptor_key)),
        unquote(condition_mask_ast(conditions))
      )
    end
  end

  defp quote_class(descriptor_key, conditions, attr_key) do
    quote do
      PhoenixAssetPipeline.Helpers.resolve_class_attr(
        unquote(Macro.escape(descriptor_key)),
        unquote(condition_mask_ast(conditions)),
        unquote(attr_key)
      )
    end
  end
end
