import { execFileSync } from "child_process";
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
      const env: Record<string, string> = { ...process.env } as Record<string, string>;
      if (this.caCertPath) {
        env.REQUESTS_CA_BUNDLE = this.caCertPath;
      }

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
      const env: Record<string, string> = { ...process.env } as Record<string, string>;
      if (this.caCertPath) {
        env.REQUESTS_CA_BUNDLE = this.caCertPath;
      }

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
   * Get the login command for the user to run.
   */
  getLoginCommand(): string {
    return "az login --allow-no-subscriptions";
  }

  getAzPath(): string | null {
    return this.azPath;
  }
}
