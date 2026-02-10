export interface ConversionConfig {
  quality: number;
  maxConcurrent: number;
  inputFormats: string[];
  tempDir: string;
}

export interface ConversionStats {
  processed: number;
  skipped: number;
  failed: FailedFile[];
  totalFiles: number;
  totalBytes: number;
  savedBytes: number;
  startTime: number | null;
  endTime: number | null;
}

export interface ConversionResult {
  totalFiles: number;
  processed: number;
  skipped: number;
  failed: FailedFile[];
  duration: string;
  totalSize: string;
  savedSize: string;
  compressionRatio: string;
}

export interface FailedFile {
  file: string;
  error: string;
}

export interface FileConversionResult {
  success: boolean;
  skipped?: boolean;
  error?: string;
}

export interface ConversionTask {
  inputPath: string;
  outputPath: string;
}

export interface ParsedArgs {
  input: string;
  outputDir?: string;
  quality: number;
  recursive: boolean;
  help: boolean;
  version: boolean;
}
