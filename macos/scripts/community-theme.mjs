import { createHash } from "node:crypto";
import fs from "node:fs/promises";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { importThemeSource } from "./theme-package.mjs";

const MAX_CATALOG_BYTES = 512 * 1024;
const MAX_THEME_BYTES = 256 * 1024;
const MAX_IMAGE_BYTES = 16 * 1024 * 1024;

function fail(message) {
  throw new Error(message);
}

function parseArgs(argv) {
  const values = {};
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    if (!key.startsWith("--") || index + 1 >= argv.length) fail(`Invalid argument: ${key}`);
    values[key.slice(2)] = argv[++index];
  }
  return values;
}

function required(values, key) {
  const value = values[key];
  if (!value) fail(`Missing --${key}`);
  return value;
}

function sha256(bytes) {
  return createHash("sha256").update(bytes).digest("hex");
}

async function readCatalog(file) {
  const stats = await fs.lstat(file);
  if (!stats.isFile() || stats.isSymbolicLink() || stats.size < 1 || stats.size > MAX_CATALOG_BYTES) {
    fail("Community catalog is missing or unsafe.");
  }
  let value;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(await fs.readFile(file)));
  } catch {
    fail("Community catalog is not strict UTF-8 JSON.");
  }
  if (value?.schemaVersion !== 1 || !Array.isArray(value.themes)) {
    fail("Unsupported community catalog version.");
  }
  return value;
}

function validateEntry(entry) {
  if (
    !entry
    || entry.verified !== true
    || typeof entry.id !== "string"
    || !/^[a-z0-9-]{1,80}$/.test(entry.id)
    || typeof entry.repository !== "string"
    || !/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(entry.repository)
    || typeof entry.commit !== "string"
    || !/^[a-f0-9]{40}$/.test(entry.commit)
  ) fail("Community theme entry is not approved for automatic import.");
  for (const key of ["themeSHA256", "imageSHA256"]) {
    if (typeof entry[key] !== "string" || !/^[a-f0-9]{64}$/.test(entry[key])) {
      fail(`Community theme ${key} is invalid.`);
    }
  }
  const expectedPrefix = `/${entry.repository}/${entry.commit}/`;
  for (const key of ["themeURL", "imageURL"]) {
    const url = new URL(entry[key]);
    if (
      url.protocol !== "https:"
      || url.hostname !== "raw.githubusercontent.com"
      || url.username
      || url.password
      || url.search
      || url.hash
      || !url.pathname.startsWith(expectedPrefix)
    ) fail(`Community ${key} is not pinned to its reviewed GitHub commit.`);
  }
  const source = new URL(entry.sourceURL);
  if (
    source.protocol !== "https:"
    || source.hostname !== "github.com"
    || !source.pathname.startsWith(`/${entry.repository}/tree/${entry.commit}/`)
  ) fail("Community source URL is not pinned to the reviewed repository commit.");
  return entry;
}

async function download(url, expectedHash, label, limit) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 20000);
  let response;
  try {
    response = await fetch(url, { redirect: "error", signal: controller.signal });
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) fail(`${label} download failed with HTTP ${response.status}.`);
  const lengthHeader = response.headers.get("content-length");
  if (lengthHeader !== null && Number(lengthHeader) > limit) fail(`${label} is too large.`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (!bytes.length || bytes.length > limit) fail(`${label} is outside its size limit.`);
  if (sha256(bytes) !== expectedHash) fail(`${label} SHA-256 does not match the reviewed catalog.`);
  return bytes;
}

async function install(values) {
  const catalog = await readCatalog(path.resolve(required(values, "catalog")));
  const requestedID = required(values, "id");
  const entry = validateEntry(catalog.themes.find((theme) => theme.id === requestedID));
  const stateRoot = path.resolve(required(values, "state-root"));
  const temporary = await fs.mkdtemp(path.join(stateRoot, ".community-download."));
  try {
    const [themeBytes, imageBytes] = await Promise.all([
      download(entry.themeURL, entry.themeSHA256, "Theme metadata", MAX_THEME_BYTES),
      download(entry.imageURL, entry.imageSHA256, "Theme image", MAX_IMAGE_BYTES),
    ]);
    let theme;
    try {
      theme = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(themeBytes));
    } catch {
      fail("Downloaded theme metadata is invalid.");
    }
    const imageName = path.basename(new URL(entry.imageURL).pathname);
    if (theme?.schemaVersion !== 1 || theme.image !== imageName) {
      fail("Downloaded theme metadata does not match the reviewed image.");
    }
    await fs.writeFile(path.join(temporary, "theme.json"), themeBytes, { flag: "wx", mode: 0o600 });
    await fs.writeFile(path.join(temporary, imageName), imageBytes, { flag: "wx", mode: 0o600 });
    return await importThemeSource({
      source: temporary,
      themesRoot: path.resolve(required(values, "themes-root")),
      stateRoot,
      injectorPath: path.resolve(required(values, "injector")),
      stageThemePath: path.resolve(required(values, "stage-theme")),
      provenance: {
        sourceIdentifier: entry.id,
        sourceName: entry.name,
        repository: entry.repository,
        sourceURL: entry.sourceURL,
        commit: entry.commit,
        license: entry.license,
        artworkLicense: entry.artworkLicense,
        verified: true,
      },
    });
  } finally {
    await fs.rm(temporary, { recursive: true, force: true });
  }
}

async function main() {
  const result = await install(parseArgs(process.argv.slice(2)));
  console.log(JSON.stringify(result));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[community-theme] ${error.message}`);
    process.exitCode = 1;
  });
}
