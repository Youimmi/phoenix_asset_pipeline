defmodule PhoenixAssetPipeline.Assets.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Bun, as: BunRuntime
  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config

  @script ~S"""
  import path from "node:path";
  import { stat, readdir } from "node:fs/promises";

  const assetsDir = process.cwd();
  const minifyJs = process.env.PHOENIX_ASSET_PIPELINE_MINIFY_JS === "1";
  const buildSvg = process.env.PHOENIX_ASSET_PIPELINE_SVG === "1";
  const entries = (name) => (process.env[name] || "").split("\n").filter(Boolean);
  const heroIconNames = entries("PHOENIX_ASSET_PIPELINE_HERO_ICON_NAMES");
  const heroiconsDir = process.env.PHOENIX_ASSET_PIPELINE_HEROICONS_DIR;

  const emit = (filePath, content) => {
    const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);

    process.stdout.write(
      `${Buffer.from(filePath).toString("base64")}\t${bytes.toString("base64")}\n`
    );
  };

  const exists = async (filePath) => {
    try {
      await stat(filePath);
      return true;
    } catch {
      return false;
    }
  };

  const hiddenPath = (filePath) => filePath.split(/[\\/]+/).some((part) => part.startsWith("."));

  const regularFiles = async (dir) => {
    if (!(await exists(dir))) return [];

    const files = [];
    const scan = async (current) => {
      for (const entry of await readdir(current, { withFileTypes: true })) {
        if (entry.name.startsWith(".")) continue;

        const entryPath = path.join(current, entry.name);

        if (entry.isDirectory()) {
          await scan(entryPath);
        } else if (entry.isFile()) {
          files.push(entryPath);
        }
      }
    };

    await scan(dir);
    return files.sort();
  };

  const buildJs = async (entry) => {
    const result = await Bun.build({
      entrypoints: [entry],
      format: "esm",
      minify: minifyJs,
      sourcemap: "none",
      splitting: false,
      target: "browser"
    });

    if (!result.success) {
      for (const log of result.logs) console.error(log);
      process.exit(1);
    }

    for (const artifact of result.outputs) {
      const ext = path.extname(artifact.path || entry).toLowerCase();

      if (ext === ".js" || ext === ".mjs" || ext === ".cjs") {
        const name = `${path.basename(entry, path.extname(entry))}.js`;
        emit(`assets/js/${name}`, Buffer.from(await artifact.arrayBuffer()));
      } else if (ext === ".css") {
        emit(`assets/css/${path.basename(artifact.path)}`, Buffer.from(await artifact.arrayBuffer()));
      }
    }
  };

  const buildCss = async (entry) => {
    const proc = Bun.spawn({
      cmd: [
        process.execPath,
        "--no-orphans",
        "run",
        "tailwindcss",
        "--input",
        entry,
        "--minify",
        "--output",
        "-",
        "--silent"
      ],
      cwd: assetsDir,
      stdout: "pipe",
      stderr: "pipe"
    });
    const output = new Response(proc.stdout).text();
    const error = new Response(proc.stderr).text();
    const exitCode = await proc.exited;
    const [css, stderr] = await Promise.all([output, error]);

    if (exitCode !== 0) {
      throw new Error(`tailwindcss ${entry} exited with ${exitCode}\n${stderr}`);
    }

    emit(`assets/css/${path.basename(entry)}`, css);
  };

  const optimizeSvg = async (filePath) => {
    const { optimize } = await import("svgo");
    const result = optimize(await Bun.file(filePath).text(), {
      multipass: true,
      path: filePath
    });

    if (result.error) throw new Error(result.error);

    return result.data;
  };

  const buildDirectSvgRoot = async (sourceDir, outputPrefix) => {
    const files = await regularFiles(sourceDir);

    for (const file of files) {
      if (path.extname(file).toLowerCase() !== ".svg") continue;
      if (hiddenPath(path.relative(sourceDir, file))) continue;

      const relative = path.relative(sourceDir, file);

      if (relative.split(path.sep).includes("sprites")) continue;

      emit(`assets/svg/${outputPrefix}${relative.split(path.sep).join("/")}`, await optimizeSvg(file));
    }
  };

  const createSpriter = async (mode, spriteName) => {
    const svgSprite = await import("svg-sprite");
    const create = svgSprite.default ?? svgSprite;

    return create({
      dest: ".",
      shape: {
        transform: [{ svgo: { multipass: true } }]
      },
      svg: {
        dimensionAttributes: false,
        doctypeDeclaration: false,
        namespaceClassnames: false,
        namespaceIDs: false,
        xmlDeclaration: false
      },
      mode: {
        [mode]: {
          bust: false,
          dest: ".",
          inline: false,
          sprite: spriteName
        }
      }
    });
  };

  const spriteSourceFiles = async (sourceDir) => {
    const files = await regularFiles(sourceDir);

    return files.filter((file) => path.extname(file).toLowerCase() === ".svg");
  };

  const addSpriteFile = async (spriter, root, file) => {
    const name = path.relative(root, file);

    spriter.add(file, name, await Bun.file(file).text());
  };

  const heroIconSource = (name) => {
    if (name.endsWith("-micro")) {
      return path.join(heroiconsDir, "16/solid", `${name.slice(0, -6)}.svg`);
    }

    if (name.endsWith("-mini")) {
      return path.join(heroiconsDir, "20/solid", `${name.slice(0, -5)}.svg`);
    }

    if (name.endsWith("-solid")) {
      return path.join(heroiconsDir, "24/solid", `${name.slice(0, -6)}.svg`);
    }

    return path.join(heroiconsDir, "24/outline", `${name}.svg`);
  };

  const addHeroIcon = async (spriter, name) => {
    const source = heroIconSource(name);

    if (!(await exists(source))) {
      throw new Error(`Unknown Heroicon "${name}" (${source})`);
    }

    const virtualPath = path.join(assetsDir, ".phoenix_asset_pipeline", `hero-${name}.svg`);

    spriter.add(virtualPath, `hero-${name}.svg`, await Bun.file(source).text());
  };

  const emitSprite = async (mode, sourceDir, spriteName, hasExtraSources = false, addExtraSources = async () => {}) => {
    const files = await spriteSourceFiles(sourceDir);

    if (files.length === 0 && !hasExtraSources) return;

    const spriter = await createSpriter(mode, spriteName);

    for (const file of files) await addSpriteFile(spriter, sourceDir, file);

    await addExtraSources(spriter);

    const { result } = await spriter.compileAsync();
    const resources = Object.values(result).flatMap((modeResult) => Object.values(modeResult));
    const resource =
      resources.find((item) => path.basename(item.path) === spriteName) ??
      resources.find((item) => item.contents);

    if (resource?.contents) {
      emit(`assets/svg/${spriteName}`, resource.contents);
    }
  };

  for (const entry of entries("PHOENIX_ASSET_PIPELINE_JS")) await buildJs(entry);
  for (const entry of entries("PHOENIX_ASSET_PIPELINE_CSS")) await buildCss(entry);

  if (buildSvg) {
    await buildDirectSvgRoot(path.join(assetsDir, "svg"), "");

    await emitSprite("stack", path.join(assetsDir, "svg", "sprites", "app"), "app.svg");
    await emitSprite(
      "symbol",
      path.join(assetsDir, "svg", "sprites", "icons"),
      "icons.svg",
      heroIconNames.length > 0,
      async (spriter) => {
        for (const name of heroIconNames) await addHeroIcon(spriter, name);
      }
    );
  }
  """

  @css_ext ".css"
  @entry_exts ~w(.cjs .cts .js .jsx .mjs .mts .ts .tsx)
  @install_cache_file "bun_install.term"
  @output_cache_file "bun_assets.term"
  @output_cache_version 1

  def build(assets_dir, hero_icon_names) do
    js_entries = asset_entries(assets_dir, "js", @entry_exts)
    css_entries = asset_entries(assets_dir, "css", [@css_ext])

    if js_entries == [] and css_entries == [] and not svg_sources?(assets_dir, hero_icon_names) do
      []
    else
      BunRuntime.ensure!()
      ensure_package_json!(assets_dir)
      ensure_dependencies(assets_dir)
      build_cached(assets_dir, js_entries, css_entries, hero_icon_names)
    end
  end

  defp asset_entries(assets_dir, dir, exts) do
    assets_dir
    |> Path.join(dir)
    |> entries(exts)
    |> Enum.map(&Path.relative_to(&1, assets_dir))
  end

  defp asset_mode do
    if Config.precompiled_manifest?(), do: :prod, else: :dev
  end

  defp build_cached(assets_dir, js_entries, css_entries, hero_icon_names) do
    source_cache = read_output_cache()
    install_signature = install_signature(assets_dir)

    {js_assets, cache} = cached_js_assets(source_cache, %{}, assets_dir, js_entries, install_signature)
    {css_assets, cache} = cached_css_assets(source_cache, cache, assets_dir, css_entries, install_signature)
    {svg_assets, cache} = cached_svg_assets(source_cache, cache, assets_dir, hero_icon_names, install_signature)

    save_output_cache(cache, source_cache)

    js_assets ++ css_assets ++ svg_assets
  end

  defp bun_install_args(assets_dir) do
    if asset_mode() == :prod and lockfile?(assets_dir),
      do: ~w(install --frozen-lockfile),
      else: ~w(install)
  end

  defp cached_css_assets(source_cache, next_cache, assets_dir, entries, install_signature) do
    Enum.flat_map_reduce(entries, next_cache, fn entry, cache ->
      key = {:css, entry, asset_mode(), install_signature, css_signature(assets_dir, entry)}
      cached_output(source_cache, cache, key, fn -> run(assets_dir, [], [entry], [], false) end)
    end)
  end

  defp cached_js_assets(_, next_cache, _, [], _), do: {[], next_cache}

  defp cached_js_assets(source_cache, next_cache, assets_dir, entries, install_signature) do
    key =
      {:js, asset_mode(), install_signature, source_signature(Path.join(assets_dir, "js")),
       source_signature(Config.colocated_dir())}

    cached_output(source_cache, next_cache, key, fn -> run(assets_dir, entries, [], [], false) end)
  end

  defp cached_output(source_cache, next_cache, key, fun) do
    case Map.fetch(source_cache, key) do
      {:ok, assets} -> {assets, Map.put(next_cache, key, assets)}
      :error -> put_output(next_cache, key, fun.())
    end
  end

  defp cached_svg_assets(source_cache, next_cache, assets_dir, hero_icon_names, install_signature) do
    if hero_icon_names != [] or has_svg_source?(Path.join(assets_dir, "svg")) do
      key = {:svg, asset_mode(), install_signature, svg_signature(assets_dir, hero_icon_names)}
      cached_output(source_cache, next_cache, key, fn -> run(assets_dir, [], [], hero_icon_names, true) end)
    else
      {[], next_cache}
    end
  end

  defp css_signature(assets_dir, _) do
    {
      source_signature(Path.join(assets_dir, "css"), [@css_ext]),
      source_signature(project_lib_dir(assets_dir), ~w(.ex .heex)),
      source_signature(Config.colocated_dir())
    }
  end

  defp ensure_dependencies(assets_dir) do
    signature = install_signature(assets_dir)

    if install_required?(assets_dir, signature) do
      case run_bun(bun_install_args(assets_dir),
             cd: assets_dir,
             into: IO.stream(:stdio, :line),
             stderr_to_stdout: true
           ) do
        {_, 0} -> save_install_cache(assets_dir)
        {_, status} -> raise "bun install exited with #{status}"
      end
    end
  end

  defp ensure_package_json!(assets_dir) do
    if !File.regular?(Path.join(assets_dir, "package.json")) do
      raise "missing assets/package.json for PhoenixAssetPipeline Bun asset builds"
    end
  end

  defp entries(dir, exts) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&(File.regular?(&1) and entry_file?(&1, exts)))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  defp entry_file?(path, exts) do
    basename = Path.basename(path)

    not String.starts_with?(basename, [".", "_"]) and
      Path.extname(path) in exts
  end

  defp file_digest(path) do
    if File.regular?(path) do
      path
      |> File.read!()
      |> :erlang.md5()
      |> Base.encode16(case: :lower)
    else
      :missing
    end
  end

  defp has_svg_source?(dir) do
    dir
    |> Path.expand()
    |> svg_source_in?()
  end

  defp hero_icon_path(assets_dir, name) do
    base = heroicons_dir(assets_dir)

    cond do
      String.ends_with?(name, "-micro") -> Path.join([base, "16/solid", String.trim_trailing(name, "-micro") <> ".svg"])
      String.ends_with?(name, "-mini") -> Path.join([base, "20/solid", String.trim_trailing(name, "-mini") <> ".svg"])
      String.ends_with?(name, "-solid") -> Path.join([base, "24/solid", String.trim_trailing(name, "-solid") <> ".svg"])
      true -> Path.join([base, "24/outline", name <> ".svg"])
    end
  end

  defp heroicons_dir(assets_dir), do: assets_dir |> project_dir() |> Path.join("deps/heroicons/optimized")

  defp install_cache_path do
    Path.join(Config.manifest_cache_dir(), @install_cache_file)
  end

  defp install_cache_record(assets_dir) do
    {Path.expand(assets_dir), install_signature(assets_dir)}
  end

  defp install_required?(assets_dir, signature) do
    not File.dir?(Path.join(assets_dir, "node_modules")) or
      read_install_cache() != {:ok, {Path.expand(assets_dir), signature}}
  end

  defp install_signature(assets_dir) do
    assets_dir = Path.expand(assets_dir)

    [
      {"package.json", file_digest(Path.join(assets_dir, "package.json"))},
      {"bun.lock", file_digest(Path.join(assets_dir, "bun.lock"))},
      {"bun.lockb", file_digest(Path.join(assets_dir, "bun.lockb"))}
    ]
  end

  defp lockfile?(assets_dir) do
    File.regular?(Path.join(assets_dir, "bun.lock")) or File.regular?(Path.join(assets_dir, "bun.lockb"))
  end

  defp mix_path(fun) do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      apply(Mix.Project, fun, [])
    end
  rescue
    _ -> nil
  end

  defp node_path do
    [System.get_env("NODE_PATH"), mix_path(:build_path), mix_path(:deps_path)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(":")
  end

  defp output_cache_path do
    Path.join(Config.manifest_cache_dir(), @output_cache_file)
  end

  defp parse_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(fn line ->
      [path, content] = String.split(line, "\t", parts: 2)
      {Base.decode64!(path), Base.decode64!(content)}
    end)
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))
  defp project_lib_dir(assets_dir), do: assets_dir |> project_dir() |> Path.join("lib")

  defp put_output(cache, key, assets), do: {assets, Map.put(cache, key, assets)}

  defp read_install_cache do
    Cache.read_term(install_cache_path(), :error, fn
      {assets_dir, signature} when is_binary(assets_dir) and is_list(signature) -> {:ok, {:ok, {assets_dir, signature}}}
      _ -> :error
    end)
  end

  defp read_output_cache do
    Cache.read_term(output_cache_path(), %{}, fn
      %{version: @output_cache_version, assets: cache} when is_map(cache) -> {:ok, cache}
      _ -> :error
    end)
  end

  defp regular_entry(_, "." <> _), do: []
  defp regular_entry(_, "node_modules"), do: []

  defp regular_entry(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) -> regular_files(path)
      File.regular?(path) -> [path]
      true -> []
    end
  end

  defp regular_files(dir) do
    case dir |> Path.expand() |> File.ls() do
      {:ok, entries} -> entries |> Enum.flat_map(&regular_entry(Path.expand(dir), &1)) |> Enum.sort()
      {:error, _} -> []
    end
  end

  defp run(assets_dir, js_entries, css_entries, hero_icon_names, svg?) do
    env = [
      {"NODE_PATH", node_path()},
      {"PHOENIX_ASSET_PIPELINE_CSS", Enum.join(css_entries, "\n")},
      {"PHOENIX_ASSET_PIPELINE_HERO_ICON_NAMES", Enum.join(hero_icon_names, "\n")},
      {"PHOENIX_ASSET_PIPELINE_HEROICONS_DIR", heroicons_dir(assets_dir)},
      {"PHOENIX_ASSET_PIPELINE_JS", Enum.join(js_entries, "\n")},
      {"PHOENIX_ASSET_PIPELINE_MINIFY_JS", if(asset_mode() == :prod, do: "1", else: "0")},
      {"PHOENIX_ASSET_PIPELINE_SVG", if(svg?, do: "1", else: "0")}
    ]

    case run_bun(["--eval", @script], cd: assets_dir, env: env) do
      {output, 0} -> parse_output(output)
      {output, status} -> raise "bun asset build exited with #{status}\n#{output}"
    end
  end

  defp run_bun(args, opts) do
    BunRuntime.run(args, opts)
  end

  defp save_install_cache(assets_dir) do
    Cache.write_term!(install_cache_path(), install_cache_record(assets_dir))
  end

  defp save_output_cache(cache, cache), do: :ok

  defp save_output_cache(cache, _) do
    Cache.write_term!(output_cache_path(), %{assets: cache, version: @output_cache_version})
  end

  defp source_signature(dir) do
    dir
    |> regular_files()
    |> Enum.map(&{Path.relative_to(&1, dir), file_digest(&1)})
  end

  defp source_signature(dir, exts) do
    dir
    |> regular_files()
    |> Enum.filter(&(Path.extname(&1) in exts))
    |> Enum.map(&{Path.relative_to(&1, dir), file_digest(&1)})
  end

  defp svg_signature(assets_dir, hero_icon_names) do
    {
      source_signature(Path.join(assets_dir, "svg"), [".svg"]),
      Enum.map(hero_icon_names, &{&1, file_digest(hero_icon_path(assets_dir, &1))})
    }
  end

  defp svg_source_entry?(_, "." <> _), do: false

  defp svg_source_entry?(dir, entry) do
    path = Path.join(dir, entry)

    cond do
      File.dir?(path) -> svg_source_in?(path)
      File.regular?(path) -> Path.extname(path) == ".svg"
      true -> false
    end
  end

  defp svg_source_in?(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.any?(entries, &svg_source_entry?(dir, &1))
      {:error, _} -> false
    end
  end

  defp svg_sources?(assets_dir, hero_icon_names) do
    hero_icon_names != [] or
      assets_dir |> Path.join("svg") |> has_svg_source?()
  end
end
