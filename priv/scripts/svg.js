import path from "node:path";
import { watch } from "node:fs";
import { mkdir } from "node:fs/promises";
import os from "node:os";

const optionValue = (name, fallback) => {
  const prefix = `--${name}=`;
  const value = process.argv.find((arg) => arg.startsWith(prefix));

  return value ? value.slice(prefix.length) : fallback;
};

const resolvePath = (value) => path.resolve(process.cwd(), value);
const HEROICONS_DIR = resolvePath(optionValue("heroicons-dir", "../deps/heroicons/optimized"));
const HEROICONS_TEMP_DIR = path.join(os.tmpdir(), "phoenix-asset-pipeline-heroicons-sprite");
const HERO_SOURCE_DIR = resolvePath(optionValue("hero-source", "../lib"));
const SPRITES_DIR = resolvePath(optionValue("app-sprites", "svg/sprites/app"));
const ICONS_DIR = resolvePath(optionValue("icon-sprites", "svg/sprites/icons"));
const SVG_DEST_DIR = optionValue("dest", "../priv/static/assets/svg");
const APP_SPRITE = optionValue("app-sprite", "app.svg");
const ICONS_SPRITE = optionValue("icons-sprite", "icons.svg");

const APP_SPRITE_ARGS = [
  "--minify",
  "--stack",
  `--stack-dest=${SVG_DEST_DIR}`,
  `--stack-sprite=${APP_SPRITE}`,
];

const ICONS_SPRITE_ARGS = [
  "--minify",
  "--symbol",
  `--symbol-dest=${SVG_DEST_DIR}`,
  `--symbol-sprite=${ICONS_SPRITE}`,
];

const WATCH_DEBOUNCE_MS = 80;
const isWatch = process.argv.includes("--watch");
const glob = new Bun.Glob("*.svg", { dot: false });
const heroSourceGlobs = [new Bun.Glob("**/*.ex"), new Bun.Glob("**/*.heex")];
const heroIconNamePattern =
  /<\.(?:icon|menu_icon)\b[^>]*\bname\s*=\s*"([a-z0-9][a-z0-9-]*)"[^>]*>|\bicon:\s*"([a-z0-9][a-z0-9-]*)"|\bicon_name\([^)]*\),\s*do:\s*"([a-z0-9][a-z0-9-]*)"/g;
let buildQueue = Promise.resolve();
let pendingBuild;
let isStopping = false;

const spriteSourceFiles = async (dir) => {
  const files = [];

  for await (const file of glob.scan(dir)) {
    files.push(path.join(dir, file));
  }

  return files.sort();
};

const appSourceFiles = () => spriteSourceFiles(SPRITES_DIR);
const iconSourceFiles = () => spriteSourceFiles(ICONS_DIR);

const heroIconSource = (name) => {
  if (name.endsWith("-micro")) {
    return path.join(HEROICONS_DIR, "16/solid", `${name.slice(0, -6)}.svg`);
  }

  if (name.endsWith("-mini")) {
    return path.join(HEROICONS_DIR, "20/solid", `${name.slice(0, -5)}.svg`);
  }

  if (name.endsWith("-solid")) {
    return path.join(HEROICONS_DIR, "24/solid", `${name.slice(0, -6)}.svg`);
  }

  return path.join(HEROICONS_DIR, "24/outline", `${name}.svg`);
};

const collectHeroIconNames = (content, names) => {
  for (const match of content.matchAll(heroIconNamePattern)) {
    names.add(match[1] ?? match[2] ?? match[3]);
  }
};

const heroIconNames = async () => {
  const names = new Set();

  for (const glob of heroSourceGlobs) {
    for await (const file of glob.scan(HERO_SOURCE_DIR)) {
      const content = await Bun.file(path.join(HERO_SOURCE_DIR, file)).text();
      collectHeroIconNames(content, names);
    }
  }

  return Array.from(names).sort();
};

const heroSourceFiles = async () => {
  await mkdir(HEROICONS_TEMP_DIR, { recursive: true });
  const names = await heroIconNames();

  const files = await Promise.all(
    names.map(async (name) => {
      const source = heroIconSource(name);
      const target = path.join(HEROICONS_TEMP_DIR, `hero-${name}.svg`);
      const sourceFile = Bun.file(source);

      if (!(await sourceFile.exists())) {
        throw new Error(`Unknown Heroicon "${name}" (${source})`);
      }

      await Bun.write(target, sourceFile);

      return target;
    }),
  );

  return files;
};

const combinedIconSourceFiles = async () => {
  const files = await iconSourceFiles();

  for (const file of await heroSourceFiles()) {
    files.push(file);
  }

  return files;
};

const runSpriteCommand = async (
  args,
  files,
  label,
  { allowFailure = false } = {},
) => {
  if (files.length === 0) {
    console.warn(`No SVG ${label} sources found`);
    return;
  }

  const proc = Bun.spawn({
    cmd: [process.execPath, "run", "svg-sprite", ...args, ...files],
    stderr: "inherit",
    stdout: "inherit",
  });

  const exitCode = await proc.exited;

  if (exitCode === 0) {
    console.info(`SVG ${label} sprite built`);
    return;
  }

  const error = new Error(`svg-sprite ${label} exited with code ${exitCode}`);

  if (allowFailure) {
    console.error(error);
    return;
  }

  throw error;
};

const runSprite = async ({ allowFailure = false } = {}) => {
  await runSpriteCommand(APP_SPRITE_ARGS, await appSourceFiles(), "app", {
    allowFailure,
  });
  await runSpriteCommand(
    ICONS_SPRITE_ARGS,
    await combinedIconSourceFiles(),
    "icons",
    {
      allowFailure,
    },
  );
};

const enqueueBuild = () => {
  buildQueue = buildQueue.then(() => runSprite({ allowFailure: true }));
  buildQueue = buildQueue.catch((error) => console.error(error));

  return buildQueue;
};

const scheduleBuild = () => {
  if (pendingBuild) clearTimeout(pendingBuild);

  pendingBuild = setTimeout(() => {
    pendingBuild = undefined;
    void enqueueBuild();
  }, WATCH_DEBOUNCE_MS);
};

const startWatchMode = async () => {
  await runSprite({ allowFailure: true });
  console.info("Watching SVG sprite sources...");

  const watchers = [
    watch(SPRITES_DIR, { recursive: false }, scheduleBuild),
    watch(ICONS_DIR, { recursive: false }, scheduleBuild),
    watch(HERO_SOURCE_DIR, { recursive: true }, scheduleBuild),
  ];

  const stopWatching = async (exitCode = 0) => {
    if (isStopping) return;

    isStopping = true;
    watchers.forEach((watcher) => watcher.close());

    if (pendingBuild) clearTimeout(pendingBuild);

    await buildQueue;
    process.exit(exitCode);
  };

  watchers.forEach((watcher) => {
    watcher.on("error", (error) => {
      console.error(error);
      void stopWatching(1);
    });
  });

  process.once("SIGINT", () => void stopWatching());
  process.once("SIGTERM", () => void stopWatching());
};

if (isWatch) {
  await startWatchMode();
} else {
  await runSprite();
}
