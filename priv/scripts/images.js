import path from "node:path";
import { watch } from "node:fs";
import { mkdir, rm, stat } from "node:fs/promises";

const optionValue = (name, fallback) => {
  const prefix = `--${name}=`;
  const value = process.argv.find((arg) => arg.startsWith(prefix));

  return value ? value.slice(prefix.length) : fallback;
};

const resolvePath = (value) => path.resolve(process.cwd(), value);
const DIST_DIR = resolvePath(optionValue("dest", "../priv/static/assets/img"));
const SRC_DIR = resolvePath(optionValue("src", "img"));

const IMAGE_OPTIONS = {
  autoOrient: true,
};

const AVIF_OPTIONS = {
  quality: 82,
};

const SHARP_AVIF_OPTIONS = {
  chromaSubsampling: "4:4:4",
  effort: 9,
  quality: 82,
};

const WEBP_OPTIONS = {
  quality: 88,
};

const CLEAN_JPEG_OPTIONS = {
  mozjpeg: true,
  progressive: true,
  quality: 100,
};

const CLEAN_PNG_OPTIONS = {
  compressionLevel: 9,
  effort: 10,
  palette: true,
};

const IMAGE_EXTS = new Set([".jpg", ".jpeg", ".png"]);
const GENERATED_IMAGE_EXTS = new Set([".avif", ".webp"]);

const isClean = process.argv.includes("--clean");
const isForce = process.argv.includes("--force");
const isWatch = process.argv.includes("--watch");
const WATCH_DEBOUNCE_MS = 80;
const glob = new Bun.Glob("**/*", { dot: false });
const pendingWatchJobs = new Map();
let didCleanSources = false;
let isStopping = false;
let processingQueue = Promise.resolve();
let sharpModulePromise;

const isImageFile = (filePath) =>
  IMAGE_EXTS.has(path.extname(filePath).toLowerCase());

const isGeneratedImageFile = (filePath) =>
  GENERATED_IMAGE_EXTS.has(path.extname(filePath).toLowerCase());

const sourceImage = (filePath) => new Bun.Image(filePath, IMAGE_OPTIONS);

const loadSharp = async () => {
  sharpModulePromise ??= import("sharp");
  const { default: sharp } = await sharpModulePromise;

  return sharp;
};

const scanSourcePaths = async function* () {
  for await (const file of glob.scan(SRC_DIR)) {
    if (isGeneratedImageFile(file)) continue;

    yield [file, path.join(SRC_DIR, file)];
  }
};

const getTargetPaths = (srcPath) => {
  const relativePath = path.relative(SRC_DIR, srcPath);
  const parsed = path.parse(relativePath);

  const dir = path.join(DIST_DIR, parsed.dir);
  const original = path.join(DIST_DIR, relativePath);
  const baseWithoutExt = path.join(dir, parsed.name);

  return {
    relativePath,
    original,
    avif: `${baseWithoutExt}.avif`,
    webp: `${baseWithoutExt}.webp`,
    dir,
  };
};

const removablePaths = (srcPath) => {
  const targets = getTargetPaths(srcPath);

  return {
    targets,
    paths: isImageFile(srcPath)
      ? [targets.original, targets.avif, targets.webp]
      : [targets.original],
  };
};

const staleOriginalPaths = (srcPath) => {
  if (!isImageFile(srcPath)) return [];

  const targets = getTargetPaths(srcPath);
  const parsed = path.parse(targets.original);

  return [...IMAGE_EXTS]
    .map((ext) => path.join(parsed.dir, `${parsed.name}${ext}`))
    .filter((filePath) => filePath !== targets.original);
};

const enqueue = (task) => {
  processingQueue = processingQueue.then(task).catch((error) => {
    console.error(error);
  });

  return processingQueue;
};

const replaceWithCleanImage = async (filePath) => {
  const ext = path.extname(filePath).toLowerCase();
  const sharp = await loadSharp();
  const pipeline = sharp(filePath).rotate();

  const buffer =
    ext === ".png"
      ? await pipeline.png(CLEAN_PNG_OPTIONS).toBuffer()
      : await pipeline.jpeg(CLEAN_JPEG_OPTIONS).toBuffer();

  await Bun.write(filePath, buffer);
};

const cleanSources = async () => {
  console.info("Cleaning image sources...");

  for await (const [file, filePath] of scanSourcePaths()) {
    if (!isImageFile(filePath)) continue;

    await replaceWithCleanImage(filePath);
    console.info(`Cleaned source: ${file}`);
  }
};

const pathType = async (filePath) => {
  try {
    const fileStat = await stat(filePath);
    return fileStat.isDirectory() ? "directory" : "file";
  } catch {
    return "missing";
  }
};

const processAllSources = async () => {
  for await (const [, filePath] of scanSourcePaths()) {
    await processFile(filePath);
  }
};

const removeGeneratedFile = async (srcPath) => {
  const { targets, paths } = removablePaths(srcPath);

  await Promise.all(paths.map((filePath) => rm(filePath, { force: true })));
  console.info(`Removed: ${targets.relativePath}`);
};

const processWatchPath = async (relativePath) => {
  if (!relativePath) {
    await processAllSources();
    return;
  }

  if (isGeneratedImageFile(relativePath)) return;

  const srcPath = path.join(SRC_DIR, relativePath);
  const type = await pathType(srcPath);

  if (type === "directory") {
    await processAllSources();
    return;
  }

  if (type === "missing") {
    await removeGeneratedFile(srcPath);
    return;
  }

  await processFile(srcPath);
};

const scheduleWatchJob = (relativePath) => {
  const jobKey = relativePath || "*";
  const existingTimeout = pendingWatchJobs.get(jobKey);

  if (existingTimeout) clearTimeout(existingTimeout);

  const timeout = setTimeout(() => {
    pendingWatchJobs.delete(jobKey);

    void enqueue(() => processWatchPath(relativePath));
  }, WATCH_DEBOUNCE_MS);

  pendingWatchJobs.set(jobKey, timeout);
};

const startWatchMode = () => {
  console.info("Watching image sources...");

  const watcher = watch(
    SRC_DIR,
    { recursive: true },
    (eventType, relativePath) => {
      void eventType;
      scheduleWatchJob(relativePath);
    },
  );

  const stopWatching = async (exitCode = 0) => {
    if (isStopping) return;

    isStopping = true;
    watcher.close();

    for (const timeout of pendingWatchJobs.values()) {
      clearTimeout(timeout);
    }

    pendingWatchJobs.clear();
    await processingQueue;
    process.exit(exitCode);
  };

  watcher.on("error", (error) => {
    console.error(error);
    void stopWatching(1);
  });

  process.once("SIGINT", () => void stopWatching());
  process.once("SIGTERM", () => void stopWatching());
};

const shouldUpdate = async (srcPath, distPath) => {
  if (isForce) return true;

  const dist = Bun.file(distPath);
  const src = Bun.file(srcPath);

  if (!(await dist.exists())) return true;
  return src.lastModified > dist.lastModified;
};

const writeAvif = async (srcPath, distPath) => {
  try {
    await sourceImage(srcPath).avif(AVIF_OPTIONS).write(distPath);
  } catch (error) {
    if (error?.code !== "ERR_IMAGE_FORMAT_UNSUPPORTED") throw error;

    const sharp = await loadSharp();
    await sharp(srcPath).rotate().avif(SHARP_AVIF_OPTIONS).toFile(distPath);
  }
};

const processFile = async (filePath) => {
  const targets = getTargetPaths(filePath);

  await mkdir(targets.dir, { recursive: true });

  if (isGeneratedImageFile(filePath)) return;

  if (!isImageFile(filePath)) {
    if (await shouldUpdate(filePath, targets.original)) {
      await Bun.write(targets.original, Bun.file(filePath));
      console.info(`Copied: ${targets.relativePath}`);
    }
    return;
  }

  const [needsOrig, needsAvif, needsWebp] = await Promise.all([
    shouldUpdate(filePath, targets.original),
    shouldUpdate(filePath, targets.avif),
    shouldUpdate(filePath, targets.webp),
  ]);

  await Promise.all(
    staleOriginalPaths(filePath).map((filePath) =>
      rm(filePath, { force: true }),
    ),
  );

  if (!needsOrig && !needsAvif && !needsWebp) return;

  if (isClean && !didCleanSources) {
    didCleanSources = true;
    await cleanSources();
    return processFile(filePath);
  }

  const tasks = [];

  if (needsOrig) tasks.push(Bun.write(targets.original, Bun.file(filePath)));
  if (needsAvif) tasks.push(writeAvif(filePath, targets.avif));
  if (needsWebp)
    tasks.push(sourceImage(filePath).webp(WEBP_OPTIONS).write(targets.webp));

  await Promise.all(tasks);
  console.info(`Processed: ${targets.relativePath}`);
};

await processAllSources();
if (isWatch) startWatchMode();
