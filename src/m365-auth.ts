import { execFile, execFileSync } from "child_process";
import { existsSync } from "fs";

const AZ_PATHS = [
  "/opt/homebrew/bin/az",
  "/usr/local/bin/az",
  "/usr/bin/az",
];

// Corporate proxy CA cert — az CLI needs REQUESTS_CA_BUNDLE
const CA_CERT_PATHS = [
  `${process.env.HOME}/.config/opencode/corp-cacerts.pem`,
  `${process.env.HOME}/certs/cacert.pem`,
];

export class M365Auth {
  private azPath: string | null = null;
  private caCertPath: string | null = null;

  constructor() {
    this.azPath = AZ_PATHS.find((p) => existsSync(p)) || null;
    this.caCertPath = CA_CERT_PATHS.find((p) => existsSync(p)) ||
      process.env.REQUESTS_CA_BUNDLE || null;
  }

  isAvailable(): boolean {
    return this.azPath !== null;
  }

  /**
   * Get a Microsoft Graph access token via Azure CLI.
   * Returns null if not logged in or az is unavailable.
   */
  getAccessToken(): string | null {
    if (!this.azPath) return null;

    try {
      const env = this.getEnv();

      const token = execFileSync(this.azPath, [
        "account", "get-access-token",
        "--resource-type", "ms-graph",
        "--query", "accessToken",
        "-o", "tsv",
      ], {
        encoding: "utf-8",
        timeout: 10000,
        env,
      }).trim();

      return token || null;
    } catch (err) {
      console.error("[alembic] Failed to get M365 token:", err);
      return null;
    }
  }

  /**
   * Check if the user is logged in to Azure CLI.
   */
  isLoggedIn(): boolean {
    if (!this.azPath) return false;

    try {
      const env = this.getEnv();

      execFileSync(this.azPath, ["account", "show"], {
        encoding: "utf-8",
        timeout: 5000,
        env,
      });
      return true;
    } catch {
      return false;
    }
  }

  /**
   * Get the tenant ID from the current az session (if any).
   */
  getTenantId(): string | null {
    if (!this.azPath) return null;

    try {
      const env = this.getEnv();
      return execFileSync(this.azPath, [
        "account", "show", "--query", "tenantId", "-o", "tsv",
      ], { encoding: "utf-8", timeout: 5000, env }).trim() || null;
    } catch {
      return null;
    }
  }

  /**
   * Spawn az login as a child process. Opens browser for auth.
   * Returns a promise that resolves on success, rejects on failure.
   */
  login(tenantId?: string): Promise<void> {
    if (!this.azPath) return Promise.reject(new Error("Azure CLI not found"));

    return new Promise((resolve, reject) => {
      const args = ["login", "--allow-no-subscriptions", "--output", "none"];
      if (tenantId) {
        args.push("--tenant", tenantId);
      }

      const env = this.getEnv();
      const proc = execFile(this.azPath!, args, { env, timeout: 120000 }, (err) => {
        if (err) {
          reject(new Error(`az login failed: ${err.message}`));
        } else {
          resolve();
        }
      });

      proc.stderr?.on("data", (data: string) => {
        console.log("[alembic] az login:", data.toString().trim());
      });
    });
  }

  /**
   * Get the login command for the user to run manually.
   */
  getLoginCommand(): string {
    return "az login --allow-no-subscriptions";
  }

  getAzPath(): string | null {
    return this.azPath;
  }

  private getEnv(): Record<string, string> {
    const env: Record<string, string> = { ...process.env } as Record<string, string>;
    if (this.caCertPath) {
      env.REQUESTS_CA_BUNDLE = this.caCertPath;
    }
    return env;
  }
}
