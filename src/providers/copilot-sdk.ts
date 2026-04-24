import type { LLMProvider } from "../summarizer";
import type { MeetingSummary } from "../types";
import { SYSTEM_PROMPT, buildUserPrompt } from "../prompts";

export class CopilotSDKProvider implements LLMProvider {
  private pluginDir: string;

  constructor(pluginDir: string) {
    this.pluginDir = pluginDir;
  }

  async summarize(
    transcript: string,
    userNotes: string,
  ): Promise<MeetingSummary> {
    const path = require("path");
    const fs = require("fs");

    // Resolve from plugin's own node_modules — Electron doesn't search plugin dirs
    const sdkPath = path.join(this.pluginDir, "node_modules", "@github", "copilot-sdk");
    const { CopilotClient, approveAll } = require(sdkPath);

    // Find the bundled CLI entry point
    const cliEntryPath = path.join(this.pluginDir, "node_modules", "@github", "copilot", "index.js");

    // Find actual node binary — Electron's process.execPath is the Obsidian binary
    const nodePaths = [
      "/opt/homebrew/bin/node",
      "/usr/local/bin/node",
      `${process.env.HOME}/.nodenv/shims/node`,
      `${process.env.HOME}/.nvm/current/bin/node`,
    ];
    const nodeBin = nodePaths.find((p) => fs.existsSync(p));
    if (!nodeBin) {
      throw new Error("Node.js not found. Install via Homebrew: brew install node");
    }

    // Get GitHub token — the CLI can't find `gh` from a GUI app's PATH
    const { execFileSync } = require("child_process");
    let githubToken: string;
    try {
      // Try gh first with known paths
      const ghPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"];
      const ghBin = ghPaths.find((p) => fs.existsSync(p));
      if (!ghBin) throw new Error("gh not found");
      githubToken = execFileSync(ghBin, ["auth", "token"], { encoding: "utf-8" }).trim();
    } catch {
      throw new Error("GitHub CLI not found or not authenticated. Run: gh auth login");
    }

    const client = new CopilotClient({
      cliPath: nodeBin,
      cliArgs: [cliEntryPath],
      githubToken,
    });

    try {
      await client.start();

      // Auto-select cheapest model with enough context for this transcript
      const userPrompt = buildUserPrompt(transcript, userNotes);
      const fullPrompt = `${SYSTEM_PROMPT}\n\n${userPrompt}`;
      // ~4 chars per token, plus headroom for the response
      const estimatedInputTokens = Math.ceil(fullPrompt.length / 4);
      const requiredContext = estimatedInputTokens + 4096;

      const models = await client.listModels();
      const eligible = models
        .filter((m: any) => {
          const enabled = !m.policy || m.policy.state === "enabled";
          const fits = m.capabilities?.limits?.max_context_window_tokens >= requiredContext;
          return enabled && fits;
        })
        .sort((a: any, b: any) => {
          const costA = a.billing?.multiplier ?? 1;
          const costB = b.billing?.multiplier ?? 1;
          return costA - costB;
        });

      if (eligible.length === 0) {
        throw new Error(
          `No available model has enough context (need ~${requiredContext} tokens). ` +
          `Available: ${models.map((m: any) => m.id).join(", ")}`,
        );
      }

      const selectedModel = eligible[0].id;
      console.log(`Alembic: auto-selected model "${selectedModel}" (${eligible[0].name})`);

      const session = await client.createSession({
        model: selectedModel,
        onPermissionRequest: approveAll,
      });

      // Scale timeout with transcript length — short clips may take 60s+,
      // so a 2-hour meeting transcript needs much more time
      const timeoutMs = Math.max(180_000, Math.ceil(fullPrompt.length / 500) * 60_000);

      const response = await session.sendAndWait(
        { prompt: fullPrompt },
        timeoutMs,
      );

      const content = response?.data?.content;
      if (!content) {
        throw new Error("No response from Copilot");
      }

      // Parse JSON from response, handling potential markdown code fences
      const jsonStr = content
        .replace(/^```json?\s*/i, "")
        .replace(/\s*```$/i, "")
        .trim();

      const parsed = JSON.parse(jsonStr) as MeetingSummary;

      // Validate required fields
      if (!parsed.summary) {
        throw new Error("Invalid summary response: missing summary field");
      }

      return {
        title: parsed.title || "Untitled Meeting",
        summary: parsed.summary,
        keyDecisions: parsed.keyDecisions || [],
        actionItems: parsed.actionItems || [],
        keyTopics: parsed.keyTopics || [],
        attendees: parsed.attendees || [],
      };
    } finally {
      await client.stop();
    }
  }
}
