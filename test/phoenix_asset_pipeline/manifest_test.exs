defmodule PhoenixAssetPipeline.ManifestTest do
  use ExUnit.Case, async: true

  alias PhoenixAssetPipeline.Manifest

  test "accepts current cached manifest schema" do
    assert Manifest.valid?(valid_manifest())
  end

  test "rejects previous cached manifest image and script schema" do
    manifest = valid_manifest()

    refute Manifest.valid?(%{manifest | image_sources: %{"app.svg" => %{digest: "digest"}}})

    refute Manifest.valid?(%{
             manifest
             | script_tags: %{
                 "app.js" => %{digest: "digest", integrity: "sha512-digest"}
               }
           })
  end

  test "rejects previous cached manifest static data schema" do
    refute Manifest.valid?(%{
             valid_manifest()
             | static_files: %{
                 "robots.txt" => %{
                   data: %{
                     "raw" => {"User-agent: *\n", 14}
                   }
                 }
               }
           })
  end

  test "rejects cached manifest static data without all encodings" do
    refute Manifest.valid?(%{
             valid_manifest()
             | static_files: %{
                 "robots.txt" => %{
                   data: %{
                     "raw" => {"User-agent: *\n", 14, ~s("raw-etag")},
                     "br" => {"br", 2, ~s("br-etag")}
                   }
                 }
               }
           })
  end

  test "rejects cached manifest digested assets without current data schema" do
    refute Manifest.valid?(%{
             valid_manifest()
             | scripts: %{
                 "digest.js" => %{
                   content_type: "application/javascript",
                   data: %{
                     "raw" => {"console.log('ok')", 17}
                   },
                   digest: "digest"
                 }
               }
           })

    refute Manifest.valid?(%{
             valid_manifest()
             | images: %{
                 "digest.svg" => %{
                   content_type: "image/svg+xml",
                   data: %{
                     "raw" => {"<svg></svg>", 11, ~s("raw-etag")},
                     "br" => {"br", 2, ~s("br-etag")},
                     "deflate" => {"deflate", 7, ~s("deflate-etag")},
                     "gzip" => {"gzip", 4, ~s("gzip-etag")},
                     "zstd" => {"zstd", 4, ~s("zstd-etag")}
                   },
                   digest: "digest"
                 }
               }
           })
  end

  test "rejects cached manifest without runtime metadata" do
    manifest = valid_manifest()

    refute Manifest.valid?(Map.delete(manifest, :digest))
    refute Manifest.valid?(Map.delete(manifest, :style_tags))

    refute Manifest.valid?(%{manifest | classes: %{"base" => 1}})

    refute Manifest.valid?(%{
             manifest
             | class_descriptors: %{
                 {module_name(), 0, "hash"} => {{"a"}, {["a", 1]}}
               }
           })

    refute Manifest.valid?(%{
             manifest
             | class_descriptors: %{
                 {module_name(), 0, "hash"} => {{}, {}}
               }
           })

    refute Manifest.valid?(%{
             manifest
             | class_descriptors: %{
                 {__MODULE__, 0, "hash"} => {{"a"}, {["a"]}}
               }
           })

    refute Manifest.valid?(%{
             manifest
             | style_tags: %{
                 "app.css" => %{content: ".a{}", digest: "digest"}
               }
           })

    refute Manifest.valid?(%{
             manifest
             | csp_directives: %{"script-src" => ["'sha512-script'"]}
           })

    refute Manifest.valid?(%{manifest | early_hints_preloads: [123]})
    refute Manifest.valid?(%{manifest | signature: 123})
    refute Manifest.valid?(%{manifest | static_signature: 123})
  end

  defp valid_manifest do
    %{
      class_descriptors: %{
        {module_name(), 0, "hash"} => {{"a b", "a c"}, {["a", "b"], ["a", "c"]}}
      },
      classes: %{
        "base" => "a"
      },
      csp_directives: %{
        "script-src" => ["'sha512-script'"],
        "style-src" => ["'sha512-style'"]
      },
      digest: "asset-digest",
      early_hints_preloads: ["/digest.js>; rel=preload; as=script; crossorigin"],
      images: %{
        "digest.svg" => %{
          content_type: "image/svg+xml",
          data: encoded_asset_data("<svg></svg>"),
          digest: "digest"
        }
      },
      image_sources: %{
        "app.svg" => %{digest: "digest", path: "/digest.svg"}
      },
      scripts: %{
        "digest.js" => %{
          content_type: "application/javascript",
          data: encoded_asset_data("console.log('ok')"),
          digest: "digest"
        }
      },
      script_tags: %{
        "app.js" => %{digest: "digest", integrity: "sha512-script", path: "/digest.js"}
      },
      signature: "signature",
      static_files: %{
        "robots.txt" => %{
          data: %{
            "raw" => {"User-agent: *\n", 14, ~s("raw-etag")},
            "br" => {"br", 2, ~s("br-etag")},
            "deflate" => {"deflate", 7, ~s("deflate-etag")},
            "gzip" => {"gzip", 4, ~s("gzip-etag")},
            "zstd" => {"zstd", 4, ~s("zstd-etag")}
          }
        }
      },
      static_signature: "static-signature",
      style_tags: %{
        "app.css" => %{content: ".a{}", digest: "digest", integrity: "sha512-style"}
      }
    }
  end

  defp encoded_asset_data(content) do
    %{
      "raw" => {content, byte_size(content)},
      "br" => {"br", 2},
      "deflate" => {"deflate", 7},
      "gzip" => {"gzip", 4},
      "zstd" => {"zstd", 4}
    }
  end

  defp module_name, do: Atom.to_string(__MODULE__)
end
