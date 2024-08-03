defmodule PhoenixAssetPipeline.Helpers do
  @moduledoc false

  import Phoenix.HTML, only: [attributes_escape: 1]
  import PhoenixAssetPipeline.Obfuscator, only: [obfuscate: 1, valid?: 1]

  alias PhoenixAssetPipeline.Compiler.CompileError
  alias PhoenixAssetPipeline.Compiler.Esbuild
  alias PhoenixAssetPipeline.Compiler.Sass
  alias PhoenixAssetPipeline.Compiler.Tailwind

  @before_compile PhoenixAssetPipeline.Utils
  @endpoint PhoenixAssetPipeline.Endpoint
  @persistent_term {:phoenix_asset_pipeline, :assets}

  import PhoenixAssetPipeline.Utils,
    only: [
      application_started?: 0,
      dets_file: 1,
      dets_table: 1,
      digest: 1
    ]

  def compile_error!(module, msg) do
    dets_file = dets_file(__MODULE__)
    table = dets_table(dets_file)

    :dets.insert_new(table, {:recompile, true})
    :dets.close(dets_file)

    if not application_started?(), do: raise(module, msg)
    quote do: raise(unquote(module), unquote(msg))
  end

  def sorted_attrs(attrs) when is_list(attrs) do
    attrs
    |> Enum.sort()
    |> attributes_escape()
    |> elem(1)
  end

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

  defp assets(extname, digest, data) do
    {:ok, br_data} = :brotli.encode(data)
    br_extname = extname <> ".br"
    zstd_data = :ezstd.compress(data)
    zstd_extname = extname <> ".zstd"

    [
      {extname, digest, data},
      {br_extname, digest, br_data},
      {zstd_extname, digest, zstd_data}
    ]
  end

  defp put_integrity(opts, hash) do
    Keyword.put_new(opts, :integrity, "sha512-" <> hash)
  end

  defp put_track_static(opts) do
    Keyword.put_new(opts, :phx_track_static, true)
  end

  defmacro class(_, _ \\ [])

  defmacro class(class_names, opts) when is_binary(class_names) do
    with [_ | [_ | _]] <- String.split(class_names, ~r/\s+/) do
      compile_error!(
        ArgumentError,
        "Pass multiple class names as a list: #{inspect(class_names)}"
      )
    end

    quote do: class([unquote(class_names)], unquote(opts))
  end

  defmacro class(class_names, opts) when is_list(class_names) and is_list(opts) do
    result =
      Enum.reduce_while(class_names, [], fn class_name, class ->
        if valid?(class_name),
          do: {:cont, [obfuscate(class_name) | class]},
          else: {:halt, {:error, class_name}}
      end)

    case result do
      {:error, class_name} ->
        compile_error!(ArgumentError, "Invalid class name: #{inspect(class_name)}")

      class when is_list(class) ->
        duplicates = class -- Enum.uniq(class)

        if Enum.empty?(duplicates),
          do: Keyword.put(opts, :class, Enum.sort(class)),
          else: compile_error!(ArgumentError, "Remove duplicate classes: #{inspect(class_names)}")
    end
  end

  # defmacro img(_path, opts) do
  #   # {_digest, _extname, _fragment, integrity} = {"", "", "", ""}

  #   # attrs =
  #   #   opts
  #   #   |> put_integrity(integrity)

  #   # {:safe, [?<, :img, sorted_attrs(attrs), ?>]}
  #   ""
  # end

  defmacro script(path, opts \\ []) when is_list(opts) do
    {content, integrity} = Esbuild.new(path)

    digest = digest(content)
    extname = ".js"
    name = Path.rootname(path)

    src_path =
      if Mix.env() == :prod,
        do: "/#{digest}#{extname}",
        else: "/#{name}-#{digest}#{extname}"

    attrs =
      opts
      |> put_integrity(integrity)
      |> put_track_static()

    assets = assets(extname, digest, content)

    for {extname, digest, content} <- assets do
      :persistent_term.put(@persistent_term, [{extname, digest, content} | assets])
    end

    quote do
      attrs =
        unquote(attrs)
        |> Keyword.put(:src, unquote(@endpoint).url() <> unquote(src_path))
        |> sorted_attrs()

      {:safe, [?<, "script", attrs, ?>, ?<, ?/, "script", ?>]}
    end
  end

  defmacro style(path, opts \\ []) when is_list(opts) do
    case Sass.new(path) do
      {:error, msg} ->
        compile_error!(CompileError, msg)

      {content, integrity} ->
        File.rm(dets_file(__MODULE__))

        attrs =
          opts
          |> put_integrity(integrity)
          |> sorted_attrs()

        {:safe, [?<, "style", attrs, ?>, content, ?<, ?/, "style", ?>]}
    end
  end

  defmacro tailwind(path, opts \\ []) when is_list(opts) do
    case Tailwind.new(path) do
      {:error, msg} ->
        compile_error!(CompileError, msg)

      {content, integrity} ->
        File.rm(dets_file(__MODULE__))

        attrs =
          opts
          |> put_integrity(integrity)
          |> sorted_attrs()

        {:safe, [?<, "style", attrs, ?>, content, ?<, ?/, "style", ?>]}
    end
  end

  defmacro __using__(_) do
    :persistent_term.erase({:phoenix_asset_pipeline, :classes})

    quote do
      import PhoenixAssetPipeline.Utils, only: [assets_paths: 0]
      import PhoenixAssetPipeline.Helpers

      @before_compile PhoenixAssetPipeline.Helpers

      for path <- assets_paths(), do: @external_resource(path)
    end
  end

  defmacro __before_compile__(_) do
    assets = :persistent_term.get(@persistent_term, []) |> Macro.escape()

    quote do
      @on_load :on_load

      defp on_load, do: :persistent_term.put(unquote(@persistent_term), unquote(assets))
    end
  end
end
