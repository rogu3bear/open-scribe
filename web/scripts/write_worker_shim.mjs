import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

const root = process.cwd();
const workerBundle = join(root, "web/build/index.js");
const shimPath = join(root, "web/build/_worker.js");

if (!existsSync(workerBundle)) {
  throw new Error(`missing Worker bundle: ${workerBundle}`);
}

await mkdir(dirname(shimPath), { recursive: true });
await writeFile(
  shimPath,
  [
    'import OpenScribeWeb from "./index.js";',
    "",
    'const STATIC_ASSET_PATHS = ["/asset-manifest.json"];',
    'const STATIC_ASSET_PREFIXES = ["/pkg/"];',
    "",
    "function shouldServeAsset(pathname) {",
    "  return STATIC_ASSET_PATHS.includes(pathname)",
    "    || STATIC_ASSET_PREFIXES.some((prefix) => pathname.startsWith(prefix));",
    "}",
    "",
    "export default class extends OpenScribeWeb {",
    "  async fetch(request) {",
    "    const url = new URL(request.url);",
    "    if (shouldServeAsset(url.pathname)) return this.env.ASSETS.fetch(request);",
    "    return super.fetch(request);",
    "  }",
    "}",
    "",
  ].join("\n"),
);
