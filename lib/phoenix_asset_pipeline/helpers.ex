defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc """
  HTML-safe helpers backed by the current asset manifest.

  Import this module in Phoenix HTML contexts to render digested script, style,
  image, source, and SVG sprite paths.
  """

  import Phoenix.HTML, only: [attributes_escape: 1]

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest

  @precomputed_class_condition_limit 6
  @url_cache_missing :__phoenix_asset_pipeline_url_cache_missing__

  @doc """
  Returns the current manifest digest.
  """
  def asset_digest, do: Manifest.get(:digest)

  @doc false
  def build_class_descriptor(kind, {static_class_names, dynamic_class_groups}, classes)
      when kind in [:string, :attr] and is_list(static_class_names) and is_list(dynamic_class_groups) do
    static_classes =
      static_class_names
      |> resolve_class_names(classes)
      |> Enum.sort()

    {dynamic_class_groups, dynamic_count} =
      resolve_dynamic_class_groups(dynamic_class_groups, classes, [], 0)

    if dynamic_count <= @precomputed_class_condition_limit do
      {:precomputed,
       build_class_values(
         kind,
         0,
         Bitwise.bsl(1, dynamic_count),
         static_classes,
         dynamic_class_groups,
         []
       )}
    else
      {:compact, compact_class_entries(static_classes, dynamic_class_groups)}
    end
  end

  @doc false
  def build_class_descriptors(template_records, classes) when is_list(template_records) and is_map(classes) do
    template_records
    |> Enum.flat_map(&elem(&1, 2))
    |> Enum.reduce(%{}, fn {{kind, _} = key, descriptor}, descriptors ->
      Map.put_new_lazy(descriptors, key, fn -> build_class_descriptor(kind, descriptor, classes) end)
    end)
  end

  @doc false
  def escape_attrs(attrs) when is_list(attrs) do
    attrs
    |> attributes_escape()
    |> elem(1)
  end

  @doc """
  Returns a safe `<img>` tag for a manifest-backed image path.

  The helper rewrites `src` and the `srcset` entries, given as a list or a
  comma-separated string, to digested URLs.
  """
  def img(path, attrs \\ []) when is_list(attrs) do
    attrs = escape_attrs([src: image_src(path), srcset: srcset(attrs[:srcset])] ++ Keyword.drop(attrs, [:src, :srcset]))

    {:safe, [?<, "img", attrs, ?/, ?>]}
  end

  @doc false
  def resolve_class({:string, hash} = descriptor_key, mask) when is_binary(hash) do
    resolve_literal_class(find!(:class_descriptors, descriptor_key), mask, nil)
  end

  @doc false
  def resolve_class_attr({:attr, hash} = descriptor_key, mask, attr_key) when is_binary(hash) do
    resolve_literal_class(find!(:class_descriptors, descriptor_key), mask, attr_key)
  end

  @doc false
  def resolve_literal_class({:precomputed, values}, mask, nil) when is_tuple(values) and is_integer(mask) do
    elem(values, mask)
  end

  def resolve_literal_class({:precomputed, values}, mask, attr_key)
      when is_tuple(values) and is_integer(mask) and is_atom(attr_key) do
    values
    |> elem(mask)
    |> class_attr(attr_key)
  end

  def resolve_literal_class({:compact, entries}, mask, nil) when is_list(entries) and is_integer(mask) do
    entries
    |> compact_class_list(mask)
    |> Enum.join(" ")
  end

  def resolve_literal_class({:compact, entries}, mask, attr_key)
      when is_list(entries) and is_integer(mask) and is_atom(attr_key) do
    entries
    |> compact_class_list(mask)
    |> class_attr(attr_key)
  end

  @doc """
  Returns a safe `<script>` tag for a manifest-backed JavaScript asset.
  """
  def script(path, attrs \\ []) when is_list(attrs) do
    %{integrity: integrity, path: path} = script_tag!(path)

    attrs =
      [type: "module", crossorigin: "anonymous", integrity: integrity, src: src(path, "")]
      |> Kernel.++(Keyword.drop(attrs, [:type, :crossorigin, :integrity, :src]))
      |> escape_attrs()

    {:safe, [?<, "script", attrs, ?>, ?<, ?/, "script", ?>]}
  end

  @doc false
  def script_tag!(path), do: find!(:script_tags, file_path(path, ".js"))

  @doc """
  Returns a safe `<source>` tag with manifest-backed `srcset` entries.
  """
  def source(attrs \\ []) when is_list(attrs) do
    attrs =
      [srcset: srcset(attrs[:srcset])]
      |> Kernel.++(Keyword.delete(attrs, :srcset))
      |> escape_attrs()

    {:safe, [?<, "source", attrs, ?/, ?>]}
  end

  @doc """
  Returns a safe inline `<style>` tag for a manifest-backed CSS asset.
  """
  def style(path, attrs \\ []) when is_list(attrs) do
    extname = ".css"
    %{content: content} = find!(:style_tags, file_path(path, extname))

    {:safe, [?<, "style", escape_attrs(attrs), ?>, content, ?<, ?/, "style", ?>]}
  end

  @doc """
  Returns a digested SVG sprite href while preserving the fragment.
  """
  def svg_sprite_href(path) do
    {source_path, fragment} = asset_path(path)
    path = find!(:image_sources, source_path).path
    endpoint = Config.endpoint()

    # `<use>` cannot load cross-origin sprites, so the href takes the application's path prefix,
    # not the static URL's. Only a running endpoint has a path prefix to apply.
    if endpoint && Process.whereis(endpoint),
      do: endpoint.path(path) <> fragment,
      else: path <> fragment
  end

  defp asset_path(path) do
    case :binary.match(path, ["://", "?", "#"]) do
      :nomatch -> {path, ""}
      _ -> uri_path(URI.parse(path))
    end
  end

  defp asset_url(endpoint, static_url, path) do
    if local_static_url?(static_url),
      do: endpoint.static_path(path),
      else: static_url <> endpoint.static_path(path)
  end

  defp build_class_values(_, mask, limit, _, _, values) when mask == limit do
    values |> :lists.reverse() |> List.to_tuple()
  end

  defp build_class_values(kind, mask, limit, static_classes, dynamic_class_groups, values) do
    class_list = class_list_for_mask(static_classes, dynamic_class_groups, mask)

    build_class_values(
      kind,
      mask + 1,
      limit,
      static_classes,
      dynamic_class_groups,
      [class_value(kind, class_list) | values]
    )
  end

  defp cache_asset_urls(key, {digest, static_url, static_path}, endpoint) do
    urls =
      :image_sources
      |> Manifest.get(%{})
      |> put_asset_urls(%{}, endpoint, static_url)

    urls =
      :script_tags
      |> Manifest.get(%{})
      |> put_asset_urls(urls, endpoint, static_url)

    :persistent_term.put(key, {digest, static_url, static_path, urls})
    urls
  end

  defp class_attr([], _), do: []
  defp class_attr(class_list, attr_key), do: [{attr_key, class_list}]

  defp class_condition_matches?(0, _), do: true
  defp class_condition_matches?(condition, mask) when condition > 0, do: Bitwise.band(mask, condition) != 0
  defp class_condition_matches?(condition, mask), do: Bitwise.band(mask, -condition) == 0

  defp class_list_for_mask(static_classes, dynamic_class_groups, mask) do
    case dynamic_classes_for_mask(dynamic_class_groups, mask, 1, []) do
      [] -> static_classes
      dynamic_classes -> Enum.sort(static_classes ++ dynamic_classes)
    end
  end

  defp class_value(:string, class_list), do: Enum.join(class_list, " ")
  defp class_value(:attr, class_list), do: class_list

  defp compact_class_entries(static_classes, dynamic_class_groups) do
    entries = Enum.reduce(static_classes, [], &[{&1, 0} | &2])

    {entries, _} =
      Enum.reduce(dynamic_class_groups, {entries, 1}, fn class_group, {entries, bit} ->
        {compact_class_group(class_group, bit, entries), Bitwise.bsl(bit, 1)}
      end)

    Enum.sort_by(entries, &elem(&1, 0))
  end

  defp compact_class_group({:choice, truthy_classes, falsy_classes}, bit, entries) do
    entries
    |> prepend_class_conditions(truthy_classes, bit)
    |> prepend_class_conditions(falsy_classes, -bit)
  end

  defp compact_class_group(class_group, bit, entries) do
    prepend_class_conditions(entries, class_group, bit)
  end

  defp compact_class_list(entries, mask) do
    compact_class_list(entries, mask, [])
  end

  defp compact_class_list([{class_name, condition} | entries], mask, classes) do
    classes =
      if class_condition_matches?(condition, mask),
        do: [class_name | classes],
        else: classes

    compact_class_list(entries, mask, classes)
  end

  defp compact_class_list([], _, classes), do: :lists.reverse(classes)

  defp dynamic_classes_for_mask([class_group | rest], mask, bit, acc) do
    acc =
      case class_group do
        {:choice, truthy_class_group, falsy_class_group} ->
          if Bitwise.band(mask, bit) == 0,
            do: :lists.reverse(falsy_class_group, acc),
            else: :lists.reverse(truthy_class_group, acc)

        class_group ->
          if Bitwise.band(mask, bit) == 0, do: acc, else: :lists.reverse(class_group, acc)
      end

    dynamic_classes_for_mask(rest, mask, Bitwise.bsl(bit, 1), acc)
  end

  defp dynamic_classes_for_mask([], _, _, acc), do: acc

  defp file_path(path, extname) do
    if String.ends_with?(path, extname), do: path, else: path <> extname
  end

  defp find!(section, key) do
    Manifest.find(section, key) ||
      raise ArgumentError, "missing asset #{inspect(key)} in manifest section #{inspect(section)}"
  end

  defp image_src(path) do
    {source_path, fragment} = asset_path(path)

    src(find!(:image_sources, source_path).path, fragment)
  end

  defp local_static_url?("http://localhost" <> rest), do: local_static_url_suffix?(rest)
  defp local_static_url?("https://localhost" <> rest), do: local_static_url_suffix?(rest)
  defp local_static_url?(_), do: false

  defp local_static_url_suffix?(""), do: true
  defp local_static_url_suffix?("/" <> _), do: true
  defp local_static_url_suffix?(":" <> _), do: true
  defp local_static_url_suffix?(_), do: false

  defp prepend_class_conditions(entries, [class_name | class_names], condition) do
    prepend_class_conditions([{class_name, condition} | entries], class_names, condition)
  end

  defp prepend_class_conditions(entries, [], _), do: entries

  defp put_asset_urls(entries, urls, endpoint, static_url) do
    Enum.reduce(entries, urls, fn {_, %{path: path}}, urls ->
      Map.put(urls, path, asset_url(endpoint, static_url, path))
    end)
  end

  defp resolve_class_names(class_names, classes) do
    resolve_class_names(class_names, classes, [])
  end

  defp resolve_class_names([class_name | rest], classes, acc) do
    resolve_class_names(rest, classes, [Map.fetch!(classes, class_name) | acc])
  end

  defp resolve_class_names([], _, acc), do: acc

  defp resolve_dynamic_class_group({:choice, truthy_class_group, falsy_class_group}, classes) do
    {:choice, resolve_class_names(truthy_class_group, classes), resolve_class_names(falsy_class_group, classes)}
  end

  defp resolve_dynamic_class_group(class_group, classes) do
    resolve_class_names(class_group, classes)
  end

  defp resolve_dynamic_class_groups([class_group | rest], classes, acc, count) do
    resolve_dynamic_class_groups(
      rest,
      classes,
      [resolve_dynamic_class_group(class_group, classes) | acc],
      count + 1
    )
  end

  defp resolve_dynamic_class_groups([], _, acc, count), do: {:lists.reverse(acc), count}

  defp src(path, fragment) do
    endpoint = Config.endpoint!()
    static_url = endpoint.static_url()
    # The path prefix can change with the endpoint configuration while the origin stays the same.
    static_path = endpoint.static_path("/")
    digest = Manifest.get(:digest)
    key = {__MODULE__, :asset_urls, endpoint}

    urls =
      case :persistent_term.get(key, @url_cache_missing) do
        {^digest, ^static_url, ^static_path, urls} -> urls
        _ -> cache_asset_urls(key, {digest, static_url, static_path}, endpoint)
      end

    # Without a manifest snapshot the path can belong to a generation a rebuild has just replaced.
    case urls do
      %{^path => url} -> url <> fragment
      _ -> asset_url(endpoint, static_url, path) <> fragment
    end
  end

  defp srcset(srcset) when is_binary(srcset), do: srcset |> String.split(",", trim: true) |> srcset()

  defp srcset([_ | _] = srcset) do
    srcset
    |> Enum.reduce([], fn part, acc ->
      {url, descriptor} = part |> String.trim() |> srcset_part()

      case acc do
        [] -> [image_src(url), descriptor]
        _ -> [acc, ?,, image_src(url), descriptor]
      end
    end)
    |> IO.iodata_to_binary()
  end

  defp srcset(srcset) when srcset in [nil, []], do: nil

  defp srcset_part(part) do
    case :binary.match(part, [" ", "\t"]) do
      :nomatch -> {part, ""}
      {index, 1} -> {binary_part(part, 0, index), binary_part(part, index, byte_size(part) - index)}
    end
  end

  defp uri_path(%URI{fragment: fragment, path: path}) when is_binary(fragment), do: {path, "#" <> fragment}
  defp uri_path(%URI{path: path}), do: {path, ""}
end
