export const SYSTEM_PROMPT = `You are a meeting notes assistant. Given a meeting transcript and the user's own notes taken during the meeting, produce a structured summary.

The user's notes reflect what THEY found important — prioritize those topics in your summary.

Respond with valid JSON matching this exact structure:
{
  "title": "A concise meeting title",
  "summary": "A 2-4 paragraph summary of the meeting covering the main topics discussed",
  "keyDecisions": ["Decision 1", "Decision 2"],
  "actionItems": [
    {"assignee": "Person Name", "task": "What they need to do", "due": "optional date"}
  ],
  "keyTopics": ["Topic 1", "Topic 2"],
  "attendees": ["Person 1", "Person 2"]
}

Guidelines:
- Extract attendee names from the transcript when possible
- Action items should have clear owners when identifiable
- Key decisions should be definitive statements, not discussion points
- Topics should be concise labels, not full sentences
- If the user's notes mention something, it's important — make sure it appears in the summary
- Return ONLY valid JSON, no markdown code fences or other text`;

export function buildUserPrompt(
  transcript: string,
  userNotes: string,
  knownNames?: string[],
): string {
  let prompt = "";

  if (knownNames && knownNames.length > 0) {
    // Extract human names (skip technical terms) for attendee correction
    const personNames = knownNames.filter((n) => n.includes(","));
    if (personNames.length > 0) {
      const displayNames = personNames.map((n) => {
        const parts = n.split(/,\s*/);
        return parts.length === 2 ? `${parts[1]} ${parts[0]}` : n;
      });
      prompt +=
        `## Known People (use these exact spellings)\n\n` +
        `The following people may appear in the transcript. The transcript was generated ` +
        `by speech recognition and may contain misspelled or phonetically similar versions ` +
        `of these names. When you encounter a name that sounds similar to one of these, ` +
        `use the correct spelling:\n\n` +
        displayNames.map((n) => `- ${n}`).join("\n") +
        "\n\n";
    }
  }

  if (userNotes.trim()) {
    prompt += `## My Notes (prioritize these topics)\n\n${userNotes}\n\n`;
  }

  prompt += `## Meeting Transcript\n\n${transcript}`;

  return prompt;
}
