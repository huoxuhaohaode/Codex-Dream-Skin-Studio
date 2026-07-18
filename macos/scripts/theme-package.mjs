import fs from "node:fs/promises";
import { constants as fsConstants } from "node:fs";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { pathToFileURL } from "node:url";

const FORMAT = "codex-dream-skin-theme";
const PACKAGE_SCHEMA = 1;
const MAX_CONFIG_BYTES = 1024 * 1024;
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_PACKAGE_BYTES = 24 * 1024 * 1024;
const OPEN_FLAGS = fsConstants.O_RDONLY | (fsConstants.O_NOFOLLOW ?? 0);
const IMAGE_EXTENSIONS = new Set([".png", ".jpg", ".jpeg", ".webp"]);
const CONTROL = /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/u;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function parseArgs(argv) {
  const command = argv[0];
  const values = {};
  for (let index = 1; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) {
      throw new Error(`Invalid package argument: ${key}`);
    }
    values[key.slice(2)] = argv[++index];
  }
  return { command, values };
}

function required(values, key) {
  const value = values[key];
  if (!value) throw new Error(`Missing --${key}`);
  return path.resolve(value);
}

function decodeJson(bytes, label) {
  const text = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  if (text.includes("\0")) throw new Error(`${label} contains NUL characters`);
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`${label} is not valid JSON`);
  }
}

async function readStableFile(filePath, label, maxBytes) {
  let handle;
  try {
    handle = await fs.open(filePath, OPEN_FLAGS);
  } catch (error) {
    if (error.code === "ELOOP") throw new Error(`${label} must not be a symbolic link`);
    throw error;
  }
  try {
    const before = await handle.stat();
    if (!before.isFile()) throw new Error(`${label} must be a regular file`);
    if (before.size < 1 || before.size > maxBytes) {
      throw new Error(`${label} must be between 1 and ${maxBytes} bytes`);
    }
    const bytes = await handle.readFile();
    const after = await handle.stat();
    if (before.dev !== after.dev || before.ino !== after.ino || before.size !== after.size ||
        before.mtimeMs !== after.mtimeMs || before.ctimeMs !== after.ctimeMs) {
      throw new Error(`${label} changed while it was being read`);
    }
    return bytes;
  } finally {
    await handle.close();
  }
}

function cleanText(value, fallback, maxLength) {
  if (typeof value !== "string" || CONTROL.test(value)) return fallback;
  const trimmed = value.trim();
  return Array.from(trimmed).slice(0, maxLength).join("") || fallback;
}

function cleanChoice(value, choices, fallback) {
  return choices.includes(value) ? value : fallback;
}

function slug(value) {
  const cleaned = String(value ?? "theme")
    .normalize("NFKD")
    .replace(/[^A-Za-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .toLowerCase();
  return cleaned.slice(0, 24) || "theme";
}

function sanitizeTheme(source, id, imageName) {
  if (!source || source.schemaVersion !== 1 || typeof source !== "object") {
    throw new Error("Theme config uses an unsupported schema");
  }
  const result = {
    schemaVersion: 1,
    id,
    name: cleanText(source.name, "导入的主题", 80),
    brandSubtitle: cleanText(source.brandSubtitle, "CODEX DREAM SKIN", 80),
    tagline: cleanText(source.tagline, "来自安全主题包", 160),
    projectPrefix: cleanText(source.projectPrefix, "选择项目 · ", 80),
    projectLabel: cleanText(source.projectLabel, "◉  选择项目", 80),
    statusText: cleanText(source.statusText, "DREAM SKIN ONLINE", 80),
    quote: cleanText(source.quote, "MAKE SOMETHING WONDERFUL", 80),
    image: imageName,
    appearance: cleanChoice(source.appearance, ["auto", "light", "dark"], "auto"),
  };

  const art = source.art && typeof source.art === "object" ? source.art : {};
  result.art = {
    safeArea: cleanChoice(art.safeArea, ["auto", "left", "right", "center", "none"], "auto"),
    taskMode: cleanChoice(art.taskMode, ["auto", "ambient", "banner", "off"], "auto"),
  };
  for (const key of ["focusX", "focusY"]) {
    if (Number.isFinite(art[key]) && art[key] >= 0 && art[key] <= 1) result.art[key] = art[key];
  }

  if (source.colors && typeof source.colors === "object") {
    const colors = {};
    for (const key of [
      "background", "panel", "panelAlt", "accent", "accentAlt", "secondary",
      "highlight", "text", "muted", "line",
    ]) {
      const value = source.colors[key];
      if (typeof value === "string" && !CONTROL.test(value) && value.length <= 64) colors[key] = value;
    }
    if (Object.keys(colors).length) result.colors = colors;
  }
  return result;
}

function normalizeProvenance(value = {}) {
  const result = {
    importedAt: new Date().toISOString(),
    verified: value.verified === true,
  };
  const fields = ["sourceIdentifier", "sourceName", "repository", "sourceURL", "commit", "license", "artworkLicense"];
  for (const field of fields) {
    if (typeof value[field] === "string" && !CONTROL.test(value[field])) {
      result[field] = Array.from(value[field].trim()).slice(0, 500).join("");
    }
  }
  return result;
}

function decodeBase64(value) {
  if (typeof value !== "string" || value.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(value)) {
    throw new Error("Theme package image is not canonical base64 data");
  }
  const bytes = Buffer.from(value, "base64");
  if (bytes.toString("base64") !== value) throw new Error("Theme package image base64 is malformed");
  return bytes;
}

function runNode(script, arguments_, label) {
  const result = spawnSync(process.execPath, [script, ...arguments_], {
    encoding: "utf8",
    maxBuffer: 4 * 1024 * 1024,
  });
  if (result.status !== 0) {
    const detail = (result.stderr || result.stdout || "").trim().split(/\r?\n/).at(-1);
    throw new Error(`${label} failed${detail ? `: ${detail}` : ""}`);
  }
  return result.stdout.trim();
}

async function prepareFromDirectory(source, stage, stageThemePath) {
  const stat = await fs.lstat(source);
  if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error("Theme source must be a real directory");
  runNode(stageThemePath, [source, stage], "Theme snapshot");
  const themeBytes = await readStableFile(path.join(stage, "theme.json"), "Theme config", MAX_CONFIG_BYTES);
  const theme = decodeJson(themeBytes, "Theme config");
  return { theme, provenance: {} };
}

async function prepareFromPackage(source, stage) {
  const bytes = await readStableFile(source, "Theme package", MAX_PACKAGE_BYTES);
  const value = decodeJson(bytes, "Theme package");
  if (value?.format !== FORMAT || value.schemaVersion !== PACKAGE_SCHEMA || typeof value.theme !== "object") {
    throw new Error("Unsupported legacy theme package format");
  }
  const image = decodeBase64(value.image?.dataBase64);
  if (image.length < 1 || image.length > MAX_IMAGE_BYTES) throw new Error("Theme package image size is invalid");
  if (sha256(image) !== value.image?.sha256) throw new Error("Theme package image hash does not match");
  const extension = path.extname(value.image?.filename ?? "").toLowerCase();
  if (!IMAGE_EXTENSIONS.has(extension)) throw new Error("Theme package image type is unsupported");
  const imageName = `background${extension === ".jpeg" ? ".jpg" : extension}`;
  await fs.writeFile(path.join(stage, imageName), image, { flag: "wx", mode: 0o600 });
  value.theme.image = imageName;
  return { theme: value.theme, provenance: value.provenance ?? {} };
}

async function validateTheme(stage, injectorPath) {
  runNode(injectorPath, ["--check-payload", "--theme-dir", stage], "Theme validation");
}

export async function importThemeSource(options) {
  const source = path.resolve(options.source);
  const themesRoot = path.resolve(options.themesRoot);
  const stateRoot = path.resolve(options.stateRoot);
  const injectorPath = path.resolve(options.injectorPath);
  const stageThemePath = path.resolve(options.stageThemePath);
  await fs.mkdir(themesRoot, { recursive: true, mode: 0o700 });
  await fs.mkdir(stateRoot, { recursive: true, mode: 0o700 });
  const themesReal = await fs.realpath(themesRoot);
  const stage = await fs.mkdtemp(path.join(stateRoot, ".theme-import."));
  await fs.chmod(stage, 0o700);
  try {
    const sourceStat = await fs.lstat(source);
    const prepared = sourceStat.isDirectory()
      ? await prepareFromDirectory(source, stage, stageThemePath)
      : await prepareFromPackage(source, stage);
    const sourceImage = prepared.theme?.image;
    if (typeof sourceImage !== "string" || path.basename(sourceImage) !== sourceImage) {
      throw new Error("Theme image must be a filename inside the theme folder");
    }
    const extension = path.extname(sourceImage).toLowerCase();
    if (!IMAGE_EXTENSIONS.has(extension)) throw new Error("Theme image type is unsupported");
    const sourceImagePath = path.join(stage, sourceImage);
    const image = await readStableFile(sourceImagePath, "Theme image", MAX_IMAGE_BYTES);
    const packageHash = sha256(Buffer.concat([
      Buffer.from(JSON.stringify(prepared.theme)),
      image,
    ]));
    const localID = `custom-import-${slug(prepared.theme.id || prepared.theme.name)}-${packageHash.slice(0, 10)}`;
    const imageName = `background${extension === ".jpeg" ? ".jpg" : extension}`;
    if (sourceImage !== imageName) await fs.rename(sourceImagePath, path.join(stage, imageName));
    const sanitized = sanitizeTheme(prepared.theme, localID, imageName);
    await fs.writeFile(path.join(stage, "theme.json"), `${JSON.stringify(sanitized, null, 2)}\n`, { mode: 0o600 });
    const provenance = normalizeProvenance({ ...prepared.provenance, ...options.provenance });
    provenance.packageHash = packageHash;
    provenance.originalThemeID = cleanText(prepared.theme.id, "unknown", 120);
    await fs.writeFile(path.join(stage, "origin.json"), `${JSON.stringify(provenance, null, 2)}\n`, { mode: 0o600 });
    await validateTheme(stage, injectorPath);

    let destination = path.join(themesReal, localID);
    try {
      const existingOrigin = decodeJson(
        await readStableFile(path.join(destination, "origin.json"), "Existing theme origin", MAX_CONFIG_BYTES),
        "Existing theme origin",
      );
      if (existingOrigin.packageHash === packageHash) {
        return { id: localID, name: sanitized.name, alreadyInstalled: true, provenance };
      }
      throw new Error("A different imported theme already uses the calculated id");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const relative = path.relative(themesReal, destination);
    if (relative.startsWith("..") || path.isAbsolute(relative)) throw new Error("Theme destination escapes the library");
    await fs.rename(stage, destination);
    return { id: localID, name: sanitized.name, alreadyInstalled: false, provenance };
  } finally {
    await fs.rm(stage, { recursive: true, force: true }).catch(() => {});
  }
}

export async function exportTheme(options) {
  const source = path.resolve(options.source);
  const output = path.resolve(options.output);
  const stage = await fs.mkdtemp(path.join(path.dirname(output), ".theme-export."));
  try {
    const imageName = runNode(options.stageThemePath, [source, stage], "Theme snapshot");
    await validateTheme(stage, options.injectorPath);
    const theme = decodeJson(await readStableFile(path.join(stage, "theme.json"), "Theme config", MAX_CONFIG_BYTES), "Theme config");
    const image = await readStableFile(path.join(stage, imageName), "Theme image", MAX_IMAGE_BYTES);
    let provenance = {};
    try {
      provenance = decodeJson(await readStableFile(path.join(source, "origin.json"), "Theme origin", MAX_CONFIG_BYTES), "Theme origin");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const packageValue = {
      format: FORMAT,
      schemaVersion: PACKAGE_SCHEMA,
      exportedAt: new Date().toISOString(),
      theme,
      image: {
        filename: imageName,
        sha256: sha256(image),
        dataBase64: image.toString("base64"),
      },
      provenance: normalizeProvenance(provenance),
    };
    const bytes = Buffer.from(`${JSON.stringify(packageValue)}\n`);
    if (bytes.length > MAX_PACKAGE_BYTES) throw new Error("Exported theme package is too large");
    try {
      const outputStat = await fs.lstat(output);
      if (outputStat.isSymbolicLink() || !outputStat.isFile()) throw new Error("Export destination must be a regular file");
    } catch (error) {
      if (error.code !== "ENOENT") throw error;
    }
    const temporary = `${output}.${process.pid}.tmp`;
    await fs.writeFile(temporary, bytes, { flag: "wx", mode: 0o600 });
    await fs.rename(temporary, output);
    return { output, bytes: bytes.length, sha256: sha256(bytes), name: theme.name, id: theme.id };
  } finally {
    await fs.rm(stage, { recursive: true, force: true }).catch(() => {});
  }
}

async function main() {
  const { command, values } = parseArgs(process.argv.slice(2));
  if (command === "import") {
    const result = await importThemeSource({
      source: required(values, "source"),
      themesRoot: required(values, "themes-root"),
      stateRoot: required(values, "state-root"),
      injectorPath: required(values, "injector"),
      stageThemePath: required(values, "stage-theme"),
    });
    console.log(JSON.stringify(result));
    return;
  }
  if (command === "export") {
    const result = await exportTheme({
      source: required(values, "source"),
      output: required(values, "output"),
      injectorPath: required(values, "injector"),
      stageThemePath: required(values, "stage-theme"),
    });
    console.log(JSON.stringify(result));
    return;
  }
  throw new Error("Usage: theme-package.mjs import|export [options]");
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[dream-skin-package] ${error.message}`);
    process.exitCode = 1;
  });
}
