import type { MeetingSummary } from "./types";

export interface LLMProvider {
  summarize(
    transcript: string,
    userNotes: string,
    knownNames?: string[],
  ): Promise<MeetingSummary>;
}

export class Summarizer {
  private provider: LLMProvider;

  constructor(provider: LLMProvider) {
    this.provider = provider;
  }

  async summarize(
    transcript: string,
    userNotes: string,
    knownNames?: string[],
  ): Promise<MeetingSummary> {
    return this.provider.summarize(transcript, userNotes, knownNames);
  }
}
