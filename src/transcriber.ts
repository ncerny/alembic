import { execFile } from "child_process";
import { existsSync, unlinkSync, readFileSync } from "fs";
import { join } from "path";
import { tmpdir } from "os";
import { promisify } from "util";
import type { TranscriptSegment } from "./types";

const execFileAsync = promisify(execFile);

export class Transcriber {
  private appPath: string;
  private helperPath: string;

  constructor(pluginDir: string) {
    this.appPath = `${pluginDir}/audio-capture.app`;
    this.helperPath = `${this.appPath}/Contents/MacOS/audio-capture`;
  }

  isHelperInstalled(): boolean {
    return existsSync(this.helperPath);
  }

  async transcribeFile(
    wavPath: string,
    onProgress?: (message: string) => void,
    vocabularyHints?: string[],
  ): Promise<TranscriptSegment[]> {
    if (!this.isHelperInstalled()) {
      throw new Error(
        "audio-capture helper not found.\n" +
          "Build it: cd swift-helper && bash build.sh",
      );
    }

    onProgress?.("Transcribing audio with macOS Speech Recognition...");

    // Diagnostic: check WAV file has actual audio data
    const { statSync } = require("fs");
    const fileSize = statSync(wavPath).size;
    console.log(`[transcribe] WAV file: ${wavPath} (${fileSize} bytes)`);
    if (fileSize < 1000) {
      throw new Error(
        `WAV file is too small (${fileSize} bytes) — likely no audio was captured. ` +
        `Check that the target app is producing audio and Screen Recording permission is granted.`,
      );
    }

    // Launch via 'open -W' so macOS properly associates the app bundle
    // with TCC permissions (Speech Recognition requires this)
    const stdoutFile = join(tmpdir(), `alembic-transcribe-out-${Date.now()}.json`);
    const stderrFile = join(tmpdir(), `alembic-transcribe-err-${Date.now()}.txt`);

    try {
      await execFileAsync(
        "open",
        [
          "-W",
          "--stdout", stdoutFile,
          "--stderr", stderrFile,
          this.appPath,
          "--args", "transcribe", "--input", wavPath,
          ...(vocabularyHints?.length ? ["--vocabulary", vocabularyHints.join(",")] : []),
        ],
        { timeout: 300_000 },
      );

      const stdout = existsSync(stdoutFile)
        ? readFileSync(stdoutFile, "utf-8")
        : "";
      const stderr = existsSync(stderrFile)
        ? readFileSync(stderrFile, "utf-8")
        : "";

      if (stderr.trim()) {
        console.log(`[transcribe] stderr: ${stderr.trim()}`);
      }
      console.log(`[transcribe] stdout (${stdout.length} chars): ${stdout.substring(0, 200)}`);

      onProgress?.("Parsing transcript...");

      const segments: TranscriptSegment[] = JSON.parse(stdout || "[]");
      return segments;
    } catch (err: unknown) {
      const stderr = existsSync(stderrFile)
        ? readFileSync(stderrFile, "utf-8").trim()
        : "";
      const execErr = err as { message?: string };
      const detail = stderr || execErr.message || "Unknown transcription error";
      throw new Error(`Transcription failed: ${detail}`);
    } finally {
      // Cleanup temp files (keep WAV for debugging)
      console.log(`[transcribe] WAV kept for debugging: ${wavPath}`);
      for (const f of [stdoutFile, stderrFile]) {
        try {
          if (existsSync(f)) unlinkSync(f);
        } catch {
          // ignore cleanup errors
        }
      }
    }
  }
}
