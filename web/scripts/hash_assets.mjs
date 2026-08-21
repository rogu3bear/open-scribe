import { createHash } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import { readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";

const root = process.cwd();
const siteRoot = join(root, "target/site");
const pkgDir = join(siteRoot, "pkg");
const outputName = "open-scribe-web";

function hash(buffer) {
  return createHash("sha256").update(buffer).digest("hex").slice(0, 16);
}

async function removeOld(extension) {
  const pattern = new RegExp(`^${outputName}\\.[a-f0-9]{16}\\.${extension}$`);
  for (const entry of readdirSync(pkgDir)) {
    if (pattern.test(entry)) await rm(join(pkgDir, entry), { force: true });
  }
}

const source = Object.fromEntries(
  ["js", "wasm", "css"].map((extension) => [
    extension,
    join(pkgDir, `${outputName}.${extension}`),
  ]),
);

for (const path of Object.values(source)) {
  if (!existsSync(path)) throw new Error(`missing build artifact: ${path}`);
}

for (const extension of Object.keys(source)) await removeOld(extension);

const buffers = {
  js: await readFile(source.js),
  wasm: await readFile(source.wasm),
  css: await readFile(source.css),
};
const hashes = {
  wasm: hash(buffers.wasm),
  css: hash(buffers.css),
};
const names = {
  wasm: `${outputName}.${hashes.wasm}.wasm`,
  css: `${outputName}.${hashes.css}.css`,
};

const sourceJs = new TextDecoder().decode(buffers.js);
const wasmReference = /new URL\("([^"]+\.wasm)",import\.meta\.url\)/;
if (!wasmReference.test(sourceJs)) {
  throw new Error("built JavaScript omitted its expected Wasm reference");
}
const rewrittenJs = sourceJs.replace(
  wasmReference,
  `new URL("${names.wasm}",import.meta.url)`,
);
const rewrittenJsBytes = new TextEncoder().encode(rewrittenJs);
hashes.js = hash(rewrittenJsBytes);
names.js = `${outputName}.${hashes.js}.js`;

await writeFile(join(pkgDir, names.js), rewrittenJsBytes);
await writeFile(join(pkgDir, names.css), buffers.css);
await rename(source.wasm, join(pkgDir, names.wasm));
await rm(source.js, { force: true });
await rm(source.css, { force: true });

await writeFile(
  join(siteRoot, "asset-manifest.json"),
  `${JSON.stringify({
    js: `/pkg/${names.js}`,
    wasm: `/pkg/${names.wasm}`,
    css: `/pkg/${names.css}`,
    hashes,
  }, null, 2)}\n`,
);
await writeFile(
  join(root, "target/web-asset-hashes.env"),
  [
    `export OPEN_SCRIBE_WEB_JS_HASH="${hashes.js}"`,
    `export OPEN_SCRIBE_WEB_WASM_HASH="${hashes.wasm}"`,
    `export OPEN_SCRIBE_WEB_CSS_HASH="${hashes.css}"`,
    "",
  ].join("\n"),
);
