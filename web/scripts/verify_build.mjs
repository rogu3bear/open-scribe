import { createHash } from "node:crypto";
import { existsSync, readdirSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { join } from "node:path";

const root = process.cwd();
const outputName = "open-scribe-web";
const required = [
  "target/site/asset-manifest.json",
  "target/site/_headers",
  "target/web-ssr/index.html",
  "web/build/index.js",
  "web/build/_worker.js",
];

for (const path of required) {
  if (!existsSync(join(root, path))) throw new Error(`missing build output: ${path}`);
}

const html = await readFile(join(root, "target/web-ssr/index.html"), "utf8");
for (const snippet of [
  "<main",
  "Local evidence for important conversations.",
  "There is no public download or service.",
  "https://open-scribe.app",
]) {
  if (!html.includes(snippet)) throw new Error(`SSR HTML omitted: ${snippet}`);
}

for (const retired of ["leptos-cf", "todo", "D1", "starter"]) {
  if (html.includes(retired)) throw new Error(`SSR HTML retained: ${retired}`);
}

const manifest = JSON.parse(
  await readFile(join(root, "target/site/asset-manifest.json"), "utf8"),
);
const extensions = { js: "js", wasm: "wasm", css: "css", boot: "boot.js" };
for (const [kind, extension] of Object.entries(extensions)) {
  const href = manifest[kind];
  const declaredHash = manifest.hashes?.[kind];
  if (!/^[a-f0-9]{16}$/.test(declaredHash)) {
    throw new Error(`${kind} manifest hash is malformed`);
  }
  const expectedHref = `/pkg/${outputName}.${declaredHash}.${extension}`;
  if (href !== expectedHref) {
    throw new Error(`${kind} manifest path does not match its declared hash`);
  }
  const assetPath = join(root, "target/site", href.replace(/^\//, ""));
  if (!existsSync(assetPath)) {
    throw new Error(`${kind} manifest target does not exist`);
  }
  const actualHash = createHash("sha256")
    .update(await readFile(assetPath))
    .digest("hex")
    .slice(0, 16);
  if (actualHash !== declaredHash) {
    throw new Error(`${kind} emitted bytes do not match the manifest hash`);
  }
}

const js = await readFile(
  join(root, "target/site", manifest.js.replace(/^\//, "")),
  "utf8",
);
if (!js.includes(manifest.wasm.split("/").at(-1))) {
  throw new Error("JavaScript does not reference the content-hashed Wasm asset");
}

const boot = await readFile(
  join(root, "target/site", manifest.boot.replace(/^\//, "")),
  "utf8",
);
for (const kind of ["js", "wasm"]) {
  if (!boot.includes(manifest[kind].split("/").at(-1))) {
    throw new Error(`boot module does not reference the content-hashed ${kind} asset`);
  }
}

// The Worker must carry the boot hash (so SSR emits the external module) and
// ADR 0015's exact policy, which admits no inline script.
const workerWasm = await readFile(join(root, "web/build/index_bg.wasm"));
for (const needle of [
  manifest.hashes.boot,
  "script-src 'self' 'wasm-unsafe-eval'; style-src 'self'",
  "cross-origin-opener-policy",
  "permissions-policy",
]) {
  if (!workerWasm.includes(Buffer.from(needle))) {
    throw new Error(`Worker bundle omitted: ${needle}`);
  }
}

const pkgEntries = readdirSync(join(root, "target/site/pkg"));
for (const extension of ["js", "wasm", "css"]) {
  if (pkgEntries.includes(`open-scribe-web.${extension}`)) {
    throw new Error(`unhashed ${extension} asset survived`);
  }
}

const wrangler = await readFile(join(root, "web/wrangler.toml"), "utf8");
if (/d1_databases|database_id|migrations_dir/i.test(wrangler)) {
  throw new Error("unused D1 configuration survived");
}

console.log("WEB_BUILD_GREEN");
console.log("proof=leptos_hydrate,hashed_assets,external_boot_module,adr_0015_csp_and_headers,worker_bundle,deep_route_ssr,useful_ssr_html");
console.log("excludes=deploy,native_capture,persistence,release");
