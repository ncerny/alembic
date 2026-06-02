import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

// MARK: - SCStream output sink (runs on the capture queue, not the actor)

/// Receives `SCStream` audio callbacks on the sample-handler queue and converts
/// each `CMSampleBuffer` into a `Sendable` `AudioChunk` **before** yielding it,
/// so no Apple buffer ever crosses an actor boundary. It also never `await`s the
/// orchestrator from the callback — it only `yield`s on `Sendable` continuations.
///
/// `@unchecked Sendable` is justified: every stored property is itself `Sendable`
/// (`SessionClock` is a value type; `AsyncStream.Continuation` is `Sendable`) and
/// the object holds **no mutable state**, so concurrent callbacks are safe.
final class StreamAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let clock: SessionClock
    private let chunks: AsyncStream<AudioChunk>.Continuation
    private let meters: AsyncStream<MeterUpdate>.Continuation
    private let errors: AsyncStream<CaptureSourceError>.Continuation

    init(
        clock: SessionClock,
        chunks: AsyncStream<AudioChunk>.Continuation,
        meters: AsyncStream<MeterUpdate>.Continuation,
        errors: AsyncStream<CaptureSourceError>.Continuation
    ) {
        self.clock = clock
        self.chunks = chunks
        self.meters = meters
        self.errors = errors
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard let block = AudioBufferConversion.decode(sampleBuffer: sampleBuffer) else { return }

        // ScreenCaptureKit presentation timestamps are on the host time clock, so
        // they share a basis with the mic's `AVAudioTime.hostTime` and with the
        // session origin captured via `HostClock.now()`. Fall back to "now" only
        // if a buffer arrives without a valid PTS.
        let platformSeconds = block.presentationSeconds ?? HostClock.now()
        let chunk = AudioChunk(
            samples: block.monoSamples,
            sampleRate: block.sampleRate,
            channelCount: block.originalChannelCount,
            source: .them,
            startTime: clock.sessionTime(forPlatformTime: platformSeconds)
        )
        chunks.yield(chunk)
        meters.yield(MeterUpdate(source: .them, level: .measuring(block.monoSamples)))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        errors.yield(.streamStopped(error.localizedDescription))
        // A fatal stream stop ends the "them" side; finish the multiplexed stream
        // so consumers unblock. The orchestrator (Phase 6) decides recovery policy.
        chunks.finish()
    }
}

// MARK: - macOS AudioSource

/// macOS `AudioSource` built on ScreenCaptureKit (meeting/"them" audio) plus
/// `AVAudioEngine` (microphone/"you" audio), multiplexed onto one tagged
/// `buffers` stream with session-relative timestamps.
///
/// ## Concurrency model (Swift 6 strict)
/// - Lifecycle/mutable state (`SCStream`, `AVAudioEngine`, stop flag) lives on
///   this `actor`.
/// - The hot audio paths run **off** the actor: the `SCStream` callback lands on
///   `StreamAudioOutput`, and the mic tap closure captures only `Sendable`
///   values. Both convert their non-`Sendable` Apple buffer to an `AudioChunk`
///   immediately and `yield` it — never `await`ing the actor or the analyzer.
///
/// ## Timestamps
/// One `SessionClock` is created at `start` with origin = `HostClock.now()`.
/// `SCStream` PTS seconds and the mic's `AVAudioTime.hostTime` both reduce to the
/// same host-time seconds basis, so subtracting the single origin yields one
/// shared session timeline for both sides.
public actor ScreenCaptureKitSource: AudioSource {

    // MARK: Public streams

    public nonisolated let buffers: AsyncStream<AudioChunk>
    /// Live input meters for both sources (`.you` mic + `.them` meeting audio).
    /// Consumed by the orchestrator/UI in Phases 6/7.
    public nonisolated let meterUpdates: AsyncStream<MeterUpdate>
    /// Out-of-band fatal capture errors (e.g. `SCStream` `didStopWithError`).
    public nonisolated let errors: AsyncStream<CaptureSourceError>

    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let meterContinuation: AsyncStream<MeterUpdate>.Continuation
    private let errorContinuation: AsyncStream<CaptureSourceError>.Continuation

    // MARK: Capture state (actor-isolated)

    private var stream: SCStream?
    private var output: StreamAudioOutput?
    private var engine: AVAudioEngine?
    private var clock: SessionClock?
    private var configObserver: (any NSObjectProtocol)?
    private var didStop = false

    private let micBufferSize: AVAudioFrameCount = 4096

    public init() {
        (buffers, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (meterUpdates, meterContinuation) = AsyncStream<MeterUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (errors, errorContinuation) = AsyncStream<CaptureSourceError>.makeStream(bufferingPolicy: .bufferingNewest(16))
    }

    // MARK: - AudioSource

    public func availableTargets() async throws -> [CaptureTarget] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        // The raw application list contains hundreds of windowless background
        // agents/daemons that can never be a meeting's audio source. Restrict the
        // picker to apps that actually own a window (visible or minimized) — i.e.
        // the GUI apps a meeting could be running in. The user can still re-run
        // "Refresh Targets" if an app appears late.
        let windowedAppPIDs = Set(content.windows.compactMap { $0.owningApplication?.processID })
        return content.applications
            .filter { !$0.applicationName.isEmpty && windowedAppPIDs.contains($0.processID) }
            .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }
            .map(Self.target(for:))
    }

    public func start(target: CaptureTarget) async throws {
        guard !didStop, stream == nil else { return }

        // NOTE (minimized-Teams / no-frames): ScreenCaptureKit only renders
        // frames for windows that are actually on-screen. A minimized or hidden
        // meeting window may deliver no *video* frames. This only matters for a
        // future video path — per-app **audio** is still captured regardless of
        // window visibility, so transcription is unaffected here. Surfaced to the
        // user as a UI hint in the permissions/onboarding flow.
        try await CapturePreflight.requireForCapture()

        // Single session origin shared by both pipelines.
        let clock = SessionClock(originSeconds: HostClock.now())
        self.clock = clock

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { Self.matches(target, $0) }) else {
            throw CaptureSourceError.targetNotFound(target.id)
        }
        guard let display = content.displays.first else {
            throw CaptureSourceError.noDisplay
        }

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.channelCount = 2
        config.sampleRate = 48_000
        // Audio-only: minimize the video plane. NOTE: a *minimized* Teams window
        // may not render video frames at all — irrelevant for audio capture here,
        // but it will matter if a future phase adds video/OCR speaker attribution.
        config.width = 2
        config.height = 2

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let output = StreamAudioOutput(
            clock: clock,
            chunks: chunkContinuation,
            meters: meterContinuation,
            errors: errorContinuation
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInteractive))
        try await stream.startCapture()
        self.output = output
        self.stream = stream

        try startMic(clock: clock)
    }

    public func stop() async {
        guard !didStop else { return }
        didStop = true

        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        output = nil

        chunkContinuation.finish()
        meterContinuation.finish()
        errorContinuation.finish()
    }

    // MARK: - Microphone ("you")

    private func startMic(clock: SessionClock) throws {
        let engine = AVAudioEngine()
        installMicTap(on: engine, clock: clock)
        do {
            try engine.start()
        } catch {
            throw CaptureSourceError.engineStartFailed(error.localizedDescription)
        }
        self.engine = engine
        observeConfigurationChanges(for: engine, clock: clock)
    }

    /// Installs the mic tap. The tap closure captures only `Sendable` values
    /// (continuations + the value-type clock) and converts each buffer to an
    /// `AudioChunk` inline — it never touches actor state or `await`s.
    private func installMicTap(on engine: AVAudioEngine, clock: SessionClock) {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let chunks = chunkContinuation
        let meters = meterContinuation
        input.installTap(onBus: 0, bufferSize: micBufferSize, format: format) { buffer, when in
            guard let block = AudioBufferConversion.decode(pcmBuffer: buffer) else { return }
            let platformSeconds = when.isHostTimeValid
                ? HostClock.seconds(fromMachHostTime: when.hostTime)
                : HostClock.now()
            let chunk = AudioChunk(
                samples: block.monoSamples,
                sampleRate: block.sampleRate,
                channelCount: block.originalChannelCount,
                source: .you,
                startTime: clock.sessionTime(forPlatformTime: platformSeconds)
            )
            chunks.yield(chunk)
            meters.yield(MeterUpdate(source: .you, level: .measuring(block.monoSamples)))
        }
    }

    // MARK: - Robustness: audio device / route changes mid-session

    /// Observes `AVAudioEngineConfigurationChange` (fired when the default input
    /// device or its format changes — e.g. plugging in headphones mid-call) and
    /// re-installs the tap against the new format so capture survives the change.
    private func observeConfigurationChanges(for engine: AVAudioEngine, clock: SessionClock) {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleConfigurationChange(clock: clock) }
        }
    }

    private func handleConfigurationChange(clock: SessionClock) {
        guard !didStop, let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        installMicTap(on: engine, clock: clock)
        if !engine.isRunning {
            try? engine.start()
        }
    }

    // MARK: - Target mapping & defensive Teams matching

    /// Maps an `SCRunningApplication` onto the platform-neutral `CaptureTarget`.
    /// Uses bundle id as the stable id, falling back to `pid:<n>` when absent.
    static func target(for app: SCRunningApplication) -> CaptureTarget {
        let id = app.bundleIdentifier.isEmpty ? "pid:\(app.processID)" : app.bundleIdentifier
        return CaptureTarget(id: id, displayName: app.applicationName)
    }

    /// Matches a previously-enumerated `CaptureTarget` back to a live app, by
    /// bundle id first, then by the `pid:` fallback id.
    static func matches(_ target: CaptureTarget, _ app: SCRunningApplication) -> Bool {
        if !app.bundleIdentifier.isEmpty, app.bundleIdentifier == target.id { return true }
        return target.id == "pid:\(app.processID)"
    }

    /// Bundle-id hints for Teams across its variants. Teams may run as several
    /// processes (new Teams, classic, helper/renderer), and browser-based Teams
    /// shows up under the browser's bundle id — so the picker always lists *all*
    /// apps; this is only a convenience for surfacing likely candidates.
    ///
    /// Delegates to `MeetingAppCatalog` as the single source of truth.
    public static var teamsBundleIDHints: [String] { MeetingAppCatalog.teamsBundleIDHints }

    /// Heuristic "is this probably Teams?" used to highlight likely targets in a
    /// picker. Deliberately permissive (covers classic/new/browser tab titles).
    public static func isLikelyTeams(_ target: CaptureTarget) -> Bool {
        let id = target.id.lowercased()
        if teamsBundleIDHints.contains(where: { id == $0.lowercased() }) { return true }
        if id.contains("teams") { return true }
        return target.displayName.localizedCaseInsensitiveContains("teams")
    }

    /// Convenience filter over `availableTargets()` results for likely Teams
    /// processes. The user can still pick any target from the full list.
    public func availableTeamsTargets() async throws -> [CaptureTarget] {
        try await availableTargets().filter(Self.isLikelyTeams)
    }
}
