#!/usr/bin/env node

import { createRequire } from "node:module";
import { ImageConverter } from "./converter.js";
import type { ParsedArgs } from "./types.js";

const require = createRequire(import.meta.url);
const { version: VERSION } = require("../package.json") as { version: string };

const HELP = `
lazywebp v${VERSION} — Convert images to WebP format

Usage:
  lazywebp <file...>                  Convert file(s), output next to source
  lazywebp <dir>                      Convert all images in dir, output next to sources
  lazywebp -o <outputDir> <input...>  Convert to separate output directory
  lazywebp -q 80 <file>               Custom quality (default: 90)
  lazywebp -r <dir>                   Recursive subdirectory processing

Options:
  -q, --quality <n>   WebP quality 1-100 (default: 90)
  -o, --output <dir>  Output directory (default: next to source)
  -r, --recursive     Process subdirectories recursively
  -h, --help          Show this help message
  -v, --version       Show version number

Supported formats: jpg, jpeg, png, gif, bmp, tiff, webp
`.trim();

function parseArgs(argv: string[]): ParsedArgs {
  const args = argv.slice(2);
  const result: ParsedArgs = {
    inputs: [],
    quality: 90,
    recursive: false,
    help: false,
    version: false,
  };

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];

    if (arg === "-h" || arg === "--help") {
      result.help = true;
      return result;
    }

    if (arg === "-v" || arg === "--version") {
      result.version = true;
      return result;
    }

    if (arg === "-r" || arg === "--recursive") {
      result.recursive = true;
      continue;
    }

    if (arg === "-q" || arg === "--quality") {
      const next = args[++i];
      if (next === undefined) {
        console.error("Error: --quality requires a numeric argument");
        process.exit(1);
      }
      const val = parseInt(next, 10);
      if (isNaN(val)) {
        console.error(`Error: invalid quality value: ${next}`);
        process.exit(1);
      }
      // Clamp to 1-100
      result.quality = Math.max(1, Math.min(val, 100));
      continue;
    }

    if (arg === "-o" || arg === "--output") {
      const next = args[++i];
      if (next === undefined) {
        console.error("Error: --output requires a directory argument");
        process.exit(1);
      }
      result.outputDir = next;
      continue;
    }

    if (arg.startsWith("-")) {
      console.error(`Error: unknown option: ${arg}`);
      console.error("Run lazywebp --help for usage");
      process.exit(1);
    }

    result.inputs.push(arg);
  }

  return result;
}

async function main(): Promise<void> {
  const parsed = parseArgs(process.argv);

  if (parsed.help) {
    console.log(HELP);
    return;
  }

  if (parsed.version) {
    console.log(VERSION);
    return;
  }

  if (parsed.inputs.length === 0) {
    console.error("Error: no input file or directory specified");
    console.error("Run lazywebp --help for usage");
    process.exit(1);
  }

  const converter = new ImageConverter(parsed.quality);
  const results = await converter.runAll(parsed.inputs, parsed.outputDir, parsed.recursive);

  console.log("\nConversion completed:");
  console.log(`  Total files: ${results.totalFiles}`);
  console.log(`  Processed:   ${results.processed}`);
  console.log(`  Skipped:     ${results.skipped}`);
  console.log(`  Failed:      ${results.failed.length}`);
  console.log(`  Duration:    ${results.duration}`);
  console.log(`  Total size:  ${results.totalSize}`);
  console.log(`  Saved:       ${results.savedSize}`);
  console.log(`  Compression: ${results.compressionRatio}`);

  if (results.failed.length > 0) {
    console.log("\nFailed conversions:");
    results.failed.forEach((f) => console.log(`  - ${f.file}: ${f.error}`));
    process.exit(1);
  }
}

main().catch((err) => {
  console.error("Error:", err instanceof Error ? err.message : String(err));
  process.exit(1);
});
