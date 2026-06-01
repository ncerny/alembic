import type { TranscriptSegment } from "./types";

function formatTimestamp(seconds: number): string {
  const minutes = Math.floor(seconds / 60);
  const remainingSeconds = Math.floor(seconds % 60);
  return `${String(minutes).padStart(2, "0")}:${String(remainingSeconds).padStart(2, "0")}`;
}

export function formatTranscriptLines(transcript: TranscriptSegment[]): string[] {
  const hasTiming = transcript.some((seg) => seg.start > 0 || seg.end > 0);

  return transcript.map((seg) =>
    hasTiming ? `[${formatTimestamp(seg.start)}] ${seg.text}` : seg.text,
  );
}
