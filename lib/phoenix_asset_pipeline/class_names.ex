defmodule PhoenixAssetPipeline.ClassNames do
  @moduledoc false

  @whitespace [" ", "\t", "\n", "\r", "\f"]

  def allocate(base, class_name, {_, _, next_suffixes} = allocation) do
    allocate(base, class_name, allocation, Map.get(next_suffixes, base, 0))
  end

  def literal?(value) when value in [false, nil] or is_binary(value), do: true
  def literal?(values) when is_list(values), do: Enum.all?(values, &literal?/1)
  def literal?(_), do: false

  def new(mappings), do: {mappings, reverse!(mappings), %{}}

  def prefix(class_name), do: class_name |> AnyAscii.transliterate() |> prefix_char()

  def reverse!(mappings) do
    Enum.reduce(mappings, %{}, fn {class_name, short_name}, short_names ->
      case short_names do
        %{^short_name => other} ->
          raise "fixed class name #{inspect(short_name)} is shared by #{inspect(other)} and #{inspect(class_name)}"

        _ ->
          Map.put(short_names, short_name, class_name)
      end
    end)
  end

  # Returns the class tokens and whether the string holds anything but single separators.
  def split(classes) do
    class_list = :binary.split(classes, @whitespace, [:global, :trim_all])
    {class_list, byte_size(classes) != :erlang.iolist_size(class_list) + length(class_list) - 1}
  end

  def variant(class_name) do
    case :binary.split(class_name, ":") do
      [variant, utility] when utility != "" -> {variant, utility}
      _ -> :error
    end
  end

  defp allocate(base, class_name, {classes, short_names, next_suffixes} = allocation, count) do
    candidate = if count == 0, do: base, else: base <> Integer.to_string(count)

    if Map.has_key?(short_names, candidate) do
      allocate(base, class_name, allocation, count + 1)
    else
      {candidate,
       {Map.put(classes, class_name, candidate), Map.put(short_names, candidate, class_name),
        Map.put(next_suffixes, base, count + 1)}}
    end
  end

  defp prefix_char([char | _]) when char in ?a..?z, do: <<char>>
  defp prefix_char([char | _]) when char in ?A..?Z, do: <<char + 32>>
  defp prefix_char([_ | rest]), do: prefix_char(rest)
  defp prefix_char(_), do: "c"
end
