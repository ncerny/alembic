import type { LLMProvider } from "../summarizer";
import type { MeetingSummary } from "../types";
import { SYSTEM_PROMPT, buildUserPrompt } from "../prompts";

export class CopilotSDKProvider implements LLMProvider {
  private model: string;

  constructor(model: string) {
    this.model = model;
  }

  async summarize(
    transcript: string,
    userNotes: string,
  ): Promise<MeetingSummary> {
    // Dynamic import — @github/copilot-sdk is an external dependency
    const { CopilotClient } = await import("@github/copilot-sdk");

    const client = new CopilotClient();

    try {
      const session = await client.createSession({ model: this.model });

      const userPrompt = buildUserPrompt(transcript, userNotes);

      const response = await session.sendAndWait({
        prompt: `${SYSTEM_PROMPT}\n\n${userPrompt}`,
      });

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
