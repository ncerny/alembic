import SwiftUI
import AlembicKit

/// Pure presentation helpers for the SwiftUI layer.
///
/// Kept free of business logic and side effects: every function maps model
/// values to display values. The `hh:mm:ss` formatting deliberately reuses
/// `TranscriptWriter.timestamp(from:)` so the live UI and the on-disk readable
/// render are byte-for-byte consistent.
enum Presentation {
    /// `[hh:mm:ss] source: text` — the same shape the readable `.md` render uses.
    static func line(for event: TranscriptEvent) -> String {
        "[\(TranscriptWriter.timestamp(from: event.start))] \(event.source.rawValue): \(event.text)"
    }

    /// Maps a meter RMS (~`[0, 1]`, usually small) to a `[0, 1]` bar fraction.
    /// A square-root curve lifts quiet speech into a visible range.
    static func meterFraction(rms: Float) -> Double {
        let clamped = Double(max(0, min(1, rms)))
        return min(1, clamped.squareRoot())
    }

    /// Display color per conversation side.
    static func color(for source: SourceTag) -> Color {
        switch source {
        case .you: return .blue
        case .them: return .green
        }
    }

    /// Speaker label per conversation side.
    static func label(for source: SourceTag) -> String {
        switch source {
        case .you: return "You"
        case .them: return "Them"
        }
    }
}

/// The live transcript window: finalized history (auto-scrolling), the current
/// volatile line per source, input meters, elapsed time, and session state.
///
/// Presentation only — it observes the `@Observable` ``MeetingSession`` through
/// ``AppModel`` and renders; all capture/transcription logic lives in the
/// orchestrator.
struct LiveTranscriptView: View {
    @Bindable var model: AppModel

    private var session: MeetingSession { model.session }

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.isPreparingModels {
                modelPreparationBar
            }
            Divider()
            transcript
            Divider()
            meters
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    // MARK: Model-asset download progress

    /// A determinate "Preparing speech model…" bar shown during the one-time
    /// asset download/preflight before the first Start. Determinate when
    /// `SpeechAssetManager` reports a fraction; indeterminate otherwise.
    @ViewBuilder
    private var modelPreparationBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let progress = model.modelDownloadProgress, progress < 1 {
                ProgressView("Preparing speech model…", value: progress, total: 1)
            } else {
                ProgressView("Preparing speech model…")
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: model.menuBarSymbol)
                .foregroundStyle(model.canStop ? .red : .secondary)
            Text(model.statusText)
                .font(.headline)
            Spacer()
            Text(model.elapsedString)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: Transcript history + volatile lines

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(session.finalizedTranscript) { event in
                        finalizedRow(event)
                            .id(event.id)
                    }

                    ForEach(volatileEventsInOrder, id: \.id) { event in
                        volatileRow(event)
                    }

                    // Anchor used to keep the newest content pinned to the bottom.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
            }
            .onChange(of: session.finalizedTranscript.count) {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
                }
            }
            .onChange(of: volatileSignature) {
                proxy.scrollTo(Self.bottomAnchor, anchor: .bottom)
            }
        }
    }

    private func finalizedRow(_ event: TranscriptEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TranscriptWriter.timestamp(from: event.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(Presentation.label(for: event.source))
                .font(.caption.bold())
                .foregroundStyle(Presentation.color(for: event.source))
            Text(event.text)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }

    private func volatileRow(_ event: TranscriptEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TranscriptWriter.timestamp(from: event.start))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary)
            Text(Presentation.label(for: event.source))
                .font(.caption.bold())
                .foregroundStyle(Presentation.color(for: event.source).opacity(0.6))
            Text(event.text)
                .italic()
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    /// Volatile lines rendered in a stable order (you before them).
    private var volatileEventsInOrder: [TranscriptEvent] {
        SourceTag.allCases.compactMap { session.volatileLines[$0] }
    }

    /// A cheap value that changes whenever any volatile line updates, used to
    /// trigger auto-scroll without observing the dictionary identity directly.
    private var volatileSignature: String {
        volatileEventsInOrder.map { "\($0.source.rawValue):\($0.text.count)" }.joined(separator: "|")
    }

    // MARK: Input meters

    private var meters: some View {
        HStack(spacing: 18) {
            ForEach(SourceTag.allCases, id: \.self) { source in
                MeterBar(
                    label: Presentation.label(for: source),
                    color: Presentation.color(for: source),
                    fraction: Presentation.meterFraction(rms: session.meterLevels[source]?.rms ?? 0)
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private static let bottomAnchor = "transcript-bottom-anchor"
}

/// A simple horizontal input-level bar for one source.
private struct MeterBar: View {
    let label: String
    let color: Color
    let fraction: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color)
                        .frame(width: max(0, min(1, fraction)) * geo.size.width)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
    }
}
