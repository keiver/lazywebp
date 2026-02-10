import sharp from "sharp";
import path from "node:path";
import fs from "node:fs/promises";
import fsSync from "node:fs";
import crypto from "node:crypto";
import os from "node:os";
import { formatBytes, formatDuration, getDiskSpace, isImageFile } from "./utils.js";
import type { ConversionConfig, ConversionStats, ConversionResult, ConversionTask, FileConversionResult } from "./types.js";

export class ImageConverter {
  config: ConversionConfig;
  stats: ConversionStats;

  constructor(quality = 90) {
    this.config = {
      quality: Math.max(1, Math.min(quality, 100)),
      maxConcurrent: Math.max(1, Math.min(os.cpus().length - 1, 4)),
      inputFormats: ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp"],
    };

    this.stats = {
      processed: 0,
      skipped: 0,
      failed: [],
      totalFiles: 0,
      totalBytes: 0,
      savedBytes: 0,
      startTime: null,
      endTime: null,
    };

    sharp.cache({ memory: 512 });
  }

  private resetStats(): void {
    this.stats = {
      processed: 0,
      skipped: 0,
      failed: [],
      totalFiles: 0,
      totalBytes: 0,
      savedBytes: 0,
      startTime: null,
      endTime: null,
    };
  }

  async run(input: string, outputDir?: string, recursive = false): Promise<ConversionResult> {
    return this.runAll([input], outputDir, recursive);
  }

  async runAll(inputs: string[], outputDir?: string, recursive = false): Promise<ConversionResult> {
    this.resetStats();
    this.stats.startTime = Date.now();

    if (outputDir) {
      await fs.mkdir(outputDir, { recursive: true });
    }

    // Collect all tasks from files and directories
    const tasks: ConversionTask[] = [];
    for (const input of inputs) {
      const stat = await fs.stat(input);

      if (stat.isFile()) {
        this.collectFileTask(input, outputDir, tasks);
      } else if (stat.isDirectory()) {
        await this.collectDirectoryTasks(input, outputDir, recursive, tasks);
      } else {
        throw new Error(`Input is neither a file nor a directory: ${input}`);
      }
    }

    if (this.stats.totalFiles === 0) {
      throw new Error("No valid image files found");
    }

    await this.processInBatches(tasks);

    this.stats.endTime = Date.now();
    return this.buildResult();
  }

  private collectFileTask(inputPath: string, outputDir: string | undefined, tasks: ConversionTask[]): void {
    if (!isImageFile(inputPath)) {
      console.warn(`Skipping: not a supported image file: ${inputPath}`);
      this.stats.totalFiles++;
      this.stats.skipped++;
      return;
    }

    const outputPath = this.resolveOutputPath(inputPath, outputDir);

    if (path.resolve(inputPath) === path.resolve(outputPath)) {
      console.warn(`Skipping: source and output are the same file: ${inputPath}`);
      this.stats.totalFiles++;
      this.stats.skipped++;
      return;
    }

    this.stats.totalFiles++;
    tasks.push({ inputPath, outputPath });
  }

  private async collectDirectoryTasks(inputDir: string, outputDir: string | undefined, recursive: boolean, tasks: ConversionTask[]): Promise<void> {
    const sameDir = !outputDir;
    const resolvedOutput = outputDir ?? inputDir;

    if (!sameDir) {
      await this.validatePaths(inputDir, resolvedOutput);
    }

    const entries = recursive
      ? await fs.readdir(inputDir, { recursive: true })
      : await fs.readdir(inputDir);

    const imageFiles = (entries as string[]).filter((entry) => isImageFile(entry));

    for (const file of imageFiles) {
      const inputPath = path.join(inputDir, file);

      let outputPath: string;
      if (sameDir) {
        outputPath = path.join(path.dirname(inputPath), `${path.parse(file).name}.webp`);
      } else {
        const relDir = path.dirname(file);
        outputPath = path.join(resolvedOutput, relDir, `${path.parse(file).name}.webp`);
      }

      if (path.resolve(inputPath) === path.resolve(outputPath)) {
        console.warn(`Skipping: source and output are the same file: ${inputPath}`);
        this.stats.totalFiles++;
        this.stats.skipped++;
        continue;
      }

      this.stats.totalFiles++;
      tasks.push({ inputPath, outputPath });
    }
  }

  private resolveOutputPath(inputPath: string, outputDir?: string): string {
    const name = path.parse(inputPath).name;
    if (outputDir) {
      return path.join(outputDir, `${name}.webp`);
    }
    return path.join(path.dirname(inputPath), `${name}.webp`);
  }

  private async validatePaths(inputDir: string, outputDir: string): Promise<void> {
    const inputStats = await fs.stat(inputDir);
    if (!inputStats.isDirectory()) {
      throw new Error("Input path is not a directory");
    }

    await fs.access(inputDir, fsSync.constants.R_OK);
    await fs.mkdir(outputDir, { recursive: true });
    await fs.access(outputDir, fsSync.constants.W_OK);

    const { available } = await getDiskSpace(outputDir);
    const requiredSpace = await this.getDirectorySize(inputDir);

    if (available < requiredSpace * 1.2) {
      throw new Error("Insufficient disk space");
    }
  }

  private async getDirectorySize(dir: string): Promise<number> {
    const files = await fs.readdir(dir);
    const sizes = await Promise.all(
      files.map(async (file) => {
        try {
          const stats = await fs.stat(path.join(dir, file));
          return stats.size;
        } catch {
          return 0;
        }
      })
    );
    return sizes.reduce((acc, size) => acc + size, 0);
  }

  private async shouldProcessImage(inputPath: string, outputPath: string): Promise<boolean> {
    try {
      const outputExists = await fs
        .access(outputPath)
        .then(() => true)
        .catch(() => false);

      if (!outputExists) return true;

      const [inputStats, outputStats] = await Promise.all([
        fs.stat(inputPath),
        fs.stat(outputPath),
      ]);

      return inputStats.mtime > outputStats.mtime || outputStats.size === 0;
    } catch {
      return true;
    }
  }

  async convertImage(inputPath: string, outputPath: string): Promise<FileConversionResult> {
    // Bug fix #2: Declare tempOutput before try so it's accessible in catch
    let tempOutput: string | undefined;

    try {
      const needsProcessing = await this.shouldProcessImage(inputPath, outputPath);

      if (!needsProcessing) {
        this.stats.skipped++;
        return { success: true, skipped: true };
      }

      const inputSize = (await fs.stat(inputPath)).size;

      tempOutput = path.join(
        path.dirname(outputPath),
        `.towebp-${crypto.randomBytes(8).toString("hex")}.webp`
      );

      // Ensure output directory exists (for recursive mode with subdirs)
      await fs.mkdir(path.dirname(outputPath), { recursive: true });

      const pipeline = sharp(inputPath, {
        failOnError: true,
        limitInputPixels: 268402689, // 16384 x 16384
        sequentialRead: true,
      });

      const metadata = await pipeline.metadata();

      let sharpInstance = pipeline.rotate(); // Auto-rotate based on EXIF

      const space = metadata.space as string | undefined;
      if (space === "rgb" || space === "display-p3") {
        sharpInstance = sharpInstance.toColorspace("srgb");
      }

      await sharpInstance
        .toFormat("webp", {
          quality: this.config.quality,
          effort: 6,
          alphaQuality: 100,
          lossless: false,
          smartSubsample: true,
          nearLossless: false,
        })
        .toFile(tempOutput);

      const tempStats = await fs.stat(tempOutput);
      if (tempStats.size === 0) {
        throw new Error("Generated file is empty");
      }

      await fs.rename(tempOutput, outputPath);

      this.stats.processed++;
      this.stats.totalBytes += inputSize;
      this.stats.savedBytes += inputSize - tempStats.size;

      return { success: true, skipped: false };
    } catch (err) {
      // Bug fix #2: Guard with if (tempOutput) before cleanup
      if (tempOutput) {
        try {
          await fs.unlink(tempOutput);
        } catch {
          // ignore cleanup errors
        }
      }

      const message = err instanceof Error ? err.message : String(err);
      this.stats.failed.push({
        file: inputPath,
        error: message,
      });
      return { success: false, error: message };
    }
  }

  // Bug fix #1: Accept task descriptors, create promises lazily inside the batch loop
  private async processInBatches(tasks: ConversionTask[]): Promise<FileConversionResult[]> {
    const results: FileConversionResult[] = [];

    for (let i = 0; i < tasks.length; i += this.config.maxConcurrent) {
      const batch = tasks.slice(i, i + this.config.maxConcurrent);
      const batchResults = await Promise.all(
        batch.map((task) => this.convertImage(task.inputPath, task.outputPath))
      );
      results.push(...batchResults);

      const progress = (((i + batch.length) / tasks.length) * 100).toFixed(1);
      const savedMB = (this.stats.savedBytes / 1024 / 1024).toFixed(2);
      process.stdout.write(
        `\rProgress: ${progress}% (${i + batch.length}/${tasks.length}) | Saved: ${savedMB}MB`
      );
    }

    if (tasks.length > 0) {
      process.stdout.write("\n");
    }

    return results;
  }

  private buildResult(): ConversionResult {
    const duration = this.stats.startTime && this.stats.endTime
      ? formatDuration(this.stats.endTime - this.stats.startTime)
      : "0s";

    const ratio = this.stats.totalBytes > 0
      ? ((this.stats.savedBytes / this.stats.totalBytes) * 100).toFixed(2) + "%"
      : "0%";

    return {
      totalFiles: this.stats.totalFiles,
      processed: this.stats.processed,
      skipped: this.stats.skipped,
      failed: this.stats.failed,
      duration,
      totalSize: formatBytes(this.stats.totalBytes),
      savedSize: formatBytes(this.stats.savedBytes),
      compressionRatio: ratio,
    };
  }
}
