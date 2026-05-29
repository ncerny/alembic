import Foundation

/// Identifies which side of a conversation a piece of audio or transcript came
/// from in a dual-engine ("you vs them") session.
///
/// - `you`:  the local microphone (the person running Alembic).
/// - `them`: the remote/Teams audio captured from the meeting app.
///
/// `String`-backed and `Codable` so the Phase 5 JSONL writer can serialize it
/// directly as a stable, human-readable token. `Sendable` so tags can flow
/// freely across actor boundaries with audio chunks and transcript events.
///
/// - Note: This is a deliberately platform-neutral contract type. It carries no
///   Apple framework types and must never gain any, so a future Windows source
///   (WASAPI loopback + mic) can reuse the exact same labeling.
public enum SourceTag: String, Sendable, Codable, Hashable, CaseIterable {
    /// The local microphone — the user of Alembic.
    case you

    /// The remote/meeting audio — everyone else on the call.
    case them
}
