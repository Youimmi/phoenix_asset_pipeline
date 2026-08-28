defmodule PhoenixAssetPipeline.Assets.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Sprites
  alias PhoenixAssetPipeline.Bun, as: BunRuntime
  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config

  @script ~S"""
  import path from "node:path";
  import { stat, readdir } from "node:fs/promises";

  const assetsDir = process.cwd();
  const outputDir = process.env.PHOENIX_ASSET_PIPELINE_OUTPUT_DIR;
  const minifyJs = process.env.PHOENIX_ASSET_PIPELINE_MINIFY_JS === "1";
  const entries = (name) => (process.env[name] || "").split("\n").filter(Boolean);
  const dropJs = entries("PHOENIX_ASSET_PIPELINE_JS_DROP");
  const buildSvg = process.env.PHOENIX_ASSET_PIPELINE_SVG === "1";
  const spriteGroupEntries = [];
  const spriteSourceEntries = [];

  for (const line of entries("PHOENIX_ASSET_PIPELINE_SVG_SPRITE_SOURCES")) {
    const fields = line.split("\t");

    if (fields[0] === "g") {
      const [, sprite, mode, namespaceIDs, metadataFile] = fields;
      spriteGroupEntries.push({
        sprite,
        mode,
        namespaceIDs: namespaceIDs === "1",
        metadataFile: metadataFile || null
      });
    } else if (fields[0] === "s") {
      const [, sprite, source, name] = fields;
      spriteSourceEntries.push({ sprite, source, name });
    } else {
      throw new Error("Invalid SVG sprite manifest entry");
    }
  }

  let outputIndex = 0;

  const emit = async (group, filePath, content) => {
    const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content);
    const outputName = String(outputIndex++);

    await Bun.write(path.join(outputDir, outputName), bytes);
    process.stdout.write(`${group}\t${Buffer.from(filePath).toString("base64")}\t${outputName}\n`);
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

  const buildJs = async (jsEntries) => {
    const result = await Bun.build({
      entrypoints: jsEntries,
      drop: dropJs,
      format: "esm",
      metafile: true,
      minify: minifyJs,
      sourcemap: "none",
      splitting: false,
      target: "browser"
    });

    if (!result.success) {
      for (const log of result.logs) console.error(log);
      process.exit(1);
    }

    for (const input of Object.keys(result.metafile.inputs)) {
      const inputPath = path.isAbsolute(input) ? input : path.resolve(assetsDir, input);

      if (!inputPath.split(path.sep).includes("node_modules")) {
        process.stdout.write(`dependency\t${Buffer.from(inputPath).toString("base64")}\tjs\n`);
      }
    }

    for (const artifact of result.outputs) {
      const artifactPath = artifact.path;
      const ext = path.extname(artifactPath).toLowerCase();

      if (ext === ".js" || ext === ".mjs" || ext === ".cjs") {
        const name = `${path.basename(artifactPath, path.extname(artifactPath))}.js`;
        await emit("js", `assets/js/${name}`, Buffer.from(await artifact.arrayBuffer()));
      } else if (ext === ".css") {
        await emit("js", `assets/css/${path.basename(artifactPath)}`, Buffer.from(await artifact.arrayBuffer()));
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
    const output = new Response(proc.stdout).arrayBuffer();
    const error = new Response(proc.stderr).text();
    const exitCode = await proc.exited;
    const [css, stderr] = await Promise.all([output, error]);

    if (exitCode !== 0) {
      throw new Error(`tailwindcss ${entry} exited with ${exitCode}\n${stderr}`);
    }

    await emit("css", `assets/css/${path.basename(entry)}`, Buffer.from(css));
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

    await Promise.all(files.map(async (file) => {
      if (path.extname(file).toLowerCase() !== ".svg") return;
      if (hiddenPath(path.relative(sourceDir, file))) return;

      const relative = path.relative(sourceDir, file);

      if (relative.split(path.sep).includes("sprites")) return;

      await emit("svg", `assets/svg/${outputPrefix}${relative.split(path.sep).join("/")}`, await optimizeSvg(file));
    }));
  };

  const createSpriter = async (mode, spriteName, namespaceIDs) => {
    const { default: create } = await import("svg-sprite");

    return create({
      dest: ".",
      shape: {
        transform: [{ svgo: { multipass: true } }]
      },
      svg: {
        dimensionAttributes: false,
        doctypeDeclaration: false,
        namespaceClassnames: false,
        namespaceIDs,
        namespaceIDPrefix: `pap-${path.basename(spriteName, ".svg").replace(/[^A-Za-z0-9_.-]/g, "_")}--`,
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

  const addSpriteEntry = async (spriter, entry) => {
    const source = entry.source;

    if (!(await exists(source))) {
      throw new Error(`Unknown SVG sprite source "${entry.name}" (${source})`);
    }

    const virtualPath = path.join(assetsDir, ".phoenix_asset_pipeline", entry.name);

    spriter.add(virtualPath, entry.name, await Bun.file(source).text());
  };

  const spriteResource = (result, spriteName) => {
    for (const mode in result) {
      for (const name in result[mode]) {
        const resource = result[mode][name];

        if (path.basename(resource.path) === spriteName) {
          if (!resource.contents) throw new Error(`SVG sprite compiler produced empty "${spriteName}"`);
          return resource;
        }
      }
    }

    throw new Error(`SVG sprite compiler did not produce "${spriteName}"`);
  };

  const xmlTextEntities = {
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;"
  };

  const escapeXmlText = (value) => value.replace(/[&<>]/g, (character) => xmlTextEntities[character]);

  const assertUniqueSpriteIDs = (contents, spriteName) => {
    const ids = new Set();

    for (const [, id] of contents.toString().matchAll(/\sid="([^"]+)"/g)) {
      if (ids.has(id)) throw new Error(`Duplicate ID "${id}" in SVG sprite "${spriteName}"`);
      ids.add(id);
    }
  };

  const addSpriteMetadata = async (contents, metadataFile) => {
    if (!metadataFile) return contents;

    if (!(await exists(metadataFile))) {
      throw new Error(`Unknown SVG sprite metadata file "${metadataFile}"`);
    }

    const svg = Buffer.isBuffer(contents) ? contents : Buffer.from(contents);
    const openingEnd = svg.indexOf(62);

    if (svg.subarray(0, 4).toString() !== "<svg" || openingEnd < 0) {
      throw new Error("SVG sprite output is missing its root element");
    }

    const metadata = escapeXmlText(await Bun.file(metadataFile).text());

    return Buffer.concat([
      svg.subarray(0, openingEnd + 1),
      Buffer.from(`<metadata>${metadata}</metadata>`),
      svg.subarray(openingEnd + 1)
    ]);
  };

  const emitSprite = async ({ entries: extraSources, metadataFile, mode, namespaceIDs, sourceDir, spriteName }) => {
    const files = sourceDir ? await spriteSourceFiles(sourceDir) : [];

    if (files.length === 0 && extraSources.length === 0) return;

    const spriter = await createSpriter(mode, spriteName, namespaceIDs);
    const extraNames = sourceDir && extraSources.length > 0 ? new Set() : null;

    if (extraNames) {
      for (const entry of extraSources) extraNames.add(entry.name);
    }

    for (const file of files) {
      if (!extraNames || !extraNames.has(path.relative(sourceDir, file))) await addSpriteFile(spriter, sourceDir, file);
    }

    for (const entry of extraSources) await addSpriteEntry(spriter, entry);

    const { result } = await spriter.compileAsync();
    const resource = spriteResource(result, spriteName);

    if (namespaceIDs) assertUniqueSpriteIDs(resource.contents, spriteName);
    await emit("svg", `assets/svg/${spriteName}`, await addSpriteMetadata(resource.contents, metadataFile));
  };

  const localSpriteSpecs = async () => {
    const spritesDir = path.join(assetsDir, "svg", "sprites");

    if (!(await exists(spritesDir))) return [];

    const specs = [];

    for (const entry of await readdir(spritesDir, { withFileTypes: true })) {
      if (!entry.isDirectory() || entry.name.startsWith(".")) continue;

      specs.push({
        mode: entry.name === "app" ? "stack" : "symbol",
        sourceDir: path.join(spritesDir, entry.name),
        spriteName: `${entry.name}.svg`
      });
    }

    return specs.sort((a, b) => a.spriteName.localeCompare(b.spriteName));
  };

  const addSpriteGroup = (groups, mode, spriteName, sourceDir = null) => {
    if (!groups.has(spriteName)) {
      groups.set(spriteName, {
        configured: false,
        entries: [],
        metadataFile: null,
        mode,
        namespaceIDs: true,
        sourceDir,
        spriteName
      });
    } else if (sourceDir) {
      groups.get(spriteName).sourceDir ||= sourceDir;
    }

    return groups.get(spriteName);
  };

  const configureSpriteGroup = (group, entry) => {
    if (!group.configured) {
      if (group.sourceDir && group.mode !== entry.mode) {
        throw new Error(`Conflicting SVG sprite modes for "${group.spriteName}"`);
      }

      group.configured = true;
      group.metadataFile = entry.metadataFile;
      group.namespaceIDs = entry.namespaceIDs;
    } else if (
      group.metadataFile !== entry.metadataFile ||
      group.mode !== entry.mode ||
      group.namespaceIDs !== entry.namespaceIDs
    ) {
      throw new Error(`Conflicting SVG sprite options for "${group.spriteName}"`);
    }

    return group;
  };

  const spriteGroups = async () => {
    const groups = new Map();

    for (const spec of await localSpriteSpecs()) addSpriteGroup(groups, spec.mode, spec.spriteName, spec.sourceDir);

    for (const entry of spriteGroupEntries) {
      configureSpriteGroup(addSpriteGroup(groups, entry.mode, entry.sprite), entry);
    }

    for (const entry of spriteSourceEntries) {
      const group = groups.get(entry.sprite);

      if (!group?.configured) throw new Error(`Missing SVG sprite group for "${entry.sprite}"`);
      group.entries.push(entry);
    }

    return groups.values();
  };

  const jsEntries = entries("PHOENIX_ASSET_PIPELINE_JS");
  const cssEntries = entries("PHOENIX_ASSET_PIPELINE_CSS");

  if (jsEntries.length > 0) await buildJs(jsEntries);
  await Promise.all(cssEntries.map(buildCss));

  if (buildSvg) {
    await buildDirectSvgRoot(path.join(assetsDir, "svg"), "");

    for (const group of await spriteGroups()) {
      await emitSprite(group);
    }
  }
  """

  @css_ext ".css"
  @css_source_prefixes ["css/", "js/", "svg/"]
  @entry_exts ~w(.cjs .cts .js .jsx .mjs .mts .ts .tsx)
  @asset_mode if(Config.manifest_mode() == :precompiled,
                do: :prod,
                else: :dev
              )
  @install_args if(@asset_mode == :prod, do: ~w(install --frozen-lockfile), else: ~w(install))
  @minify_js if(@asset_mode == :prod, do: "1", else: "0")
  @node_env if(@asset_mode == :prod, do: "production", else: "development")
  @install_lock {__MODULE__, :install}
  @install_cache_file "bun_install.term"
  @output_cache_file "bun_assets.term"
  @path_delimiter if(match?({:win32, _}, :os.type()), do: ";", else: ":")
  @script_fingerprint :crypto.hash(:sha256, @script)

  def build(assets_dir, sprite_sources), do: build(assets_dir, sprite_sources, nil, nil)

  @doc false
  def build(assets_dir, sprite_sources, asset_terms, colocated_terms) do
    js_entries = asset_entries(assets_dir, "js", @entry_exts)
    css_entries = asset_entries(assets_dir, "css", [@css_ext])

    svg_signature =
      if is_list(asset_terms),
        do: source_terms_signature(asset_terms, "svg/", [".svg"]),
        else: source_signature(Path.join(assets_dir, "svg"), [".svg"])

    if js_entries == [] and css_entries == [] and svg_signature == [] and sprite_sources == [] do
      []
    else
      ensure_package_json!(assets_dir)
      bun_fingerprint = BunRuntime.ensure_fingerprint!()

      build_cached(
        assets_dir,
        js_entries,
        css_entries,
        sprite_sources,
        svg_signature,
        bun_fingerprint,
        asset_terms,
        colocated_terms
      )
    end
  end

  @doc false
  def fingerprint(assets_dir \\ Config.assets_dir()) do
    {build_fingerprint(BunRuntime.fingerprint()), dependency_sources_signature(assets_dir)}
  end

  defp asset_entries(assets_dir, dir, exts) do
    assets_dir
    |> Path.join(dir)
    |> entries(exts)
    |> Enum.map(&Path.relative_to(&1, assets_dir))
  end

  defp build_cached(
         assets_dir,
         js_entries,
         css_entries,
         sprite_sources,
         svg_signature,
         bun_fingerprint,
         asset_terms,
         colocated_terms
       ) do
    install_signature = ensure_dependencies(assets_dir, bun_fingerprint)
    build_fingerprint = build_fingerprint(bun_fingerprint)
    source_cache = read_output_cache(build_fingerprint)

    css_signature = source_signature_for(css_entries, asset_terms, assets_dir, @css_source_prefixes)
    css_colocated_signature = source_signature_for(css_entries, colocated_terms, Config.colocated_dir())
    lib_signature = lib_signature(css_entries, assets_dir)
    source_digests = source_digest_map(js_entries, assets_dir, asset_terms, colocated_terms)

    js_key = js_cache_key(js_entries, install_signature)

    css_key =
      cache_key(
        :css,
        css_entries,
        install_signature,
        css_signature,
        lib_signature,
        css_colocated_signature
      )

    svg_key = svg_cache_key(sprite_sources, install_signature, svg_signature)

    {js_assets, js_dependencies, build_js?} = cached_js_assets(source_cache, js_key, source_digests)
    {css_assets, build_css?} = cached_assets(source_cache, css_key)
    {svg_assets, build_svg?} = cached_assets(source_cache, svg_key)

    built_assets =
      build_missing_assets(
        assets_dir,
        js_entries,
        css_entries,
        sprite_sources,
        build_js?,
        build_css?,
        build_svg?
      )

    js_assets = select_assets(build_js?, built_assets.js, js_assets)
    js_dependencies = select_dependencies(build_js?, built_assets.js_dependencies, js_dependencies, source_digests)
    css_assets = select_assets(build_css?, built_assets.css, css_assets)
    svg_assets = select_assets(build_svg?, built_assets.svg, svg_assets)

    cache =
      %{}
      |> put_cached_js(js_key, js_dependencies, js_assets)
      |> put_cached_assets(css_key, css_assets)
      |> put_cached_assets(svg_key, svg_assets)

    save_output_cache(cache, source_cache, build_fingerprint)

    js_assets ++ css_assets ++ svg_assets
  end

  defp build_fingerprint(bun_fingerprint) do
    {@script_fingerprint, @asset_mode, @node_env, Config.js_drop(), node_path(), bun_fingerprint}
  end

  defp build_missing_assets(_, _, _, _, false, false, false), do: %{css: [], js: [], js_dependencies: [], svg: []}

  defp build_missing_assets(assets_dir, js_entries, css_entries, sprite_sources, build_js?, build_css?, build_svg?) do
    run(
      assets_dir,
      select_entries(build_js?, js_entries),
      select_entries(build_css?, css_entries),
      select_entries(build_svg?, sprite_sources),
      build_svg?,
      select_entries(build_js?, js_drop())
    )
  end

  defp lib_signature([], _), do: []

  defp lib_signature(_, assets_dir) do
    {PhoenixAssetPipeline.Components.module_info(:md5), source_signature(project_lib_dir(assets_dir), ~w(.ex .heex))}
  end

  defp select_assets(true, built, _), do: built
  defp select_assets(false, _, cached), do: cached

  defp select_dependencies(true, paths, _, source_digests) do
    Enum.map(paths, &{&1, source_digest(&1, source_digests)})
  end

  defp select_dependencies(false, _, cached, _), do: cached

  defp select_entries(true, entries), do: entries
  defp select_entries(false, _), do: []

  defp svg_cache_key([], _, []), do: nil

  defp svg_cache_key(sprite_sources, install_signature, svg_signature) do
    {:svg, install_signature, svg_signature, Sprites.signature(sprite_sources)}
  end

  defp js_cache_key([], _), do: nil
  defp js_cache_key(entries, install_signature), do: {:js, entries, install_signature}

  defp cache_key(_, [], _, _, _, _), do: nil
  defp cache_key(type, entries, first, second, third, fourth), do: {type, entries, first, second, third, fourth}

  defp cached_assets(_, nil), do: {[], false}

  defp cached_assets(cache, key) do
    case Map.fetch(cache, key) do
      {:ok, assets} -> {assets, false}
      :error -> {[], true}
    end
  end

  defp cached_js_assets(_, nil, _), do: {[], [], false}

  defp cached_js_assets(cache, key, source_digests) do
    case Map.fetch(cache, key) do
      {:ok, {dependencies, assets}} ->
        if dependencies_current?(dependencies, source_digests),
          do: {assets, dependencies, false},
          else: {[], [], true}

      _ ->
        {[], [], true}
    end
  end

  defp dependencies_current?([], _), do: true

  defp dependencies_current?([{path, digest} | dependencies], source_digests) when is_binary(path) do
    source_digest(path, source_digests) == digest and dependencies_current?(dependencies, source_digests)
  end

  defp dependencies_current?(_, _), do: false

  defp ensure_dependencies(assets_dir, bun_fingerprint) do
    :global.trans(
      {{@install_lock, Path.expand(assets_dir)}, self()},
      fn ->
        signature = install_signature(assets_dir, bun_fingerprint)
        ensure_dependencies_unlocked(assets_dir, signature, bun_fingerprint)
      end,
      [node()],
      :infinity
    )
  end

  defp ensure_dependencies_unlocked(assets_dir, signature, bun_fingerprint) do
    install_dependencies(assets_dir, signature, bun_fingerprint, install_required?(assets_dir, signature))
  end

  defp install_dependencies(_, signature, _, false), do: signature

  defp install_dependencies(assets_dir, _, bun_fingerprint, true) do
    :ok = run_bun_install(assets_dir, @install_args)
    signature = install_signature(assets_dir, bun_fingerprint)
    save_install_cache(assets_dir, signature)
    signature
  end

  defp ensure_package_json!(assets_dir) do
    if !File.regular?(Path.join(assets_dir, "package.json")) do
      raise "missing assets/package.json for PhoenixAssetPipeline Bun asset builds"
    end

    if @asset_mode == :prod and !File.regular?(Path.join(assets_dir, "bun.lock")) do
      raise "missing assets/bun.lock for production PhoenixAssetPipeline builds"
    end
  end

  defp entries(dir, exts) do
    case File.ls(dir) do
      {:ok, files} ->
        entries(files, dir, exts)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        raise File.Error, reason: reason, action: "list asset entries", path: dir
    end
  end

  defp entries(files, dir, exts) do
    files
    |> Enum.reduce([], fn file, entries ->
      path = Path.join(dir, file)

      case entry_file?(path, exts) and File.stat(path) do
        false -> entries
        {:ok, %{type: :regular}} -> [path | entries]
        {:ok, _} -> entries
        {:error, :enoent} -> entries
        {:error, reason} -> raise File.Error, reason: reason, action: "stat asset entry", path: path
      end
    end)
    |> Enum.sort()
  end

  defp entry_file?(path, exts) do
    basename = Path.basename(path)

    not String.starts_with?(basename, [".", "_"]) and
      Path.extname(path) in exts
  end

  defp file_digest(path) do
    case File.read(path) do
      {:ok, content} -> :erlang.md5(content)
      {:error, :enoent} -> :missing
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp forward_path(path), do: String.replace(path, "\\", "/")

  defp install_cache_path do
    Path.join(Config.manifest_cache_dir(), @install_cache_file)
  end

  defp install_cache_record(assets_dir, signature), do: {Path.expand(assets_dir), signature}

  defp install_required?(assets_dir, signature) do
    not File.dir?(Path.join(assets_dir, "node_modules")) or
      read_install_cache() != {:ok, {Path.expand(assets_dir), signature}}
  end

  defp install_signature(assets_dir, bun_fingerprint) do
    [{:bun, bun_fingerprint} | dependency_sources_signature(assets_dir)]
  end

  defp dependency_sources_signature(assets_dir) do
    assets_dir = Path.expand(assets_dir)

    [
      {"package.json", file_digest(Path.join(assets_dir, "package.json"))},
      {"bun.lock", file_digest(Path.join(assets_dir, "bun.lock"))}
    ]
  end

  defp js_drop, do: Config.js_drop()

  defp mix_deps_path do
    if Code.ensure_loaded?(Mix.Project) do
      config = Mix.Project.config()
      if config[:app], do: Mix.Project.deps_path(config)
    end
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  defp node_path do
    [
      System.get_env("NODE_PATH"),
      Config.build_path(),
      mix_deps_path() || Path.join(Config.project_dir(), "deps")
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(@path_delimiter)
  end

  defp output_cache_path do
    Path.join(Config.manifest_cache_dir(), @output_cache_file)
  end

  defp parse_output(output, output_dir) do
    assets = parse_output(output, output_dir, %{css: [], js: [], js_dependencies: [], svg: []})

    %{
      css: Enum.sort(assets.css),
      js: Enum.sort(assets.js),
      js_dependencies: Enum.sort(assets.js_dependencies),
      svg: Enum.sort(assets.svg)
    }
  end

  defp parse_output("", _, assets), do: assets

  defp parse_output(output, output_dir, assets) do
    {line, rest} = take_output_line(output)
    [group, path, output_name] = :binary.split(line, "\t", [:global])

    if group == "dependency" do
      dependency = dependency_path!(path, output_name)
      parse_output(rest, output_dir, %{assets | js_dependencies: [dependency | assets.js_dependencies]})
    else
      group = output_group!(group)
      asset = {Base.decode64!(path), File.read!(output_path!(output_dir, output_name))}
      parse_output(rest, output_dir, Map.update!(assets, group, &[asset | &1]))
    end
  end

  defp dependency_path!(path, "js") do
    path = Base.decode64!(path)
    if Path.type(path) == :absolute, do: path, else: raise("bun asset build returned a relative dependency path")
  end

  defp dependency_path!(_, _), do: raise("bun asset build returned an invalid dependency group")

  defp output_group!("css"), do: :css
  defp output_group!("js"), do: :js
  defp output_group!("svg"), do: :svg
  defp output_group!(_), do: raise("bun asset build returned an invalid output group")

  defp output_path!(output_dir, output_name) do
    case Integer.parse(output_name) do
      {index, ""} when index >= 0 ->
        if Integer.to_string(index) == output_name,
          do: Path.join(output_dir, output_name),
          else: raise("bun asset build returned an invalid output reference")

      _ ->
        raise "bun asset build returned an invalid output reference"
    end
  end

  defp take_output_line(output) do
    case :binary.match(output, "\n") do
      {index, 1} ->
        line = binary_part(output, 0, index)
        {line, binary_part(output, index + 1, byte_size(output) - index - 1)}

      :nomatch ->
        {output, ""}
    end
  end

  defp project_dir(assets_dir), do: Path.dirname(Path.expand(assets_dir))
  defp project_lib_dir(assets_dir), do: assets_dir |> project_dir() |> Path.join("lib")

  defp put_cached_assets(cache, nil, _), do: cache
  defp put_cached_assets(cache, key, assets), do: Map.put(cache, key, assets)

  defp put_cached_js(cache, nil, _, _), do: cache
  defp put_cached_js(cache, key, dependencies, assets), do: Map.put(cache, key, {dependencies, assets})

  defp read_install_cache do
    Cache.read_term(install_cache_path(), :error, fn
      {assets_dir, signature} when is_binary(assets_dir) and is_list(signature) -> {:ok, {:ok, {assets_dir, signature}}}
      _ -> :error
    end)
  end

  defp read_output_cache(fingerprint) do
    Cache.read_term(output_cache_path(), %{}, fn
      {^fingerprint, cache} when is_map(cache) -> {:ok, cache}
      _ -> :error
    end)
  end

  defp regular_entry(_, "." <> _), do: []
  defp regular_entry(_, "node_modules"), do: []

  defp regular_entry(dir, entry) do
    path = Path.join(dir, entry)

    case File.stat(path) do
      {:ok, %{type: :directory}} -> regular_files_in(path)
      {:ok, %{type: :regular}} -> [path]
      {:ok, _} -> []
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "stat asset dependency", path: path
    end
  end

  defp regular_files(dir) do
    dir
    |> Path.expand()
    |> regular_files_in()
    |> Enum.sort()
  end

  defp regular_files_in(dir) do
    case File.ls(dir) do
      {:ok, entries} -> Enum.flat_map(entries, &regular_entry(dir, &1))
      {:error, :enoent} -> []
      {:error, reason} -> raise File.Error, reason: reason, action: "list asset dependencies", path: dir
    end
  end

  defp run(assets_dir, js_entries, css_entries, sprite_sources, svg?, js_drop) do
    output_dir = output_dir()

    env = [
      {"NODE_ENV", @node_env},
      {"NODE_PATH", node_path()},
      {"PHOENIX_ASSET_PIPELINE_CSS", Enum.join(css_entries, "\n")},
      {"PHOENIX_ASSET_PIPELINE_JS", Enum.join(js_entries, "\n")},
      {"PHOENIX_ASSET_PIPELINE_JS_DROP", Enum.join(js_drop, "\n")},
      {"PHOENIX_ASSET_PIPELINE_MINIFY_JS", @minify_js},
      {"PHOENIX_ASSET_PIPELINE_OUTPUT_DIR", output_dir},
      {"PHOENIX_ASSET_PIPELINE_SVG", if(svg?, do: "1", else: "0")},
      {"PHOENIX_ASSET_PIPELINE_SVG_SPRITE_SOURCES", sprite_source_env(sprite_sources)}
    ]

    File.mkdir_p!(output_dir)

    try do
      case run_bun(["--eval", @script], cd: assets_dir, env: env) do
        {output, 0} -> parse_output(output, output_dir)
        {output, status} -> raise "bun asset build exited with #{status}\n#{output}"
      end
    after
      File.rm_rf!(output_dir)
    end
  end

  defp output_dir do
    unique = System.unique_integer([:monotonic, :positive])
    Path.join(Config.manifest_cache_dir(), ".bun-output-#{System.pid()}-#{unique}")
  end

  defp run_bun(args, opts) do
    BunRuntime.run_ready(args, opts)
  end

  defp run_bun_install(assets_dir, args) do
    case run_bun(args, cd: assets_dir, stderr_to_stdout: true) do
      {output, 0} ->
        IO.write(output)
        :ok

      {output, status} ->
        raise "bun install exited with #{status}\n#{output}"
    end
  end

  defp save_install_cache(assets_dir, signature) do
    Cache.write_term!(install_cache_path(), install_cache_record(assets_dir, signature))
  end

  defp save_output_cache(cache, cache, _), do: :ok

  defp save_output_cache(cache, _, fingerprint) do
    Cache.write_term!(output_cache_path(), {fingerprint, cache})
  end

  defp sprite_source_env(sprite_sources) do
    Enum.map_join(
      sprite_sources,
      "\n",
      fn
        {:svg_sprite_group, sprite, mode, namespace_ids?, metadata_path, _} ->
          Enum.join(["g", sprite, mode, if(namespace_ids?, do: "1", else: "0"), metadata_path], "\t")

        {:svg_sprite_source, sprite, path, name, _, _, _} ->
          Enum.join(["s", sprite, path, name], "\t")
      end
    )
  end

  defp source_signature(dir) do
    dir
    |> regular_files()
    |> Enum.map(&{&1 |> Path.relative_to(dir) |> forward_path(), file_digest(&1)})
  end

  defp source_signature(dir, exts) do
    dir
    |> regular_files()
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in exts))
    |> Enum.map(&{&1 |> Path.relative_to(dir) |> forward_path(), file_digest(&1)})
  end

  defp source_signature_for([], _, _), do: []
  defp source_signature_for(_, terms, _) when is_list(terms), do: Enum.map(terms, &source_term_signature/1)
  defp source_signature_for(_, _, dir), do: source_signature(dir)

  defp source_signature_for([], _, _, _), do: []

  defp source_signature_for(_, terms, _, prefixes) when is_list(terms) do
    source_terms_signature(terms, prefixes)
  end

  defp source_signature_for(_, _, dir, prefixes), do: source_prefix_signature(dir, prefixes)

  defp source_digest_map([], _, _, _), do: %{}

  defp source_digest_map(_, assets_dir, asset_terms, colocated_terms) do
    {
      Path.expand(assets_dir),
      source_term_digest_map(asset_terms),
      Config.build_path(),
      source_term_digest_map(colocated_terms)
    }
  end

  defp source_term_digest_map(terms) when is_list(terms) do
    Map.new(terms, &source_term_digest_pair/1)
  end

  defp source_term_digest_map(_), do: %{}

  defp source_term_digest_pair({_, path, digest}), do: {path, digest}
  defp source_term_digest_pair({_, path, digest, _}), do: {path, digest}

  defp source_digest(path, {assets_dir, asset_digests, build_path, colocated_digests}) do
    case source_digest(path, assets_dir, asset_digests) do
      :error ->
        case source_digest(path, build_path, colocated_digests) do
          :error -> file_digest(path)
          {:ok, digest} -> digest
        end

      {:ok, digest} ->
        digest
    end
  end

  defp source_digest(path, root, digests) do
    relative = Path.relative_to(path, root)
    if Path.type(relative) == :relative, do: Map.fetch(digests, forward_path(relative)), else: :error
  end

  defp source_term_signature({type, path, digest, _}), do: {type, path, digest}
  defp source_term_signature(term), do: term

  defp source_terms_signature(terms, prefix, exts) do
    terms
    |> Enum.reduce([], fn
      {_, path, _} = term, signature ->
        if String.starts_with?(path, prefix) and String.downcase(Path.extname(path)) in exts,
          do: [term | signature],
          else: signature

      _, signature ->
        signature
    end)
    |> :lists.reverse()
  end

  defp source_terms_signature(terms, prefixes) do
    terms
    |> Enum.reduce([], fn
      {_, path, _} = term, signature ->
        if String.starts_with?(path, prefixes), do: [term | signature], else: signature

      {_, path, _, _} = term, signature ->
        if String.starts_with?(path, prefixes),
          do: [source_term_signature(term) | signature],
          else: signature

      _, signature ->
        signature
    end)
    |> :lists.reverse()
  end

  defp source_prefix_signature(dir, prefixes) do
    dir
    |> regular_files()
    |> Enum.reduce([], fn path, signature ->
      relative = path |> Path.relative_to(dir) |> forward_path()

      if String.starts_with?(relative, prefixes),
        do: [{relative, file_digest(path)} | signature],
        else: signature
    end)
    |> :lists.reverse()
  end
end
