import Foundation
import Speech

/// Errors surfaced by the macOS transcription stack (asset manager + engine).
///
/// Kept inside `Platform/macOS` so the contract layer stays Apple-free.
public enum TranscriptionEngineError: Error, Sendable, Equatable, CustomStringConvertible {
    /// On-device speech transcription is unavailable on this machine.
    case transcriberUnavailable
    /// The current (or requested) locale has no supported speech model.
    case localeUnsupported(String)
    /// Installing the speech model assets failed.
    case assetInstallFailed(String)
    /// No analyzer-compatible audio format could be resolved for the locale.
    case noCompatibleAudioFormat

    public var description: String {
        switch self {
        case .transcriberUnavailable:
            return "On-device speech transcription is unavailable on this device."
        case .localeUnsupported(let id):
            return "Speech transcription does not support locale '\(id)'."
        case .assetInstallFailed(let message):
            return "Failed to install speech model assets: \(message)."
        case .noCompatibleAudioFormat:
            return "No analyzer-compatible audio format is available for the resolved locale."
        }
    }
}

/// Centralized, one-time speech-model preflight for a session.
///
/// ## Why this is shared (built once, before any engine)
/// Both per-source engines ("you" and "them") use the **same** shared locale and
/// the **same** on-disk model assets. The asset download is a real, potentially
/// long-blocking operation, so it must happen **exactly once** per locale and
/// must never race when two engines are constructed back-to-back. This actor:
///
/// 1. checks `SpeechTranscriber.isAvailable`;
/// 2. resolves `SpeechTranscriber.supportedLocale(equivalentTo:)`, raising a
///    clear `TranscriptionEngineError.localeUnsupported` otherwise;
/// 3. installs assets **idempotently** via
///    `AssetInventory.assetInstallationRequest(...).downloadAndInstall()` — a
///    single in-flight install is shared by all callers, and an already-resolved
///    locale short-circuits;
/// 4. hands back the resolved `Locale` for engine construction.
///
/// Progress is surfaced through an `AsyncStream<Double>` so the UI can show a
/// download bar without coupling to AVFoundation/Speech.
///
/// > Manual gate: a real `downloadAndInstall()` cannot run headlessly. The pure
/// > preflight ordering is covered by `AlembicCheck`; the live install path is
/// > validated on a machine with models present.
public actor SpeechAssetManager {
    /// Progress in `[0, 1]` for the (at most one) in-flight install. Emits `1.0`
    /// and finishes when the resolved locale is ready.
    public nonisolated let progress: AsyncStream<Double>
    private let progressContinuation: AsyncStream<Double>.Continuation

    /// The locale resolved by `preflight()`, cached so repeat calls are no-ops.
    private var resolvedLocale: Locale?
    /// The single in-flight (or completed) preflight task; ensures no duplicate
    /// or racing installs for the shared locale.
    private var preflightTask: Task<Locale, Error>?

    /// - Parameter requestedLocale: the locale to resolve a model for; defaults
    ///   to the user's current locale.
    public init(requestedLocale: Locale = Locale.current) {
        self.requestedLocale = requestedLocale
        (progress, progressContinuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    private let requestedLocale: Locale

    /// Resolves the supported locale and installs its assets, exactly once.
    ///
    /// Concurrent callers await the same underlying task; a second call after
    /// success returns the cached locale immediately. Throws
    /// `TranscriptionEngineError` on unsupported locale / unavailable transcriber
    /// / install failure.
    public func preflight() async throws -> Locale {
        if let resolvedLocale { return resolvedLocale }
        if let preflightTask { return try await preflightTask.value }

        let requested = requestedLocale
        let task = Task<Locale, Error> { [progressContinuation] in
            guard SpeechTranscriber.isAvailable else {
                throw TranscriptionEngineError.transcriberUnavailable
            }
            guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
                throw TranscriptionEngineError.localeUnsupported(requested.identifier)
            }

            progressContinuation.yield(0.0)

            // Build a transcriber purely to describe the assets we need.
            let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)

            let installed = await SpeechTranscriber.installedLocales
            let alreadyInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
            if !alreadyInstalled {
                do {
                    if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                        try await request.downloadAndInstall()
                    }
                } catch {
                    throw TranscriptionEngineError.assetInstallFailed(error.localizedDescription)
                }
            }

            progressContinuation.yield(1.0)
            progressContinuation.finish()
            return locale
        }

        preflightTask = task
        do {
            let locale = try await task.value
            resolvedLocale = locale
            return locale
        } catch {
            // Allow a later retry after a failure (don't cache the failed task).
            preflightTask = nil
            progressContinuation.finish()
            throw error
        }
    }
}
