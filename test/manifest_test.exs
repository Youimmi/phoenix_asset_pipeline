defmodule PhoenixAssetPipeline.ManifestTest do
  use ExUnit.Case, async: false

  alias PhoenixAssetPipeline.Manifest

  @compile {:no_warn_undefined, {Manifest.Precompiled, :manifest, 0}}

  @tag :tmp_dir
  test "loads a newly saved manifest from a cached code path", %{tmp_dir: directory} do
    module = PhoenixAssetPipeline.Manifest.Precompiled
    File.mkdir_p!(directory)
    assert Code.prepend_path(directory, cache: true)

    on_exit(fn ->
      Code.delete_path(directory)
      :code.delete(module)
      :code.purge(module)
    end)

    refute Code.ensure_loaded?(module)
    path = Path.join(directory, Atom.to_string(module) <> ".beam")
    manifest = %{digest: "test"}

    assert Manifest.save_precompiled!(manifest, path) == path
    assert File.regular?(path)
    assert Code.ensure_loaded?(module)
    assert module.manifest() == manifest
  end
end
