import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { ImageConverter } from "../converter.js";
import sharp from "sharp";
import fs from "node:fs/promises";
import path from "node:path";
import os from "node:os";

function tmpDir(): string {
  return path.join(os.tmpdir(), `towebp-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
}

async function createTestPng(filePath: string, width = 10, height = 10): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await sharp({
    create: { width, height, channels: 3, background: { r: 255, g: 0, b: 0 } },
  })
    .png()
    .toFile(filePath);
}

async function createTestJpg(filePath: string, width = 10, height = 10): Promise<void> {
  await fs.mkdir(path.dirname(filePath), { recursive: true });
  await sharp({
    create: { width, height, channels: 3, background: { r: 0, g: 255, b: 0 } },
  })
    .jpeg()
    .toFile(filePath);
}

async function cleanup(dir: string): Promise<void> {
  try {
    await fs.rm(dir, { recursive: true, force: true });
  } catch {
    // ignore
  }
}

describe("ImageConverter", () => {
  let workDir: string;

  beforeEach(async () => {
    workDir = tmpDir();
    await fs.mkdir(workDir, { recursive: true });
  });

  afterEach(async () => {
    await cleanup(workDir);
  });

  describe("single file conversion", () => {
    it("converts a PNG to WebP next to the source", async () => {
      const inputPath = path.join(workDir, "test.png");
      await createTestPng(inputPath);

      const converter = new ImageConverter();
      const result = await converter.run(inputPath);

      expect(result.processed).toBe(1);
      expect(result.skipped).toBe(0);
      expect(result.failed.length).toBe(0);

      const outputPath = path.join(workDir, "test.webp");
      const stat = await fs.stat(outputPath);
      expect(stat.size).toBeGreaterThan(0);
    });

    it("converts a JPG to WebP in a separate output directory", async () => {
      const inputPath = path.join(workDir, "photo.jpg");
      const outDir = path.join(workDir, "out");
      await createTestJpg(inputPath);

      const converter = new ImageConverter();
      const result = await converter.run(inputPath, outDir);

      expect(result.processed).toBe(1);

      const outputPath = path.join(outDir, "photo.webp");
      const stat = await fs.stat(outputPath);
      expect(stat.size).toBeGreaterThan(0);
    });

    it("skips when source is .webp and output would be same path", async () => {
      const inputPath = path.join(workDir, "already.webp");
      // Create a small webp
      await sharp({
        create: { width: 10, height: 10, channels: 3, background: { r: 0, g: 0, b: 255 } },
      })
        .webp()
        .toFile(inputPath);

      const converter = new ImageConverter();
      const result = await converter.run(inputPath);

      expect(result.skipped).toBe(1);
      expect(result.processed).toBe(0);
    });

    it("rejects non-image files", async () => {
      const inputPath = path.join(workDir, "readme.txt");
      await fs.writeFile(inputPath, "hello");

      const converter = new ImageConverter();
      await expect(converter.run(inputPath)).rejects.toThrow("Not a supported image file");
    });
  });

  describe("directory conversion", () => {
    it("converts all images in a directory (same-dir output)", async () => {
      await createTestPng(path.join(workDir, "a.png"));
      await createTestJpg(path.join(workDir, "b.jpg"));

      const converter = new ImageConverter();
      const result = await converter.run(workDir);

      expect(result.totalFiles).toBe(2);
      expect(result.processed).toBe(2);

      const aWebp = await fs.stat(path.join(workDir, "a.webp"));
      const bWebp = await fs.stat(path.join(workDir, "b.webp"));
      expect(aWebp.size).toBeGreaterThan(0);
      expect(bWebp.size).toBeGreaterThan(0);
    });

    it("converts directory to separate output directory", async () => {
      await createTestPng(path.join(workDir, "c.png"));
      const outDir = path.join(workDir, "output");

      const converter = new ImageConverter();
      const result = await converter.run(workDir, outDir);

      expect(result.processed).toBe(1);
      const stat = await fs.stat(path.join(outDir, "c.webp"));
      expect(stat.size).toBeGreaterThan(0);
    });

    it("skips unchanged files on second run", async () => {
      await createTestPng(path.join(workDir, "d.png"));
      const outDir = path.join(workDir, "output");

      const converter1 = new ImageConverter();
      await converter1.run(workDir, outDir);

      const converter2 = new ImageConverter();
      const result = await converter2.run(workDir, outDir);

      expect(result.skipped).toBe(1);
      expect(result.processed).toBe(0);
    });

    it("throws on empty directory", async () => {
      const emptyDir = path.join(workDir, "empty");
      await fs.mkdir(emptyDir, { recursive: true });

      const converter = new ImageConverter();
      await expect(converter.run(emptyDir)).rejects.toThrow("No valid image files found");
    });
  });

  describe("recursive mode", () => {
    it("processes images in subdirectories", async () => {
      await createTestPng(path.join(workDir, "top.png"));
      await createTestPng(path.join(workDir, "sub", "nested.png"));

      const converter = new ImageConverter();
      const result = await converter.run(workDir, undefined, true);

      expect(result.totalFiles).toBe(2);
      expect(result.processed).toBe(2);

      const topWebp = await fs.stat(path.join(workDir, "top.webp"));
      const nestedWebp = await fs.stat(path.join(workDir, "sub", "nested.webp"));
      expect(topWebp.size).toBeGreaterThan(0);
      expect(nestedWebp.size).toBeGreaterThan(0);
    });

    it("mirrors subdirectory structure in separate output", async () => {
      await createTestPng(path.join(workDir, "a", "deep.png"));
      const outDir = path.join(workDir, "output");

      const converter = new ImageConverter();
      const result = await converter.run(workDir, outDir, true);

      expect(result.processed).toBe(1);
      const stat = await fs.stat(path.join(outDir, "a", "deep.webp"));
      expect(stat.size).toBeGreaterThan(0);
    });
  });

  describe("quality option", () => {
    it("uses custom quality", async () => {
      const inputPath = path.join(workDir, "q.png");
      // Use a large noisy image so quality difference is measurable
      const size = 500;
      const channels = 3;
      const noise = Buffer.alloc(size * size * channels);
      for (let i = 0; i < noise.length; i++) {
        noise[i] = Math.floor(Math.random() * 256);
      }
      await fs.mkdir(path.dirname(inputPath), { recursive: true });
      await sharp(noise, { raw: { width: size, height: size, channels } })
        .png()
        .toFile(inputPath);

      const converterHigh = new ImageConverter(100);
      await converterHigh.run(inputPath);
      const highSize = (await fs.stat(path.join(workDir, "q.webp"))).size;

      // Remove output for second run
      await fs.unlink(path.join(workDir, "q.webp"));

      const converterLow = new ImageConverter(1);
      await converterLow.run(inputPath);
      const lowSize = (await fs.stat(path.join(workDir, "q.webp"))).size;

      // Lower quality should produce smaller file with noisy content
      expect(lowSize).toBeLessThan(highSize);
    });

    it("clamps quality to valid range", () => {
      const converterLow = new ImageConverter(0);
      expect(converterLow.config.quality).toBe(1);

      const converterHigh = new ImageConverter(200);
      expect(converterHigh.config.quality).toBe(100);
    });
  });

  describe("error handling", () => {
    it("records failed files without crashing", async () => {
      const inputPath = path.join(workDir, "corrupt.png");
      await fs.writeFile(inputPath, "not a real image");

      const converter = new ImageConverter();
      const result = await converter.run(workDir);

      expect(result.failed.length).toBe(1);
      expect(result.failed[0].file).toBe("corrupt.png");
    });
  });
});
