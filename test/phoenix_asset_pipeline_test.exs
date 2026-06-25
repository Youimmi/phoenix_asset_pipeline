defmodule PhoenixAssetPipelineTest do
  use ExUnit.Case, async: true

  @encoded_data_keys MapSet.new(~w(br deflate gzip raw zstd))

  test "build stores every compressed encoding for static assets" do
    static_dir = Path.join(System.tmp_dir!(), "phoenix_asset_pipeline-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(static_dir, "assets/css"))
    File.mkdir_p!(Path.join(static_dir, "assets/img"))
    File.mkdir_p!(Path.join(static_dir, "assets/js"))
    File.write!(Path.join(static_dir, "assets/css/app.css"), ".btn { color: red; }")
    File.write!(Path.join(static_dir, "assets/img/avatar.png"), "png")
    File.write!(Path.join(static_dir, "assets/js/app.js"), "console.log('ok')")
    File.write!(Path.join(static_dir, "robots.txt"), "User-agent: *\n")

    on_exit(fn -> File.rm_rf!(static_dir) end)

    manifest = PhoenixAssetPipeline.build(static_dir)

    assert_encoded_data!(manifest, :scripts)
    assert_encoded_data!(manifest, :static_files)
    assert_static_etags!(manifest)
    assert_helper_paths!(manifest)
    assert_class_descriptor_keys!(manifest)

    assert %{
             "script-src" => [script_integrity],
             "style-src" => [style_integrity]
           } = manifest.csp_directives

    assert String.starts_with?(script_integrity, "'sha512-")
    assert String.ends_with?(script_integrity, "'")
    assert String.starts_with?(style_integrity, "'sha512-")
    assert String.ends_with?(style_integrity, "'")

    assert [preload] = manifest.early_hints_preloads
    assert String.starts_with?(preload, "/")
    assert String.ends_with?(preload, ".js>; rel=preload; as=script; crossorigin")
  end

  defp assert_encoded_data!(manifest, section) do
    assets = Map.fetch!(manifest, section)

    assert map_size(assets) > 0

    for {_, %{data: data}} <- assets do
      assert MapSet.new(Map.keys(data)) == @encoded_data_keys
    end
  end

  defp assert_static_etags!(manifest) do
    static_files = Map.fetch!(manifest, :static_files)

    for {_, %{data: data}} <- static_files do
      {_, _, raw_etag} = Map.fetch!(data, "raw")
      {_, _, br_etag} = Map.fetch!(data, "br")

      assert raw_etag != br_etag
      assert String.starts_with?(raw_etag, "\"")
      assert String.ends_with?(raw_etag, "\"")
    end
  end

  defp assert_helper_paths!(manifest) do
    assert [{_, %{path: script_path}}] = Map.to_list(manifest.script_tags)
    assert String.starts_with?(script_path, "/")
    assert String.ends_with?(script_path, ".js")

    assert %{path: image_path} = Map.fetch!(manifest.image_sources, "avatar.png")
    assert String.starts_with?(image_path, "/")
    assert String.ends_with?(image_path, ".png")

    assert Enum.all?(manifest.early_hints_preloads, &String.starts_with?(&1, script_path))
  end

  defp assert_class_descriptor_keys!(manifest) do
    class_descriptors = Map.fetch!(manifest, :class_descriptors)

    assert map_size(class_descriptors) > 0

    assert Enum.all?(class_descriptors, fn
             {{module_name, id, hash}, _}
             when is_binary(module_name) and is_integer(id) and is_binary(hash) ->
               true

             _ ->
               false
           end)
  end
end
