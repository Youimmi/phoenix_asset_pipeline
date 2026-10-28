defmodule PhoenixAssetPipeline.ClassNames do
  @moduledoc false

  def allocate(base, class_name, {_, _, next_suffixes} = allocation) do
    allocate(base, class_name, allocation, Map.get(next_suffixes, base, 0))
  end

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
