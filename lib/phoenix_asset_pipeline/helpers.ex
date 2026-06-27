defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc """
  HTML-safe helpers backed by the current asset manifest.

  Import this module in Phoenix HTML contexts to render digested script, style,
  image, source, and SVG sprite paths.
  """

  import Phoenix.HTML, only: [attributes_escape: 1]
  import Phoenix.VerifiedRoutes, only: [static_url: 2]

  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Manifest

  @doc """
  Returns the current manifest digest.
  """
  def asset_digest, do: Manifest.get(:digest)

  @doc false
  def build_class_descriptor({static_class_names, dynamic_class_groups}, classes)
      when is_list(static_class_names) and is_list(dynamic_class_groups) and is_map(classes) do
    static_classes =
      static_class_names
      |> resolve_class_names(classes)
      |> Enum.sort()

    {dynamic_class_groups, dynamic_count} =
      resolve_dynamic_class_groups(dynamic_class_groups, classes, [], 0)

    build_class_values(
      0,
      Bitwise.bsl(1, dynamic_count),
      static_classes,
      dynamic_class_groups,
      [],
      []
    )
  end

  @doc """
  Returns a safe `<img>` tag for a manifest-backed image path.

  The helper rewrites `src` and list-based `srcset` entries to digested URLs.
  It returns `nil` when the image is not present in the manifest.
  """
  def img(path, attrs \\ []) when is_list(attrs) do
    uri = URI.parse(path)
    extname = Path.extname(uri.path)

    with %{path: path} <- Manifest.find(:image_sources, file_path(uri.path, extname)) do
      path = path <> uri_fragment(uri)

      attrs =
        attrs
        |> Keyword.put(:src, src(path))
        |> Keyword.put(:srcset, srcset(attrs[:srcset]))
        |> sorted_attrs()

      {:safe, [?<, "img", attrs, ?/, ?>]}
    end
  end

  @doc false
  def resolve_class({_, _, _} = descriptor_key, descriptor, mask) when is_integer(mask) do
    {strings, _} = resolved_class_descriptor(descriptor_key, descriptor)
    elem(strings, mask)
  end

  @doc false
  def resolve_class_attr({_, _, _} = descriptor_key, descriptor, mask, attr_key)
      when is_integer(mask) and is_atom(attr_key) do
    {_, lists} = resolved_class_descriptor(descriptor_key, descriptor)
    class_attr(lists, mask, attr_key)
  end

  @doc """
  Returns a safe `<script>` tag for a manifest-backed JavaScript asset.
  """
  def script(path, attrs \\ []) when is_list(attrs) do
    extname = ".js"

    with %{integrity: integrity, path: path} <- Manifest.find(:script_tags, file_path(path, extname)) do
      attrs =
        attrs
        |> Keyword.put(:integrity, integrity)
        |> Keyword.put(:src, src(path))
        |> sorted_attrs()

      {:safe, [?<, "script", attrs, ?>, ?<, ?/, "script", ?>]}
    end
  end

  @doc false
  def sorted_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.sort()
    |> attributes_escape()
    |> elem(1)
  end

  @doc """
  Returns a safe `<source>` tag with manifest-backed `srcset` entries.
  """
  def source(attrs \\ []) when is_list(attrs) do
    attrs =
      attrs
      |> Keyword.put(:srcset, srcset(attrs[:srcset]))
      |> sorted_attrs()

    {:safe, [?<, "source", attrs, ?/, ?>]}
  end

  @doc """
  Returns a safe inline `<style>` tag for a manifest-backed CSS asset.
  """
  def style(path, attrs \\ []) when is_list(attrs) do
    extname = ".css"

    with %{content: content} <- Manifest.find(:style_tags, file_path(path, extname)) do
      {:safe, [?<, "style", sorted_attrs(attrs), ?>, content, ?<, ?/, "style", ?>]}
    end
  end

  @doc """
  Returns a digested SVG sprite href while preserving the fragment.
  """
  def svg_sprite_href(path) do
    uri = URI.parse(path)
    extname = Path.extname(uri.path)

    case Manifest.find(:image_sources, file_path(uri.path, extname)) do
      %{path: path} ->
        path <> uri_fragment(uri)

      _ ->
        path
    end
  end

  defp build_class_values(mask, limit, _, _, strings, lists) when mask == limit do
    {strings |> Enum.reverse() |> List.to_tuple(), lists |> Enum.reverse() |> List.to_tuple()}
  end

  defp build_class_values(mask, limit, static_classes, dynamic_class_groups, strings, lists) do
    class_list = class_list_for_mask(static_classes, dynamic_class_groups, mask)

    build_class_values(
      mask + 1,
      limit,
      static_classes,
      dynamic_class_groups,
      [Enum.join(class_list, " ") | strings],
      [class_list | lists]
    )
  end

  defp class_attr(lists, mask, attr_key) do
    case tuple_value(lists, mask, []) do
      [] -> []
      class_list -> [{attr_key, class_list}]
    end
  end

  defp class_list_for_mask(static_classes, dynamic_class_groups, mask) do
    case dynamic_classes_for_mask(dynamic_class_groups, mask, 1, []) do
      [] -> static_classes
      dynamic_classes -> Enum.sort(static_classes ++ dynamic_classes)
    end
  end

  defp dynamic_classes_for_mask([class_group | rest], mask, bit, acc) do
    acc =
      case class_group do
        {:choice, truthy_class_group, falsy_class_group} ->
          if Bitwise.band(mask, bit) == 0,
            do: prepend_all(falsy_class_group, acc),
            else: prepend_all(truthy_class_group, acc)

        class_group ->
          if Bitwise.band(mask, bit) == 0, do: acc, else: prepend_all(class_group, acc)
      end

    dynamic_classes_for_mask(rest, mask, Bitwise.bsl(bit, 1), acc)
  end

  defp dynamic_classes_for_mask([], _, _, acc), do: acc

  defp file_path(path, ""), do: path

  defp file_path(path, extname) do
    if match?("", Path.extname(path)),
      do: path <> extname,
      else: path
  end

  defp prepend_all([item | rest], acc), do: prepend_all(rest, [item | acc])
  defp prepend_all([], acc), do: acc

  defp resolve_class_names(class_names, classes) when map_size(classes) == 0, do: class_names

  defp resolve_class_names(class_names, classes) do
    resolve_class_names(class_names, classes, [])
  end

  defp resolve_class_names([class_name | rest], classes, acc) do
    case Map.get(classes, class_name) do
      nil -> resolve_class_names(rest, classes, acc)
      short_name -> resolve_class_names(rest, classes, [short_name | acc])
    end
  end

  defp resolve_class_names([], _, acc), do: acc

  defp resolve_dynamic_class_groups([class_group | rest], classes, acc, count) do
    resolve_dynamic_class_groups(
      rest,
      classes,
      [resolve_dynamic_class_group(class_group, classes) | acc],
      count + 1
    )
  end

  defp resolve_dynamic_class_groups([], _, acc, count), do: {:lists.reverse(acc), count}

  defp resolve_dynamic_class_group({:choice, truthy_class_group, falsy_class_group}, classes) do
    {:choice, resolve_class_names(truthy_class_group, classes), resolve_class_names(falsy_class_group, classes)}
  end

  defp resolve_dynamic_class_group(class_group, classes) do
    resolve_class_names(class_group, classes)
  end

  defp resolved_class_descriptor(descriptor_key, descriptor) do
    case Manifest.find(:class_descriptors, descriptor_key) do
      nil -> build_class_descriptor(descriptor, Manifest.get(:classes, %{}))
      descriptor -> descriptor
    end
  end

  defp src(path) do
    static_url = static_url(Config.endpoint!(), path)

    if local_static_url?(static_url),
      do: path,
      else: static_url
  end

  defp local_static_url?("http://localhost" <> rest), do: local_static_url_suffix?(rest)
  defp local_static_url?("https://localhost" <> rest), do: local_static_url_suffix?(rest)
  defp local_static_url?(_), do: false

  defp local_static_url_suffix?(""), do: true
  defp local_static_url_suffix?("/" <> _), do: true
  defp local_static_url_suffix?(":" <> _), do: true
  defp local_static_url_suffix?(_), do: false

  defp srcset([_ | _] = srcset) do
    srcset
    |> Enum.flat_map(fn part ->
      part = String.trim(part)
      [url | descriptor] = String.split(part, " ", parts: 2)
      descriptor = if descriptor == [], do: "", else: " " <> hd(descriptor)
      uri = URI.parse(url)
      extname = Path.extname(uri.path)

      case Manifest.find(:image_sources, file_path(uri.path, extname)) do
        %{path: path} ->
          [src(path <> uri_fragment(uri)) <> descriptor]

        _ ->
          []
      end
    end)
    |> Enum.join(",")
  end

  defp srcset(_), do: nil

  defp tuple_value(tuple, index, _) when is_tuple(tuple) and index >= 0 and index < tuple_size(tuple) do
    elem(tuple, index)
  end

  defp tuple_value(_, _, default), do: default

  defp uri_fragment(%URI{fragment: fragment}) when is_binary(fragment), do: "#" <> fragment
  defp uri_fragment(_), do: ""
end
