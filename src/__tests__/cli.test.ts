import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import sharp from "sharp";

const exec = promisify(execFile);

// Use tsx to run the TypeScript source directly
const CLI = path.resolve("src/index.ts");
const TSX = path.resolve("node_modules/.bin/tsx");

function tmpDir(): string {
  return path.join(os.tmpdir(), `towebp-cli-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
}

async function createTestPng(filePath: string): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await sharp({
    create: { width: 10, height: 10, channels: 3, background: { r: 255, g: 0, b: 0 } },
  })
    .png()
    .toFile(filePath);
}

async function cleanup(dir: string): Promise<void> {
  try {
    await fs.rm(dir, { recursive: true, force: true });
  } catch {
    // ignore
  }
}

describe("CLI", () => {
  let workDir: string;

  beforeEach(async () => {
    workDir = tmpDir();
    await fs.mkdir(workDir, { recursive: true });
  });

  afterEach(async () => {
    await cleanup(workDir);
  });

  it("prints help with --help", async () => {
    const { stdout } = await exec(TSX, [CLI, "--help"]);
    expect(stdout).toContain("towebp");
    expect(stdout).toContain("Usage:");
    expect(stdout).toContain("--quality");
  });

  it("prints version with --version", async () => {
    const { stdout } = await exec(TSX, [CLI, "--version"]);
    expect(stdout.trim()).toMatch(/^\d+\.\d+\.\d+$/);
  });

  it("exits with error on no arguments", async () => {
    try {
      await exec(TSX, [CLI]);
      expect.fail("should have thrown");
    } catch (err: unknown) {
      const error = err as { code: number; stderr: string };
      expect(error.code).toBe(1);
      expect(error.stderr).toContain("no input");
    }
  });

  it("converts a single file via CLI", async () => {
    const inputPath = path.join(workDir, "cli-test.png");
    await createTestPng(inputPath);

    const { stdout } = await exec(TSX, [CLI, inputPath]);
    expect(stdout).toContain("Processed:");

    const stat = await fs.stat(path.join(workDir, "cli-test.webp"));
    expect(stat.size).toBeGreaterThan(0);
  });

  it("converts a directory via CLI", async () => {
    await createTestPng(path.join(workDir, "a.png"));
    await createTestPng(path.join(workDir, "b.png"));

    const { stdout } = await exec(TSX, [CLI, workDir]);
    expect(stdout).toContain("Total files:");
    expect(stdout).toContain("2");
  });

  it("exits with error on invalid input", async () => {
    try {
      await exec(TSX, [CLI, "/nonexistent/path"]);
      expect.fail("should have thrown");
    } catch (err: unknown) {
      const error = err as { code: number; stderr: string };
      expect(error.code).toBe(1);
    }
  });

  it("exits with error on unknown flag", async () => {
    try {
      await exec(TSX, [CLI, "--badopt"]);
      expect.fail("should have thrown");
    } catch (err: unknown) {
      const error = err as { code: number; stderr: string };
      expect(error.code).toBe(1);
      expect(error.stderr).toContain("unknown option");
    }
  });
});
