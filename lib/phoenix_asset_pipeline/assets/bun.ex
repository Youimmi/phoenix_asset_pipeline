defmodule PhoenixAssetPipeline.Assets.Bun do
  @moduledoc false

  alias PhoenixAssetPipeline.Assets.Sprites
  alias PhoenixAssetPipeline.Bun, as: BunRuntime
  alias PhoenixAssetPipeline.Cache
  alias PhoenixAssetPipeline.Config
  alias PhoenixAssetPipeline.Digest
  alias PhoenixAssetPipeline.Files

  @script ~S"""
  import path from "node:path";
  import { stat, readdir } from "node:fs/promises";

  const assetsDir = process.cwd();
  const outputDir = process.env.PHOENIX_ASSET_PIPELINE_OUTPUT_DIR;
  const minifyJs = process.env.PHOENIX_ASSET_PIPELINE_MINIFY_JS === "1";
  const entries = (name) => (process.env[name] || "").split("\n").filter(Boolean);
  const dropJs = entries("PHOENIX_ASSET_PIPELINE_JS_DROP");
  const buildSvg = process.env.PHOENIX_ASSET_PIPELINE_SVG === "1";
  const svgoOptions = {
    multipass: true,
    plugins: [{
      name: "preset-default",
      params: {
        overrides: {
          convertPathData: { applyTransforms: false },
          convertTransform: false,
          moveGroupAttrsToElems: false
        }
      }
    }]
  };
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
    const outputName = String(outputIndex++);

    await Bun.write(path.join(outputDir, outputName), content);
    process.stdout.write(`${group}\t${Buffer.from(filePath).toString("base64")}\t${outputName}\n`);
  };

  const emitDependency = (kind, source, group) => {
    process.stdout.write(`${kind}\t${Buffer.from(typeof source === "string" ? source : JSON.stringify(source)).toString("base64")}\t${group}\n`);
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

  const inventoryPattern = (pattern) => pattern.endsWith("}")
    ? pattern.slice(0, -1) + ",gitignore}"
    : pattern.replace(/\*\.([^/{}]+)$/, "*.{$1,gitignore}");

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
    const checked = Bun.spawnSync({
      cmd: [process.execPath, "--no-orphans", "check", "--listFiles", "--no-pretty", "--allowJs", ...jsEntries],
      cwd: assetsDir,
      env: { ...process.env, npm_lifecycle_event: "check" },
      stdout: "pipe",
      stderr: "pipe"
    });

    if (checked.exitCode !== 0) {
      throw new Error(`Type checking failed\n${checked.stdout.toString()}${checked.stderr.toString()}`);
    }

    const dependencies = new Set();
    const directories = new Set();

    for (const file of checked.stdout.toString().split("\n")) {
      if (path.isAbsolute(file) && !file.split(path.sep).includes("node_modules")) dependencies.add(file);
    }

    const result = await Bun.build({
      entrypoints: jsEntries,
      drop: dropJs,
      format: "esm",
      metafile: true,
      minify: minifyJs,
      plugins: [{
        name: "phoenix-asset-dependencies",
        setup(build) {
          build.onResolve({ filter: /^(?:\.{1,2}\/|\/)/ }, ({ path: specifier, resolveDir }) => {
            directories.add(path.dirname(path.resolve(resolveDir, specifier)));
          });
        }
      }],
      sourcemap: "none",
      splitting: false,
      target: "browser"
    });

    if (!result.success) {
      for (const log of result.logs) console.error(log);
      process.exit(1);
    }

    const configs = new Set();
    const configDirs = new Map();
    const packageDirs = new Set();
    const projectDir = path.dirname(assetsDir);
    const addPackages = async (dir) => {
      while (!packageDirs.has(dir)) {
        packageDirs.add(dir);
        const packagePath = path.join(dir, "package.json");

        if (dir === projectDir || dir.startsWith(projectDir + path.sep) || await Bun.file(packagePath).exists()) {
          dependencies.add(packagePath);
        }

        const parent = path.dirname(dir);
        if (dir === parent) break;
        dir = parent;
      }
    };
    const findConfig = async (dir) => {
      if (configDirs.has(dir)) return configDirs.get(dir);

      for (const name of ["tsconfig.json", "jsconfig.json"]) {
        const configPath = path.join(dir, name);
        const present = await Bun.file(configPath).exists();
        if (present || dir === projectDir || dir.startsWith(projectDir + path.sep)) dependencies.add(configPath);

        if (present) {
          configDirs.set(dir, configPath);
          return configPath;
        }
      }

      const parent = path.dirname(dir);
      const configPath = dir === parent ? null : await findConfig(parent);
      configDirs.set(dir, configPath);
      return configPath;
    };
    const addConfig = async (configPath) => {
      if (configs.has(configPath)) return;
      configs.add(configPath);
      dependencies.add(configPath);

      const config = Bun.JSONC.parse(await Bun.file(configPath).text());
      const bases = typeof config.extends === "string" ? [config.extends] : config.extends || [];

      for (const base of bases) await addConfig(Bun.resolveSync(base, path.dirname(configPath)));
    };

    for (const input of Object.keys(result.metafile.inputs)) {
      const inputPath = path.isAbsolute(input) ? input : path.resolve(assetsDir, input);
      if (inputPath.split(path.sep).includes("node_modules")) continue;
      dependencies.add(inputPath);
    }

    for (const inputPath of dependencies) {
      directories.add(path.dirname(inputPath));
      if (path.basename(inputPath).startsWith("index.")) directories.add(path.dirname(path.dirname(inputPath)));
      await addPackages(path.dirname(inputPath));

      const configPath = await findConfig(path.dirname(inputPath));
      if (configPath) await addConfig(configPath);
    }

    dependencies.add(path.join(assetsDir, "bunfig.toml"));

    for (const dependency of dependencies) emitDependency("dependency", dependency, "js");
    for (const directory of directories) emitDependency("directory", directory, "js");

    for (const artifact of result.outputs) {
      const artifactPath = artifact.path;
      const ext = path.extname(artifactPath).toLowerCase();

      if (ext === ".js" || ext === ".mjs" || ext === ".cjs") {
        const name = `${path.basename(artifactPath, path.extname(artifactPath))}.js`;
        await emit("js", `assets/js/${name}`, artifact);
      } else if (ext === ".css") {
        await emit("js", `assets/css/${path.basename(artifactPath)}`, artifact);
      } else {
        throw new Error(`Unsupported Bun output ${artifactPath}: only JavaScript and CSS imports are supported`);
      }
    }
  };

  const buildCss = async (entry) => {
    const { compile, optimize } = await import("@tailwindcss/node");
    const { Scanner } = await import("@tailwindcss/oxide");
    const input = path.resolve(assetsDir, entry);
    const dependencies = new Set([input]);
    const compiler = await compile(await Bun.file(input).text(), {
      base: path.dirname(input),
      from: input,
      onDependency: (file) => dependencies.add(file)
    });
    const sources = compiler.root === "none" ? [] : [compiler.root ?? { base: assetsDir, pattern: "**/*" }];
    const scanner = new Scanner({ sources: sources.map((source) => ({ ...source, negated: false })).concat(
      compiler.sources,
      { base: path.dirname(input), pattern: path.basename(input), negated: false },
      { base: path.dirname(process.execPath), pattern: path.basename(process.execPath), negated: true }
    ) });
    const css = compiler.build(scanner.scan());

    for (const file of scanner.files) dependencies.add(file);
    for (const dependency of dependencies) emitDependency("dependency", dependency, "css");
    for (const { base, pattern } of scanner.globs) {
      if (!pattern.startsWith("{")) emitDependency("glob", [base, inventoryPattern(pattern)], "css");

      let directory = base;

      while (true) {
        emitDependency("dependency", path.join(directory, ".gitignore"), "css");
        if (directory === path.dirname(assetsDir)) break;
        const parent = path.dirname(directory);
        if (parent === directory) break;
        directory = parent;
      }
    }

    for (const { base, pattern } of scanner.normalizedSources) {
      if (pattern === "**/*") emitDependency("directory", base, "css");
      else emitDependency("glob", [base, inventoryPattern(pattern.replace(/^\/+/, ""))], "css");
    }

    await emit("css", `assets/css/${path.basename(entry)}`, optimize(css, { file: input, minify: true }).code);
  };

  const optimizeSvg = async (filePath) => {
    const { optimize } = await import("svgo");
    const result = optimize(await Bun.file(filePath).text(), {
      ...svgoOptions,
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
        transform: [{ svgo: svgoOptions }]
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
          rootviewbox: mode !== "stack",
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
      group.configured = true;
      group.metadataFile = entry.metadataFile;
      group.mode = entry.mode;
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
  @entry_exts ~w(.cjs .cts .js .jsx .mjs .mts .ts .tsx)
  @asset_mode if(Config.precompiled_manifest?(),
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
  def fingerprint(assets_dir, asset_terms, colocated_terms) do
    fingerprint = build_fingerprint(BunRuntime.fingerprint(), assets_dir)

    dependencies =
      fingerprint
      |> read_output_cache()
      |> cached_dependencies()
      |> dependency_signature(assets_dir, asset_terms, colocated_terms)

    {fingerprint, dependency_sources_signature(assets_dir), dependencies}
  end

  @doc false
  def watch_sources(assets_dir \\ Config.assets_dir()) do
    BunRuntime.fingerprint()
    |> build_fingerprint(assets_dir)
    |> read_output_cache()
    |> cached_dependencies()
    |> Enum.reduce({[], []}, fn
      {{:directory, path}, _}, {dirs, files} -> {[watch_dir(path) | dirs], files}
      {{:glob, path, _}, _}, {dirs, files} -> {[watch_dir(path) | dirs], files}
      {path, _}, {dirs, files} -> {dirs, [path | files]}
    end)
  end

  defp asset_entries(assets_dir, dir, exts) do
    assets_dir
    |> Path.join(dir)
    |> entries(exts)
    |> Enum.map(&Files.relative_path(&1, assets_dir))
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
    build_fingerprint = build_fingerprint(bun_fingerprint, assets_dir)
    source_cache = read_output_cache(build_fingerprint)

    source_digests = source_digest_map(assets_dir, asset_terms, colocated_terms)
    js_key = cache_key(:js, js_entries, install_signature)
    css_key = cache_key(:css, css_entries, install_signature)

    svg_key = svg_cache_key(sprite_sources, install_signature, svg_signature)

    {js_assets, js_dependencies, build_js?} = cached_assets(source_cache, js_key, source_digests)
    {css_assets, css_dependencies, build_css?} = cached_assets(source_cache, css_key, source_digests)
    {svg_assets, _, build_svg?} = cached_assets(source_cache, svg_key, source_digests)

    built_assets =
      build_missing_assets(
        {assets_dir, js_entries, css_entries, sprite_sources},
        {build_js?, build_css?, build_svg?},
        {js_dependencies, css_dependencies},
        3
      )

    js_assets = select_assets(build_js?, built_assets.js, js_assets)
    js_dependencies = select_assets(build_js?, built_assets.js_dependencies, js_dependencies)
    css_assets = select_assets(build_css?, built_assets.css, css_assets)
    css_dependencies = select_assets(build_css?, built_assets.css_dependencies, css_dependencies)
    svg_assets = select_assets(build_svg?, built_assets.svg, svg_assets)

    cache =
      %{}
      |> put_cached_assets(js_key, js_dependencies, js_assets)
      |> put_cached_assets(css_key, css_dependencies, css_assets)
      |> put_cached_assets(svg_key, [], svg_assets)

    save_output_cache(cache, source_cache, build_fingerprint)

    js_assets ++ css_assets ++ svg_assets
  end

  defp build_fingerprint(bun_fingerprint, assets_dir) do
    {Path.expand(assets_dir), @script_fingerprint, @asset_mode, @node_env, Config.js_drop(), node_path(), bun_fingerprint}
  end

  defp build_missing_assets(_, {false, false, false}, _, _),
    do: %{css: [], css_dependencies: [], js: [], js_dependencies: [], svg: []}

  defp build_missing_assets(_, _, _, 0), do: raise("asset dependencies changed repeatedly during build")

  defp build_missing_assets(
         {assets_dir, js_entries, css_entries, sprite_sources} = inputs,
         {build_js?, build_css?, build_svg?},
         {js_dependencies, css_dependencies},
         attempts
       ) do
    js_before = Map.new(select_entries(build_js?, js_dependencies), fn {path, _} -> {path, source_digest(path, nil)} end)

    css_before =
      Map.new(select_entries(build_css?, css_dependencies), fn {path, _} -> {path, source_digest(path, nil)} end)

    assets =
      run(
        assets_dir,
        select_entries(build_js?, js_entries),
        select_entries(build_css?, css_entries),
        select_entries(build_svg?, sprite_sources),
        build_svg?,
        select_entries(build_js?, js_drop())
      )

    assets = %{
      assets
      | js_dependencies: dependency_signature(assets.js_dependencies),
        css_dependencies: dependency_signature(assets.css_dependencies)
    }

    retry_js? = build_js? and not dependencies_unchanged?(assets.js_dependencies, js_before)
    retry_css? = build_css? and not dependencies_unchanged?(assets.css_dependencies, css_before)

    if retry_js? or retry_css? do
      retry =
        build_missing_assets(
          inputs,
          {retry_js?, retry_css?, false},
          {assets.js_dependencies, assets.css_dependencies},
          attempts - 1
        )

      %{
        assets
        | js: select_assets(retry_js?, retry.js, assets.js),
          js_dependencies: select_assets(retry_js?, retry.js_dependencies, assets.js_dependencies),
          css: select_assets(retry_css?, retry.css, assets.css),
          css_dependencies: select_assets(retry_css?, retry.css_dependencies, assets.css_dependencies)
      }
    else
      assets
    end
  end

  defp cache_key(_, [], _), do: nil
  defp cache_key(type, entries, signature), do: {type, entries, signature}

  defp cached_assets(_, nil, _), do: {[], [], false}

  defp cached_assets(cache, key, source_digests) do
    case Map.fetch(cache, key) do
      {:ok, {dependencies, assets}} ->
        if dependencies_current?(dependencies, source_digests),
          do: {assets, dependencies, false},
          else: {[], dependencies, true}

      _ ->
        {[], [], true}
    end
  end

  defp cached_dependencies(cache) do
    cache
    |> Enum.flat_map(fn {_, {dependencies, _}} -> dependencies end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp dependencies_current?([], _), do: true

  defp dependencies_current?([{path, digest} | dependencies], source_digests) do
    source_digest(path, source_digests) == digest and dependencies_current?(dependencies, source_digests)
  end

  defp dependencies_current?(_, _), do: false

  defp dependencies_unchanged?(dependencies, before) do
    Enum.all?(dependencies, fn {path, digest} -> Map.fetch(before, path) == {:ok, digest} end)
  end

  defp dependency_group!("css"), do: :css_dependencies
  defp dependency_group!("js"), do: :js_dependencies
  defp dependency_group!(_), do: raise("bun asset build returned an invalid dependency group")

  defp dependency_path!(path) do
    if Path.type(path) == :absolute, do: path, else: raise("bun asset build returned a relative dependency path")
  end

  defp dependency_signature(dependencies) do
    Enum.map(dependencies, &{&1, source_digest(&1, nil)})
  end

  defp dependency_signature([], _, _, _), do: []

  defp dependency_signature(dependencies, assets_dir, asset_terms, colocated_terms) do
    source_digests = source_digest_map(assets_dir, asset_terms, colocated_terms)
    Enum.map(dependencies, fn {path, _} -> {path, source_digest(path, source_digests)} end)
  end

  defp dependency_source!("dependency", path), do: path |> Base.decode64!() |> dependency_path!()
  defp dependency_source!("directory", path), do: {:directory, dependency_source!("dependency", path)}

  defp dependency_source!("glob", path) do
    [base, pattern] = path |> Base.decode64!() |> JSON.decode!()
    {:glob, dependency_path!(base), pattern}
  end

  defp dependency_sources_signature(assets_dir) do
    assets_dir = Path.expand(assets_dir)

    [
      {"package.json", file_digest(Path.join(assets_dir, "package.json"))},
      {"bun.lock", file_digest(Path.join(assets_dir, "bun.lock"))}
    ]
  end

  defp directory_entry(path, file) do
    entry = Path.join(path, file)
    if File.lstat!(entry).type == :symlink, do: {file, File.read_link!(entry)}, else: file
  end

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

      case entry_file?(path, exts) and File.lstat(path) do
        false -> entries
        {:ok, %{type: :regular}} -> [path | entries]
        {:ok, %{type: type}} -> raise ArgumentError, "invalid asset entry type #{inspect(type)}: #{path}"
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
      {:ok, content} -> Digest.binary(content)
      {:error, :enoent} -> :missing
      {:error, reason} -> raise File.Error, reason: reason, action: "read file", path: path
    end
  end

  defp install_cache_path do
    Path.join(Config.manifest_cache_dir(), @install_cache_file)
  end

  defp install_cache_record(assets_dir, signature), do: {Path.expand(assets_dir), signature}

  defp install_dependencies(_, signature, _, false), do: signature

  defp install_dependencies(assets_dir, _, bun_fingerprint, true) do
    :ok = run_bun_install(assets_dir, @install_args)
    signature = install_signature(assets_dir, bun_fingerprint)
    save_install_cache(assets_dir, signature)
    signature
  end

  defp install_required?(assets_dir, signature) do
    not File.dir?(Path.join(assets_dir, "node_modules")) or
      read_install_cache() != {:ok, {Path.expand(assets_dir), signature}}
  end

  defp install_signature(assets_dir, bun_fingerprint) do
    [{:bun, bun_fingerprint} | dependency_sources_signature(assets_dir)]
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

  defp output_dir do
    unique = System.unique_integer([:monotonic, :positive])
    Path.join(Config.manifest_cache_dir(), ".bun-output-#{System.pid()}-#{unique}")
  end

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

  defp parse_output(output, output_dir) do
    assets = parse_output(output, output_dir, %{css: [], css_dependencies: [], js: [], js_dependencies: [], svg: []})

    %{
      css: Enum.sort(assets.css),
      css_dependencies: assets.css_dependencies |> Enum.uniq() |> Enum.sort(),
      js: Enum.sort(assets.js),
      js_dependencies: Enum.sort(assets.js_dependencies),
      svg: Enum.sort(assets.svg)
    }
  end

  defp parse_output("", _, assets), do: assets

  defp parse_output(output, output_dir, assets) do
    {line, rest} = take_output_line(output)
    [group, path, output_name] = :binary.split(line, "\t", [:global])

    if group in ["dependency", "directory", "glob"] do
      dependency = dependency_source!(group, path)
      group = dependency_group!(output_name)
      parse_output(rest, output_dir, Map.update!(assets, group, &[dependency | &1]))
    else
      group = output_group!(group)
      asset = {Base.decode64!(path), File.read!(output_path!(output_dir, output_name))}
      parse_output(rest, output_dir, Map.update!(assets, group, &[asset | &1]))
    end
  end

  defp put_cached_assets(cache, nil, _, _), do: cache
  defp put_cached_assets(cache, key, dependencies, assets), do: Map.put(cache, key, {dependencies, assets})

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

    File.mkdir!(output_dir)

    try do
      case run_bun(["--eval", @script], cd: assets_dir, env: env) do
        {output, 0} -> parse_output(output, output_dir)
        {output, status} -> raise "bun asset build exited with #{status}\n#{output}"
      end
    after
      File.rm_rf!(output_dir)
    end
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

  defp select_assets(true, built, _), do: built
  defp select_assets(false, _, cached), do: cached

  defp select_entries(true, entries), do: entries
  defp select_entries(false, _), do: []

  defp source_digest({:directory, path}, _) do
    case File.ls(path) do
      {:ok, files} ->
        %{inode: inode, major_device: device} = File.stat!(path)

        entries = files |> Enum.map(&directory_entry(path, &1)) |> Enum.sort()
        Digest.term({device, inode, entries})

      {:error, :enoent} ->
        :missing

      {:error, reason} ->
        raise File.Error, reason: reason, action: "list dependency directory", path: path
    end
  end

  defp source_digest({:glob, path, pattern}, _) do
    path
    |> Path.join(pattern)
    |> Path.wildcard(match_dot: true)
    |> Enum.map(fn path ->
      if Path.basename(path) == ".gitignore" and File.regular?(path), do: {path, file_digest(path)}, else: path
    end)
    |> Digest.term()
  end

  defp source_digest(path, nil), do: file_digest(path)

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
    relative = Files.relative_path(path, root)
    if Path.type(relative) == :relative, do: Map.fetch(digests, relative), else: :error
  end

  defp source_digest_map(assets_dir, asset_terms, colocated_terms) do
    {
      Path.expand(assets_dir),
      source_term_digest_map(asset_terms),
      Config.build_path(),
      source_term_digest_map(colocated_terms)
    }
  end

  defp source_signature(dir, exts) do
    dir
    |> Files.regular_files()
    |> Enum.filter(&(String.downcase(Path.extname(&1)) in exts))
    |> Enum.map(&{Files.relative_path(&1, dir), file_digest(&1)})
  end

  defp source_term_digest_map(terms) when is_list(terms) do
    Map.new(terms, &source_term_digest_pair/1)
  end

  defp source_term_digest_map(_), do: %{}

  defp source_term_digest_pair({_, path, digest}), do: {path, digest}
  defp source_term_digest_pair({_, path, digest, _}), do: {path, digest}

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

  defp sprite_source_env(sprite_sources) do
    Enum.map_join(
      sprite_sources,
      "\n",
      fn
        {:svg_sprite_group, sprite, mode, namespace_ids?, metadata_path, _} ->
          Enum.join(["g", sprite, mode, if(namespace_ids?, do: "1", else: "0"), metadata_path], "\t")

        {:svg_sprite_source, sprite, path, name, _, _} ->
          Enum.join(["s", sprite, path, name], "\t")
      end
    )
  end

  defp svg_cache_key([], _, []), do: nil

  defp svg_cache_key(sprite_sources, install_signature, svg_signature) do
    {:svg, install_signature, svg_signature, Sprites.signature(sprite_sources)}
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

  defp watch_dir(path) do
    if File.dir?(path), do: path, else: watch_dir(Path.dirname(path))
  end
end
