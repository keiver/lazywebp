import path from "node:path";
import fs from "node:fs";

const INPUT_FORMATS = ["jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp"];

export function isImageFile(filePath: string): boolean {
  const ext = path.extname(filePath).toLowerCase().slice(1);
  return INPUT_FORMATS.includes(ext);
}

export function formatBytes(bytes: number): string {
  const units = ["B", "KB", "MB", "GB"];
  let size = bytes;
  let unit = 0;

  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }

  return `${size.toFixed(2)} ${units[unit]}`;
}

export function formatDuration(ms: number): string {
  const seconds = Math.floor(ms / 1000);
  const minutes = Math.floor(seconds / 60);
  return minutes > 0 ? `${minutes}m ${seconds % 60}s` : `${seconds}s`;
}

export function getDiskSpace(dir: string): Promise<{ available: number }> {
  return new Promise((resolve) => {
    const target = process.platform === "win32" ? path.parse(dir).root : dir;
    fs.statfs(target, (err, stats) => {
      if (err) {
        resolve({ available: Infinity });
        return; // Bug fix #3: return after resolve to prevent fallthrough
      }
      resolve({ available: stats.bavail * stats.bsize });
    });
  });
}
