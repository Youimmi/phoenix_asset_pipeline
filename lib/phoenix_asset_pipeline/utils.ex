defmodule PhoenixAssetPipeline.Utils do
  @moduledoc """
  Provides utility functions for the Phoenix Asset Pipeline.

  ## Assets directory

      ├── assets
      │   ├── css
      │   │   ├── app.css
      │   │   ├── app.sass
      │   │   ├── app.scss
      │   ├── img
      │   │   ├── logo.svg
      │   ├── js
      │   │   ├── app.js
      │   │   ├── app.ts
      │   ├── tailwind.config.js

  ## Static directory

      ├── priv
      │   ├── static
      │   │   ├── apple-touch-icon.png
      │   │   ├── android-chrome-192x192.png
      │   │   ├── android-chrome-512x512.png
      │   │   ├── apple-touch-icon-precomposed.png
      │   │   ├── browserconfig.xml
      │   │   ├── favicon-16x16.png
      │   │   ├── favicon-32x32.png
      │   │   ├── favicon.ico
      │   │   ├── mstile-150x150.png
      │   │   ├── mstile-310x150.png
      │   │   ├── mstile-310x310.png
      │   │   ├── mstile-70x70.png
      │   │   ├── robots.txt
      │   │   ├── safari-pinned-tab.svg
      │   │   ├── site.webmanifest
  """

  @assets_dir "assets"
  @static_dir "priv/static"

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  defmacro __before_compile__(_) do
    Application.put_all_env(
      dart_sass: version(:dart_sass, "1.80.2"),
      esbuild: version(:esbuild, "0.24.0"),
      tailwind: version(:tailwind, "3.4.14")
    )

    File.exists?(Esbuild.bin_path()) || Esbuild.install()
    Enum.all?(DartSass.bin_paths(), &File.exists?/1) || DartSass.install()
    File.exists?(Tailwind.bin_path()) || Tailwind.install()
  end

  @doc """
  Returns the paths of the assets.

  ## Examples

      assets_paths()

  ## Output

      [
        "assets/css/app.css",
        "assets/img/logo.svg",
        "assets/js/app.js"
      ]
  """
  def assets_paths do
    assets_path = Path.join([File.cwd!(), @assets_dir])

    glob = [
      Path.join([assets_path, "css", "**/*.{css,sass,scss}"]),
      Path.join([assets_path, "img", "**/*.{png,svg}"]),
      Path.join([assets_path, "js", "**/*.{js,ts}"])
    ]

    for paths <- glob, path <- Path.wildcard(paths), do: path
  end

  @doc false
  def cmd([command | args], extra_args, opts) do
    cmd(command, args ++ extra_args, opts)
  end

  @doc false
  def cmd(command, args, opts) do
    System.cmd(command, args, opts)
  end

  @doc false
  def dets_file(module) when is_atom(module) do
    dets_file_path(module)
    |> String.to_charlist()
  end

  @doc false
  def dets_table(file) do
    with {:ok, table} <- :dets.open_file(file, type: :set), do: table
  end

  @doc """
  Returns the Base64 encoded MD5 digest of the content.
  """
  def digest(content) do
    :erlang.md5(content)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Encodes the content using the specified algorithm.

  ## Examples

      encode(:brotli, content)
      encode(:deflate, content)
      encode(:gzip, content)
  """
  def encode(:brotli, content) do
    with {:ok, data} <- :brotli.encode(content, %{quality: 11}),
         do: data
  end

  def encode(:deflate, content), do: compress(content, 15)
  def encode(:gzip, content), do: compress(content, 31)

  @doc """
  Returns the Base64 encoded SHA-512 digest of the content.
  """
  def integrity(content) do
    :crypto.hash(:sha512, content)
    |> Base.encode64()
  end

  @doc """
  Normalizes the path by removing the trailing slash.
  """
  def normalize(path) do
    Regex.replace(~r/(\/)*$/, path, "")
  end

  @doc """
  Returns the priv/static file paths.

  ## Examples

      static_paths()

  ## Output

      [
        "priv/static/android-chrome-192x192.png",
        "priv/static/android-chrome-512x512.png",
        "priv/static/apple-touch-icon-precomposed.png",
        "priv/static/apple-touch-icon.png",
        "priv/static/browserconfig.xml",
        "priv/static/favicon-16x16.png",
        "priv/static/favicon-32x32.png",
        "priv/static/favicon.ico",
        "priv/static/mstile-150x150.png",
        "priv/static/mstile-310x150.png",
        "priv/static/mstile-310x310.png",
        "priv/static/mstile-70x70.png",
        "priv/static/robots.txt",
        "priv/static/safari-pinned-tab.svg",
        "priv/static/site.webmanifest"
      ]
  """
  def static_paths do
    Path.join([File.cwd!(), @static_dir])
    |> Path.join("**/*")
    |> Path.wildcard()
  end

  @doc """
  Returns the list of static files.

  ## Examples

      static_files()

  ## Output

      [
        {".png", "apple-touch-icon", "<digest>", <data>, <byte_size>},
        {".png.br", "apple-touch-icon", "<digest>", <br_data>, <byte_size>},
        {".png.deflate", "apple-touch-icon", "<digest>", <deflate_data>, <byte_size>},
        {".png.gz", "apple-touch-icon", "<digest>", <gz_data>, <byte_size>},
        ...
      ]
  """
  def static_files do
    root_dir = Path.join([File.cwd!(), @static_dir])

    for path <- static_paths(),
        {:ok, file_info(type: :regular)} <- [:prim_file.read_file_info(path)] do
      content = File.read!(path)
      digest = digest(content)

      ^root_dir <> "/" <> path = path
      extname = Path.extname(path)
      path = Path.rootname(path)

      fun = &{&1, &2, &3, &4, byte_size(&4)}

      [
        Task.async(fn -> fun.(extname, path, digest, content) end),
        Task.async(fn -> fun.(extname <> ".br", path, digest, encode(:brotli, content)) end),
        Task.async(fn -> fun.(extname <> ".deflate", path, digest, encode(:deflate, content)) end),
        Task.async(fn -> fun.(extname <> ".gz", path, digest, encode(:gzip, content)) end)
      ]
      |> Task.await_many()
    end
    |> List.flatten()
  end

  defp compress(content, window_bits) do
    zstream = :zlib.open()
    :zlib.deflateInit(zstream, :best_compression, :deflated, window_bits, 9, :default)
    data = :zlib.deflate(zstream, content, :finish)
    :zlib.deflateEnd(zstream)
    :zlib.close(zstream)

    IO.iodata_to_binary(data)
  end

  defp dets_file_path(module) when is_atom(module) do
    path =
      Module.split(module)
      |> Enum.map_join(".", &Macro.underscore/1)

    if Code.loaded?(Mix.Project) do
      Mix.Project.build_path()
      |> Path.dirname()
      |> Path.join(path)
    else
      Path.expand("_build/" <> path)
    end
  end

  defp version(app, default) do
    [version: Application.get_env(app, :version, default)]
  end
end
