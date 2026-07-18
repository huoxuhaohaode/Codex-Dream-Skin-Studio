import { createHash, randomBytes } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const MAX_PACKAGE_BYTES = 24 * 1024 * 1024;
const MAX_THEME_BYTES = 256 * 1024;
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;
const MAX_PREVIEW_BYTES = 4 * 1024 * 1024;
const MEDIA = new Map([
  [".png", "image/png"],
  [".jpg", "image/jpeg"],
  [".jpeg", "image/jpeg"],
  [".webp", "image/webp"],
]);
const RESERVED = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i;

function fail(code, message) {
  const error = new Error(`${code}: ${message}`);
  error.code = code;
  throw error;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

function portableBasename(name, label) {
  if (
    typeof name !== "string"
    || !name
    || path.basename(name) !== name
    || /[\\/:\0-\x1f\x7f]/.test(name)
    || RESERVED.test(name)
  ) {
    fail("E_NAME", `${label} is not a portable basename`);
  }
  return name;
}

function mediaFor(name) {
  const media = MEDIA.get(path.extname(name).toLowerCase());
  if (!media) fail("E_MEDIA", "unsupported image extension");
  return media;
}

function imageMagicMatches(bytes, media) {
  const head = bytes.subarray(0, 12);
  if (media === "image/png") {
    return head.length >= 8
      && head.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
  }
  if (media === "image/jpeg") return head[0] === 0xff && head[1] === 0xd8;
  return head.subarray(0, 4).equals(Buffer.from("RIFF"))
    && head.subarray(8, 12).equals(Buffer.from("WEBP"));
}

function decodeBase64(value, label, limit) {
  if (
    typeof value !== "string"
    || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)
  ) {
    fail("E_BASE64", `${label} is not strict base64`);
  }
  const bytes = Buffer.from(value, "base64");
  if (!bytes.length || bytes.length > limit) fail("E_SIZE", `${label} exceeds its size limit`);
  return bytes;
}

function validatePayload(entry, label, limit) {
  if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
    fail("E_PAYLOAD", `${label} payload is invalid`);
  }
  const name = portableBasename(entry.name, label);
  const mediaType = label === "theme" ? "application/json" : mediaFor(name);
  if (entry.mediaType !== mediaType) fail("E_MEDIA", `${label} media type does not match`);
  const bytes = decodeBase64(entry.data, label, limit);
  if (entry.bytes !== bytes.length) fail("E_LENGTH", `${label} byte length mismatch`);
  if (
    typeof entry.sha256 !== "string"
    || !/^[a-f0-9]{64}$/.test(entry.sha256)
    || entry.sha256 !== sha256(bytes)
  ) {
    fail("E_HASH", `${label} SHA-256 mismatch`);
  }
  if (label === "theme" && name !== "theme.json") {
    fail("E_NAME", "theme payload must be named theme.json");
  }
  if (label !== "theme" && !imageMagicMatches(bytes, mediaType)) {
    fail("E_MAGIC", `${label} bytes do not match the declared image type`);
  }
  return { name, mediaType, bytes, sha256: entry.sha256 };
}

function parseTheme(bytes) {
  let theme;
  try {
    theme = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    fail("E_THEME_JSON", "theme payload is not strict UTF-8 JSON");
  }
  if (!theme || typeof theme !== "object" || Array.isArray(theme) || theme.schemaVersion !== 1) {
    fail("E_THEME_VERSION", "theme schemaVersion must be 1");
  }
  if (typeof theme.id !== "string" || !/^[A-Za-z0-9_-]{1,80}$/.test(theme.id)) {
    fail("E_THEME_ID", "theme id is invalid");
  }
  if (typeof theme.name !== "string" || !theme.name.trim() || theme.name.length > 80) {
    fail("E_THEME_NAME", "theme name is invalid");
  }
  return theme;
}

function inspectEnvelope(value) {
  if (
    !value
    || typeof value !== "object"
    || Array.isArray(value)
    || value.format !== "codex-dream-skin"
    || value.packageVersion !== 1
  ) {
    fail("E_VERSION", "unsupported Dream Skin package version");
  }
  const allowed = new Set(["format", "packageVersion", "theme", "primaryImage", "preview"]);
  if (Object.keys(value).some((key) => !allowed.has(key))) {
    fail("E_ENVELOPE", "package contains unsupported top-level fields");
  }
  const themePayload = validatePayload(value.theme, "theme", MAX_THEME_BYTES);
  const theme = parseTheme(themePayload.bytes);
  const primary = validatePayload(value.primaryImage, "primary image", MAX_IMAGE_BYTES);
  if (theme.image !== primary.name) {
    fail("E_THEME_IMAGE", "theme image does not match the primary image payload");
  }
  const preview = value.preview === undefined
    ? null
    : validatePayload(value.preview, "preview", MAX_PREVIEW_BYTES);
  return { theme, themePayload, primary, preview };
}

async function readPackage(file) {
  const stats = await fs.lstat(file);
  if (!stats.isFile() || stats.isSymbolicLink() || !stats.size || stats.size > MAX_PACKAGE_BYTES) {
    fail("E_SIZE", "package must be a regular file within the size limit");
  }
  const bytes = await fs.readFile(file);
  let value;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(bytes));
  } catch {
    fail("E_PACKAGE_JSON", "package is not strict UTF-8 JSON");
  }
  return { bytes, value, validated: inspectEnvelope(value) };
}

async function regularFile(file, label, limit) {
  const stats = await fs.lstat(file);
  if (!stats.isFile() || stats.isSymbolicLink() || !stats.size || stats.size > limit) {
    fail("E_FILE", `${label} must be a regular file within the size limit`);
  }
  return fs.readFile(file);
}

export async function inspectPackage(file) {
  const { bytes, validated } = await readPackage(file);
  return {
    format: "codex-dream-skin",
    packageVersion: 1,
    id: validated.theme.id,
    name: validated.theme.name,
    image: validated.primary.name,
    imageBytes: validated.primary.bytes.length,
    packageBytes: bytes.length,
    packageSHA256: sha256(bytes),
    preview: validated.preview?.name ?? null,
    safeDataOnly: true,
  };
}

export async function exportPackage(themeDirectory, outputFile, options = {}) {
  const source = path.resolve(themeDirectory);
  const target = path.resolve(outputFile);
  const sourceStats = await fs.lstat(source);
  if (!sourceStats.isDirectory() || sourceStats.isSymbolicLink()) {
    fail("E_SOURCE", "theme source must be a real directory");
  }
  try {
    await fs.lstat(target);
    fail("E_EXISTS", "package output already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const themePath = path.join(source, "theme.json");
  const themeBytes = await regularFile(themePath, "theme.json", MAX_THEME_BYTES);
  const theme = parseTheme(themeBytes);
  const imageName = portableBasename(theme.image, "theme image");
  const imagePath = path.join(source, imageName);
  const imageBytes = await regularFile(imagePath, "theme image", MAX_IMAGE_BYTES);
  const mediaType = mediaFor(imageName);
  if (!imageMagicMatches(imageBytes, mediaType)) fail("E_MAGIC", "theme image is invalid");

  const wrap = (name, type, bytes) => ({
    name,
    mediaType: type,
    bytes: bytes.length,
    sha256: sha256(bytes),
    data: bytes.toString("base64"),
  });
  const value = {
    format: "codex-dream-skin",
    packageVersion: 1,
    theme: wrap("theme.json", "application/json", themeBytes),
    primaryImage: wrap(imageName, mediaType, imageBytes),
  };
  if (options.preview) {
    const previewName = portableBasename(options.preview, "preview");
    const previewBytes = await regularFile(
      path.join(source, previewName),
      "preview",
      MAX_PREVIEW_BYTES,
    );
    const previewType = mediaFor(previewName);
    if (!imageMagicMatches(previewBytes, previewType)) fail("E_MAGIC", "preview image is invalid");
    value.preview = wrap(previewName, previewType, previewBytes);
  }
  inspectEnvelope(value);
  const encoded = Buffer.from(`${JSON.stringify(value)}\n`);
  if (encoded.length > MAX_PACKAGE_BYTES) fail("E_SIZE", "encoded package exceeds its size limit");
  await fs.writeFile(target, encoded, { flag: "wx", mode: 0o600 });
  return inspectPackage(target);
}

export async function importPackage(packageFile, destination, options = {}) {
  const { validated } = await readPackage(packageFile);
  const target = path.resolve(destination);
  try {
    await fs.lstat(target);
    fail("E_EXISTS", "destination already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }

  const importedId = options.id ?? validated.theme.id;
  if (!/^custom-imported-[A-Za-z0-9_-]{1,60}$/.test(importedId)) {
    fail("E_IMPORT_ID", "imported theme id is invalid");
  }
  const theme = {
    ...validated.theme,
    id: importedId,
    provenance: {
      importedAt: new Date().toISOString(),
      originalId: validated.theme.id,
      packageSHA256: (await inspectPackage(packageFile)).packageSHA256,
      sourceURL: options.sourceURL || null,
      sourceLabel: options.sourceLabel || null,
      license: options.license || null,
    },
  };
  const stage = `${target}.dreamskin-stage-${process.pid}-${randomBytes(4).toString("hex")}`;
  await fs.mkdir(stage, { mode: 0o700 });
  try {
    await fs.writeFile(path.join(stage, validated.primary.name), validated.primary.bytes, {
      flag: "wx",
      mode: 0o600,
    });
    await fs.writeFile(path.join(stage, "theme.json"), `${JSON.stringify(theme, null, 2)}\n`, {
      flag: "wx",
      mode: 0o600,
    });
    await fs.rename(stage, target);
    return {
      id: importedId,
      originalId: validated.theme.id,
      name: validated.theme.name,
      image: validated.primary.name,
      safeDataOnly: true,
    };
  } catch (error) {
    await fs.rm(stage, { recursive: true, force: true });
    throw error;
  }
}

export async function extractPackage(packageFile, destination) {
  const { validated } = await readPackage(packageFile);
  const target = path.resolve(destination);
  try {
    await fs.lstat(target);
    fail("E_EXISTS", "destination already exists");
  } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const stage = `${target}.dreamskin-extract-${process.pid}-${randomBytes(4).toString("hex")}`;
  await fs.mkdir(stage, { mode: 0o700 });
  try {
    await fs.writeFile(path.join(stage, validated.primary.name), validated.primary.bytes, {
      flag: "wx",
      mode: 0o600,
    });
    await fs.writeFile(
      path.join(stage, "theme.json"),
      `${JSON.stringify(validated.theme, null, 2)}\n`,
      { flag: "wx", mode: 0o600 },
    );
    await fs.rename(stage, target);
    return {
      id: validated.theme.id,
      name: validated.theme.name,
      image: validated.primary.name,
      safeDataOnly: true,
    };
  } catch (error) {
    await fs.rm(stage, { recursive: true, force: true });
    throw error;
  }
}

function optionValue(args, name) {
  const index = args.indexOf(name);
  return index >= 0 ? args[index + 1] : undefined;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [action, ...args] = process.argv.slice(2);
  try {
    let result;
    if (action === "inspect") {
      result = await inspectPackage(args[0]);
    } else if (action === "export") {
      result = await exportPackage(args[0], args[1]);
    } else if (action === "extract") {
      result = await extractPackage(args[0], args[1]);
    } else if (action === "import") {
      result = await importPackage(args[0], args[1], {
        id: optionValue(args, "--id"),
        sourceURL: optionValue(args, "--source-url"),
        sourceLabel: optionValue(args, "--source-label"),
        license: optionValue(args, "--license"),
      });
    } else {
      fail("E_USAGE", "use inspect, export, extract, or import");
    }
    console.log(JSON.stringify(result));
  } catch (error) {
    console.error(error.message);
    process.exitCode = 2;
  }
}
