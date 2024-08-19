defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc """
  Provides asset pipeline macros.
  """

  import Phoenix.HTML, only: [attributes_escape: 1]
  import PhoenixAssetPipeline.Obfuscator, only: [obfuscate: 1, valid?: 1]

  import PhoenixAssetPipeline.Utils,
    only: [
      dets_file: 1,
      dets_table: 1,
      digest: 1,
      encode: 2
    ]

  alias PhoenixAssetPipeline.Compiler.CompileError
  alias PhoenixAssetPipeline.Compiler.Esbuild
  alias PhoenixAssetPipeline.Compiler.Sass
  alias PhoenixAssetPipeline.Compiler.Tailwind
  alias PhoenixAssetPipeline.Storage

  @before_compile PhoenixAssetPipeline.Utils

  defmacro __before_compile__(_) do
    assets = Storage.get(:assets, []) |> Enum.uniq() |> Macro.escape()
    integrities = Storage.get(:integrities, []) |> Enum.uniq() |> Macro.escape()

    quote do
      @on_load :on_load

      def on_load do
        Storage.put(:assets, unquote(assets))
        Storage.put(:integrities, unquote(integrities))
      end
    end
  end

  defmacro __using__(_) do
    Storage.erase(:classes)

    quote do
      import PhoenixAssetPipeline.Helpers
      import PhoenixAssetPipeline.Utils, only: [assets_paths: 0]

      @before_compile unquote(__MODULE__)

      paths =
        File.cwd!()
        |> Path.join("lib/**/*.{ex,heex}")
        |> Path.wildcard()

      for path <- paths ++ assets_paths(), do: @external_resource(path)
    end
  end

  @doc """
  Returns class list with obfuscated class names.

  ## Examples

      <.div {class("text-center")}>
        <.h1 {class(["text-2xl", "font-bold"])}>
          Hello, Phoenix!
        </.h1>
      </.div>

  ## Output

      <div class="t">
        <h1 class="t1 f">
          Hello, Phoenix!
        </h1>
      </div>
  """
  defmacro class(class) when is_binary(class) do
    class_names = String.split(class, ~r/\s+/)

    if "" in class_names,
      do: compile_error!("Remove extra whitespaces: #{inspect(class)}"),
      else: quote(do: class(unquote(class_names)))
  end

  defmacro class(class_names) when is_list(class_names) do
    Enum.reduce_while(class_names, [], fn class_name, class ->
      if valid?(class_name),
        do: {:cont, [obfuscate(class_name) | class]},
        else: {:halt, {:error, class_name}}
    end)
    |> case do
      {:error, class_name} ->
        compile_error!("Invalid class name: #{inspect(class_name)}")

      class when is_list(class) ->
        if Enum.empty?(class -- Enum.uniq(class)),
          do: [class: Enum.sort(class)],
          else: compile_error!("Remove duplicate classes: #{inspect(class_names)}")
    end
  end

  @doc """
  Renders a script tag.

  Uses Phoenix.Endpoint.static_url/0
  Read more https://hexdocs.pm/phoenix/Phoenix.Endpoint.html

  ## Args

      path: ("app" || "app.js") || "app.ts"
      html_opts: list of html options

  ## Configuration

      config :my_app, MyAppWeb.Endpoint, static_url: [host: host, port: 443, scheme: "https"]

  ## Examples

      <%= script("app") %>
      <%= script("app", async: true, crossorigin: "anonymous") %>

  ## Output

  If `static_url/0` returns "localhost" hostname, root path will be used

      <script async="async" crossorigin="anonymous" integrity="sha512-<integrity>" phx-track-static="phx-track-static" src="/<path>-<digest>.js">
      </script>

  Otherwise, the full url will be used

      <script async="async" crossorigin="anonymous" integrity="sha512-<integrity>" phx-track-static="phx-track-static" src="<static_url>/<path>-<digest>.js">
      </script>
  """
  defmacro script(path, html_opts \\ []) when is_list(html_opts) do
    {content, integrity} = Esbuild.new(path)
    digest = digest(content)
    extname = ".js"
    name = Path.rootname(path)

    src_path =
      if Mix.env() == :prod,
        do: "/#{digest}#{extname}",
        else: "/#{name}-#{digest}#{extname}"

    attrs =
      html_opts
      |> put_integrity(integrity)
      |> put_track_static()

    assets = Storage.get(:assets, [])
    Storage.put(:assets, assets ++ assets(extname, digest, content))

    integrities = Storage.get(:integrities, [])
    Storage.put(:integrities, [{".js", integrity} | integrities])

    quote do
      endpoint = Storage.get(:endpoint)

      src =
        if endpoint.host() == "localhost",
          do: unquote(src_path),
          else: endpoint.static_url() <> unquote(src_path)

      attrs =
        unquote(attrs)
        |> Keyword.put(:src, src)
        |> sorted_attrs()

      {:safe, [?<, "script", attrs, ?>, ?<, ?/, "script", ?>]}
    end
  end

  @doc """
  Renders a inline style tag.

  ## Args

      path: ("app" || "app.css") || "app.sass" || "app.scss"
      html_opts: list of html options

  ## Examples

      <%= style("app") %>

  ## Output

      <style integrity="sha512-<integrity>">
        /* app.css styles */
      </style>
  """
  defmacro style(path, html_opts \\ []) when is_list(html_opts) do
    case Sass.new(path) do
      {:error, msg} ->
        compile_error!(CompileError, msg)

      {content, integrity} ->
        integrities = Storage.get(:integrities, [])
        Storage.put(:integrities, [{".css", integrity} | integrities])

        attrs =
          html_opts
          |> put_integrity(integrity)
          |> sorted_attrs()

        {:safe, [?<, "style", attrs, ?>, content, ?<, ?/, "style", ?>]}
    end
  end

  @doc """
  Renders a inline style tag with tailwind css.

  Requires tailwind.config.js file in the assets directory.

  ## Args

      path: ("app" || "app.css") || "app.sass" || "app.scss"
      html_opts: list of html options

  ## Examples

      <%= style("app") %>

  ## Output

      <style integrity="sha512-<integrity>">
        /* tailwind css styles */
        /* app.css styles */
      </style>
  """
  defmacro tailwind(path, html_opts \\ []) when is_list(html_opts) do
    case Tailwind.new(path) do
      {:error, msg} ->
        compile_error!(CompileError, msg)

      {content, integrity} ->
        integrities = Storage.get(:integrities, [])
        Storage.put(:integrities, [{".css", integrity} | integrities])

        attrs =
          html_opts
          |> put_integrity(integrity)
          |> sorted_attrs()

        {:safe, [?<, "style", attrs, ?>, content, ?<, ?/, "style", ?>]}
    end
  end

  @doc false
  def __mix_recompile__? do
    dets_file = dets_file(__MODULE__)
    table = dets_table(dets_file)

    recompile =
      case :dets.lookup(table, :recompile) do
        [recompile: true] -> true
        _ -> false
      end

    :dets.close(dets_file)
    File.rm(dets_file)

    recompile
  end

  @doc false
  def sorted_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.sort()
    |> attributes_escape()
    |> elem(1)
  end

  defp assets(extname, digest, data) do
    fun = &{&1, &2, &3, byte_size(&3)}

    [
      Task.async(fn -> fun.(extname, digest, data) end),
      Task.async(fn -> fun.(extname <> ".br", digest, encode(:brotli, data)) end),
      Task.async(fn -> fun.(extname <> ".deflate", digest, encode(:deflate, data)) end),
      Task.async(fn -> fun.(extname <> ".gz", digest, encode(:gzip, data)) end)
    ]
    |> Task.await_many()
  end

  defp compile_error!(module \\ ArgumentError, msg) do
    dets_file = dets_file(__MODULE__)
    table = dets_table(dets_file)

    :dets.insert_new(table, {:recompile, true})
    :dets.close(dets_file)

    if Code.ensure_loaded?(Code) && Code.can_await_module_compilation?(), do: raise(module, msg)
    quote do: raise(unquote(module), unquote(msg))
  end

  defp put_integrity(opts, hash) do
    Keyword.put_new(opts, :integrity, "sha512-" <> hash)
  end

  defp put_track_static(opts) do
    Keyword.put_new(opts, :phx_track_static, true)
  end
end
