import { execFile } from "child_process";
import { existsSync, mkdirSync, writeFileSync, readFileSync, unlinkSync } from "fs";
import { join } from "path";
import { promisify } from "util";
import { requestUrl } from "obsidian";
import type { TranscriptSegment, WhisperModelSize } from "./types";

const execFileAsync = promisify(execFile);

const WHISPER_RELEASES_BASE =
  "https://github.com/ggerganov/whisper.cpp/releases/latest/download";

const MODEL_URLS: Record<WhisperModelSize, string> = {
  tiny: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin",
  base: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin",
  small: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin",
  medium: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.en.bin",
};

export class WhisperManager {
  private whisperDir: string;

  constructor(pluginDir: string) {
    this.whisperDir = join(pluginDir, "whisper");
    if (!existsSync(this.whisperDir)) {
      mkdirSync(this.whisperDir, { recursive: true });
    }
  }

  get binaryPath(): string {
    return join(this.whisperDir, "whisper-cli");
  }

  modelPath(size: WhisperModelSize): string {
    return join(this.whisperDir, `ggml-${size}.en.bin`);
  }

  isBinaryInstalled(): boolean {
    return existsSync(this.binaryPath);
  }

  isModelInstalled(size: WhisperModelSize): boolean {
    return existsSync(this.modelPath(size));
  }

  async ensureBinary(
    onProgress?: (message: string) => void,
  ): Promise<void> {
    if (this.isBinaryInstalled()) return;

    onProgress?.("Downloading whisper.cpp binary...");

    // Try to build from homebrew or download pre-built
    try {
      const { stdout } = await execFileAsync("which", ["whisper-cli"]);
      const systemPath = stdout.trim();
      if (systemPath && existsSync(systemPath)) {
        // Symlink to system-installed whisper
        const { symlinkSync } = await import("fs");
        symlinkSync(systemPath, this.binaryPath);
        onProgress?.("Using system-installed whisper-cli");
        return;
      }
    } catch {
      // Not installed system-wide, that's fine
    }

    // Fallback: download pre-built binary
    // For macOS ARM64 — user may need to build from source
    onProgress?.(
      "whisper-cli not found. Install via: brew install whisper-cpp",
    );
    throw new Error(
      "whisper-cli not found. Please install: brew install whisper-cpp\n" +
        "Then restart Obsidian.",
    );
  }

  async ensureModel(
    size: WhisperModelSize,
    onProgress?: (message: string) => void,
  ): Promise<void> {
    if (this.isModelInstalled(size)) return;

    const url = MODEL_URLS[size];
    onProgress?.(`Downloading Whisper ${size} model... This may take a few minutes.`);

    const response = await requestUrl({ url });
    writeFileSync(this.modelPath(size), Buffer.from(response.arrayBuffer));

    onProgress?.(`Whisper ${size} model downloaded.`);
  }
}

export class Transcriber {
  private whisperManager: WhisperManager;

  constructor(pluginDir: string) {
    this.whisperManager = new WhisperManager(pluginDir);
  }

  get manager(): WhisperManager {
    return this.whisperManager;
  }

  async transcribeFile(
    wavPath: string,
    modelSize: WhisperModelSize,
    onProgress?: (message: string) => void,
  ): Promise<TranscriptSegment[]> {
    // Ensure dependencies
    await this.whisperManager.ensureBinary(onProgress);
    await this.whisperManager.ensureModel(modelSize, onProgress);

    onProgress?.("Transcribing audio...");

    const tempVtt = wavPath.replace(/\.wav$/, ".vtt");

    try {
      // Run whisper directly on the WAV file
      await execFileAsync(
        this.whisperManager.binaryPath,
        [
          "-m", this.whisperManager.modelPath(modelSize),
          "-f", wavPath,
          "--output-vtt",
          "--output-file", wavPath.replace(/\.wav$/, ""),
          "--no-prints",
        ],
        { maxBuffer: 50 * 1024 * 1024 },
      );

      onProgress?.("Parsing transcript...");

      if (!existsSync(tempVtt)) {
        throw new Error("Whisper did not produce VTT output");
      }

      const vttContent = readFileSync(tempVtt, "utf-8");
      return this.parseVTT(vttContent);
    } finally {
      // Cleanup temp files
      for (const f of [wavPath, tempVtt]) {
        try {
          if (existsSync(f)) unlinkSync(f);
        } catch {
          // ignore cleanup errors
        }
      }
    }
  }

  async transcribe(
    audioBlob: Blob,
    modelSize: WhisperModelSize,
    onProgress?: (message: string) => void,
  ): Promise<TranscriptSegment[]> {
    // Ensure dependencies
    await this.whisperManager.ensureBinary(onProgress);
    await this.whisperManager.ensureModel(modelSize, onProgress);

    // Write audio to temp WAV file
    onProgress?.("Preparing audio...");
    const tempDir = join(this.whisperManager["whisperDir"], "temp");
    if (!existsSync(tempDir)) {
      mkdirSync(tempDir, { recursive: true });
    }

    const tempWav = join(tempDir, `recording-${Date.now()}.wav`);
    const tempVtt = tempWav.replace(".wav", ".vtt");

    try {
      // Convert blob to WAV using ffmpeg or write directly
      const arrayBuffer = await audioBlob.arrayBuffer();
      const buffer = Buffer.from(arrayBuffer);
      writeFileSync(tempWav, buffer);

      // Convert to 16kHz mono WAV if needed (whisper requirement)
      const convertedWav = tempWav.replace(".wav", "-16k.wav");
      try {
        await execFileAsync("ffmpeg", [
          "-i", tempWav,
          "-ar", "16000",
          "-ac", "1",
          "-y",
          convertedWav,
        ]);
      } catch {
        // If ffmpeg not available, try with raw file
        // whisper.cpp may handle conversion internally
        onProgress?.("ffmpeg not found, using raw audio (quality may vary)");
      }

      const inputFile = existsSync(convertedWav) ? convertedWav : tempWav;

      // Run whisper
      onProgress?.("Transcribing audio...");
      const { stdout, stderr } = await execFileAsync(
        this.whisperManager.binaryPath,
        [
          "-m", this.whisperManager.modelPath(modelSize),
          "-f", inputFile,
          "--output-vtt",
          "--output-file", tempWav.replace(".wav", ""),
          "--no-prints",
        ],
        { maxBuffer: 50 * 1024 * 1024 },
      );

      onProgress?.("Parsing transcript...");

      // Parse VTT output
      if (!existsSync(tempVtt)) {
        throw new Error("Whisper did not produce VTT output");
      }

      const vttContent = readFileSync(tempVtt, "utf-8");
      return this.parseVTT(vttContent);
    } finally {
      // Cleanup temp files
      for (const f of [tempWav, tempWav.replace(".wav", "-16k.wav"), tempVtt]) {
        try {
          if (existsSync(f)) unlinkSync(f);
        } catch {
          // ignore cleanup errors
        }
      }
    }
  }

  private parseVTT(vtt: string): TranscriptSegment[] {
    const segments: TranscriptSegment[] = [];
    const lines = vtt.split("\n");

    let i = 0;
    // Skip WEBVTT header
    while (i < lines.length && !lines[i].includes("-->")) {
      i++;
    }

    while (i < lines.length) {
      const line = lines[i].trim();

      if (line.includes("-->")) {
        const [startStr, endStr] = line.split("-->").map((s) => s.trim());
        const start = this.parseTimestamp(startStr);
        const end = this.parseTimestamp(endStr);

        i++;
        const textLines: string[] = [];
        while (i < lines.length && lines[i].trim() !== "") {
          textLines.push(lines[i].trim());
          i++;
        }

        const text = textLines.join(" ").trim();
        if (text) {
          segments.push({ start, end, text });
        }
      } else {
        i++;
      }
    }

    return segments;
  }

  private parseTimestamp(ts: string): number {
    // Format: HH:MM:SS.mmm or MM:SS.mmm
    const parts = ts.split(":");
    if (parts.length === 3) {
      const [h, m, s] = parts;
      return parseInt(h) * 3600 + parseInt(m) * 60 + parseFloat(s);
    } else if (parts.length === 2) {
      const [m, s] = parts;
      return parseInt(m) * 60 + parseFloat(s);
    }
    return 0;
  }
}
