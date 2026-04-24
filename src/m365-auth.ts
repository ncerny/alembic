import { requestUrl } from "obsidian";
import { createServer, type Server } from "http";
import { randomBytes, createHash } from "crypto";

const MS_OFFICE_CLIENT_ID = "d3590ed6-52b3-4102-aeff-aad2292ab01c";
const AUTH_BASE = "https://login.microsoftonline.com/organizations/oauth2/v2.0";
const SCOPES = "https://outlook.office365.com/Calendars.Read offline_access";
const LOGIN_TIMEOUT_MS = 120_000;

export interface TokenData {
  accessToken: string;
  refreshToken: string;
  expiresAt: number;
}

export class M365Auth {
  private tokenData: TokenData | null;
  private onTokenUpdate: (data: TokenData | null) => Promise<void>;
  private loginServer: Server | null = null;

  constructor(
    savedTokenData: TokenData | null,
    onTokenUpdate: (data: TokenData | null) => Promise<void>,
  ) {
    this.tokenData = savedTokenData;
    this.onTokenUpdate = onTokenUpdate;
  }

  isAvailable(): boolean {
    return true;
  }

  hasRefreshToken(): boolean {
    return !!this.tokenData?.refreshToken;
  }

  /**
   * Get a valid access token, refreshing if needed.
   */
  async getAccessToken(): Promise<string | null> {
    if (!this.tokenData) return null;

    // Return cached token if still valid (5-min buffer)
    if (Date.now() < this.tokenData.expiresAt - 5 * 60 * 1000) {
      return this.tokenData.accessToken;
    }

    // Try refresh
    try {
      await this.refreshAccessToken();
      return this.tokenData?.accessToken || null;
    } catch (err) {
      console.error("[alembic] Token refresh failed:", err);
      this.tokenData = null;
      await this.onTokenUpdate(null);
      return null;
    }
  }

  /**
   * Start PKCE login flow. Opens browser, listens on localhost for callback.
   */
  async startLogin(): Promise<void> {
    const verifier = generateCodeVerifier();
    const challenge = generateCodeChallenge(verifier);

    return new Promise<void>((resolve, reject) => {
      let port = 0;
      let settled = false;

      const server = createServer(async (req, res) => {
        if (settled) return;

        const url = new URL(req.url || "/", `http://localhost:${port}`);
        const code = url.searchParams.get("code");
        const error = url.searchParams.get("error");
        const errorDesc = url.searchParams.get("error_description");

        if (error) {
          res.writeHead(200, { "Content-Type": "text/html" });
          res.end(resultPage(false, errorDesc || error));
          settled = true;
          cleanup();
          reject(new Error(errorDesc || error));
          return;
        }

        if (!code) {
          res.writeHead(400, { "Content-Type": "text/plain" });
          res.end("Missing authorization code");
          return;
        }

        res.writeHead(200, { "Content-Type": "text/html" });
        res.end(resultPage(true));

        try {
          await this.exchangeCode(code, verifier, port);
          settled = true;
          cleanup();
          resolve();
        } catch (err) {
          settled = true;
          cleanup();
          reject(err);
        }
      });

      server.listen(0, "127.0.0.1", () => {
        const addr = server.address();
        port = typeof addr === "object" && addr ? addr.port : 0;
        const redirectUri = `http://localhost:${port}`;

        const params = new URLSearchParams({
          client_id: MS_OFFICE_CLIENT_ID,
          response_type: "code",
          redirect_uri: redirectUri,
          scope: SCOPES,
          code_challenge: challenge,
          code_challenge_method: "S256",
        });

        const authUrl = `${AUTH_BASE}/authorize?${params.toString()}`;
        window.open(authUrl);
      });

      this.loginServer = server;

      const timeout = setTimeout(() => {
        if (!settled) {
          settled = true;
          cleanup();
          reject(new Error("Login timed out — no response within 2 minutes"));
        }
      }, LOGIN_TIMEOUT_MS);

      const cleanup = () => {
        clearTimeout(timeout);
        try { server.close(); } catch { /* ignore */ }
        this.loginServer = null;
      };
    });
  }

  private async exchangeCode(code: string, verifier: string, port: number): Promise<void> {
    const body = new URLSearchParams({
      client_id: MS_OFFICE_CLIENT_ID,
      grant_type: "authorization_code",
      code,
      redirect_uri: `http://localhost:${port}`,
      code_verifier: verifier,
    });

    const response = await requestUrl({
      url: `${AUTH_BASE}/token`,
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });

    const data = response.json;
    if (data.error) {
      throw new Error(data.error_description || data.error);
    }

    this.tokenData = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token,
      expiresAt: Date.now() + data.expires_in * 1000,
    };

    await this.onTokenUpdate(this.tokenData);
  }

  private async refreshAccessToken(): Promise<void> {
    if (!this.tokenData?.refreshToken) throw new Error("No refresh token");

    const body = new URLSearchParams({
      client_id: MS_OFFICE_CLIENT_ID,
      grant_type: "refresh_token",
      refresh_token: this.tokenData.refreshToken,
      scope: SCOPES,
    });

    const response = await requestUrl({
      url: `${AUTH_BASE}/token`,
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: body.toString(),
    });

    const data = response.json;
    if (data.error) {
      throw new Error(data.error_description || data.error);
    }

    this.tokenData = {
      accessToken: data.access_token,
      refreshToken: data.refresh_token || this.tokenData.refreshToken,
      expiresAt: Date.now() + data.expires_in * 1000,
    };

    await this.onTokenUpdate(this.tokenData);
  }

  logout(): void {
    this.tokenData = null;
    this.onTokenUpdate(null);
  }

  cancelLogin(): void {
    if (this.loginServer) {
      try { this.loginServer.close(); } catch { /* ignore */ }
      this.loginServer = null;
    }
  }

  getLoginCommand(): string {
    return "Use the Connect button in Alembic settings";
  }
}

function generateCodeVerifier(): string {
  return base64UrlEncode(randomBytes(32));
}

function generateCodeChallenge(verifier: string): string {
  const hash = createHash("sha256").update(verifier).digest();
  return base64UrlEncode(hash);
}

function base64UrlEncode(buffer: Buffer): string {
  return buffer.toString("base64")
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function resultPage(success: boolean, errorMsg?: string): string {
  if (success) {
    return `<!DOCTYPE html><html><head><title>Alembic</title></head>
<body style="font-family:system-ui;text-align:center;padding:60px">
<h2>✅ Connected to Microsoft 365</h2>
<p>You can close this tab and return to Obsidian.</p>
</body></html>`;
  }
  return `<!DOCTYPE html><html><head><title>Alembic</title></head>
<body style="font-family:system-ui;text-align:center;padding:60px">
<h2>⛔ Authentication Failed</h2>
<p>${errorMsg}</p>
<p>Close this tab and try again in Obsidian settings.</p>
</body></html>`;
}
