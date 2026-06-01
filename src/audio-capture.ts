import { execFile, spawn, type ChildProcess } from "child_process";
import { existsSync } from "fs";
import { join } from "path";
import { promisify } from "util";

const execFileAsync = promisify(execFile);

export class AudioCapture {
  private captureProcess: ChildProcess | null = null;
  private startTime = 0;
  private _duration = 0;
  private timerInterval: number | null = null;
  private onDurationUpdate: ((seconds: number) => void) | null = null;
  private _isRecording = false;
  private outputPath = "";
  private helperPath: string;
  private stopPromise: Promise<string> | null = null;

  constructor(pluginDir: string) {
    this.helperPath = join(pluginDir, "audio-capture.app", "Contents", "MacOS", "audio-capture");
  }

  get isRecording(): boolean {
    return this._isRecording;
  }

  get duration(): number {
    return this._duration;
  }

  isHelperInstalled(): boolean {
    return existsSync(this.helperPath);
  }

  async listApps(): Promise<{ pid: number; name: string }[]> {
    if (!this.isHelperInstalled()) {
      throw new Error("audio-capture helper not found. Build with: cd swift-helper && bash build.sh");
    }

    const { stdout } = await execFileAsync(this.helperPath, ["list"]);
    return stdout
      .trim()
      .split("\n")
      .filter((line) => line.includes("\t"))
      .map((line) => {
        const [pid, ...nameParts] = line.split("\t");
        return { pid: parseInt(pid), name: nameParts.join("\t") };
      });
  }

  async start(
    appName: string,
    outputPath: string,
    onDurationUpdate?: (seconds: number) => void,
  ): Promise<void> {
    if (this._isRecording) {
      throw new Error("Already recording");
    }

    if (!this.isHelperInstalled()) {
      throw new Error(
        "audio-capture helper not found.\n" +
        "Build it: cd swift-helper && bash build.sh\n" +
        "Then copy build/audio-capture to the plugin directory."
      );
    }

    this.onDurationUpdate = onDurationUpdate ?? null;
    this.outputPath = outputPath;

    return new Promise((resolve, reject) => {
      this.captureProcess = spawn(this.helperPath, [
        "capture",
        "--app", appName,
        "--output", outputPath,
      ]);

      let started = false;
      let stderrOutput = "";

      this.captureProcess.stdout?.on("data", (data: Buffer) => {
        const text = data.toString().trim();
        if (text === "RECORDING" && !started) {
          started = true;
          this._isRecording = true;
          this.startTime = Date.now();
          this._duration = 0;

          this.timerInterval = window.setInterval(() => {
            this._duration = Math.floor((Date.now() - this.startTime) / 1000);
            this.onDurationUpdate?.(this._duration);
          }, 1000);

          resolve();
        }
      });

      this.captureProcess.stderr?.on("data", (data: Buffer) => {
        const text = data.toString().trim();
        console.log(`[audio-capture] ${text}`);
        stderrOutput += text + "\n";
      });

      this.captureProcess.on("error", (err) => {
        if (!started) reject(err);
      });

      this.captureProcess.on("exit", (code, signal) => {
        if (!started) {
          const reason = signal
            ? `killed by signal ${signal}`
            : `exited with code ${code}`;
          const stderr = stderrOutput.trim();
          reject(new Error(`audio-capture ${reason}${stderr ? `\n${stderr}` : ""}`));
        }
        this.cleanup();
      });

      setTimeout(() => {
        if (!started) {
          this.captureProcess?.kill();
          reject(new Error("audio-capture timed out starting"));
        }
      }, 10000);
    });
  }

  stop(): Promise<string> {
    if (this.stopPromise) {
      return this.stopPromise;
    }

    if (!this._isRecording || !this.captureProcess) {
      throw new Error("No active recording");
    }

    const captureProcess = this.captureProcess;

    this.stopPromise = new Promise((resolve, reject) => {
      let settled = false;
      let timeout: NodeJS.Timeout | null = null;

      const finish = (complete: () => void) => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeout) {
          clearTimeout(timeout);
          timeout = null;
        }
        captureProcess.stdout?.off("data", onData);
        this.stopPromise = null;
        complete();
      };

      const onData = (data: Buffer) => {
        if (data.toString().trim() === "STOPPED") {
          finish(() => {
            this.cleanup();
            if (!existsSync(this.outputPath)) {
              reject(new Error("Recording finished but no audio file was created. Check Screen Recording permission in System Settings."));
              return;
            }
            resolve(this.outputPath);
          });
        }
      };

      timeout = setTimeout(() => {
        finish(() => {
          captureProcess.kill("SIGKILL");
          reject(new Error("audio-capture did not stop gracefully"));
        });
      }, 5000);

      captureProcess.stdout?.on("data", onData);

      // Send SIGINT to stop capture gracefully
      captureProcess.kill("SIGINT");
    });

    return this.stopPromise;
  }

  private cleanup(): void {
    this._isRecording = false;
    if (this.timerInterval) {
      window.clearInterval(this.timerInterval);
      this.timerInterval = null;
    }
    this.captureProcess = null;
    this.stopPromise = null;
  }
}

export function formatDuration(seconds: number): string {
  const h = Math.floor(seconds / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = seconds % 60;
  if (h > 0) {
    return `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
  }
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}

export function formatTimestamp(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = Math.floor(seconds % 60);
  return `${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}`;
}
