import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit

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

// MARK: - Phase 4: gated meeting-window video-frame stream

/// The concrete capture configuration `ScreenCaptureKitSource` is constructed
/// with. `.audioOnly` (the default, and every production call site's value
/// until Phase 6) reproduces today's behavior exactly: no second `SCStream`,
/// no `.screen` output, no frame stream ever yielded to. `.audioPlusAttribution`
/// is the only value that can ever create the video stream.
public enum ScreenCaptureMode: Sendable, Equatable {
    case audioOnly
    case audioPlusAttribution
}

/// The pixel format `CapturedFrame.pixelData` is stored in. Always `.bgra8`
/// today (the video stream's `SCStreamConfiguration` contractually requests
/// `kCVPixelFormatType_32BGRA`) — stated as an enum, not a comment, so a
/// future format change is a visible, exhaustive-switch compile error in any
/// Phase 5 consumer rather than a silent assumption.
public enum CapturedFramePixelFormat: Sendable {
    case bgra8
}

/// A single captured meeting-window video frame. Holds only plain,
/// unconditionally `Sendable` value types — `Data`, `Int`, `Double`, an enum —
/// so the compiler verifies the actor-boundary crossing; no `@unchecked
/// Sendable` is used or needed anywhere on this type, and it must stay that
/// way (no stored property may ever be a `CVPixelBuffer`, `CMSampleBuffer`, or
/// any other Apple reference type).
public struct CapturedFrame: Sendable {
    /// Row-major BGRA8 pixel bytes, exactly `bytesPerRow * height` bytes — an
    /// owned copy, made once in the capture callback, never a view onto any
    /// Apple-owned buffer.
    public let pixelData: Data
    /// Pixel dimensions read from the source buffer once, at copy time.
    public let width: Int
    public let height: Int
    /// Stride in bytes between rows. May exceed `width * 4` if the source
    /// `CVPixelBuffer` padded rows — callers **must** index by `bytesPerRow`,
    /// never assume `width * 4`, to avoid reading skewed/garbage pixels.
    public let bytesPerRow: Int
    /// Currently always `.bgra8` — see `CapturedFramePixelFormat`.
    public let pixelFormat: CapturedFramePixelFormat
    /// Session-relative seconds (`SessionClock.sessionTime(forPlatformTime:)`),
    /// same basis as `AudioChunk.startTime` / `TranscriptEvent.start`/`.end` (SR-7).
    public let sessionTime: Double

    public init(pixelData: Data, width: Int, height: Int, bytesPerRow: Int, pixelFormat: CapturedFramePixelFormat, sessionTime: Double) {
        self.pixelData = pixelData
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixelFormat = pixelFormat
        self.sessionTime = sessionTime
    }
}

/// Pure, `Sendable`, `Equatable` description of the capture configuration
/// `start(target:)` will construct for a given `mode` and resolved-window
/// outcome — returned by a pure static function so `AlembicCheck` can assert
/// the semantic plan directly, rather than inferring it from source-text
/// grep. This type is a testability seam only: `start(target:)` does not
/// consume it to drive construction — it exists so the *shape* of what
/// production code does can be asserted independently of runtime
/// `SCStream`/`NSScreen` availability under CLT.
package struct ScreenCaptureConfigurationPlan: Sendable, Equatable {
    /// Which process-ID scope the audio stream's content-filter **display**
    /// selection is drawn from. Must always be `.singleMatchedApp` — the
    /// same single `SCRunningApplication` passed to
    /// `SCContentFilter(display:including:)` — never the broader PID family
    /// (`.pidFamily`) used only for meeting-window/video resolution. Using
    /// the wider family for the audio display can select a display where a
    /// *different* helper/renderer process in the family has a window while
    /// the included `app` itself has none there, producing an effectively
    /// empty filter — the exact regression this enum's single fixed value
    /// (`.singleMatchedApp`) exists to lock in.
    package enum AudioDisplayPIDScope: Sendable, Equatable {
        case singleMatchedApp
        case pidFamily
    }

    package struct AudioPlan: Sendable, Equatable {
        package let width: Int
        package let height: Int
        package let capturesAudio: Bool
        package let sampleHandlerQoS: DispatchQoS.QoSClass
        /// Always `.singleMatchedApp` — see `AudioDisplayPIDScope`.
        package let displayPIDScope: AudioDisplayPIDScope
        /// `true` iff the audio filter's `including:` list is exactly the
        /// single matched `SCRunningApplication` (`[app]`) — never the app's
        /// wider PID family and never `nil`/all-apps. Modeled as a `Bool`
        /// for the same reason `VideoPlan.usesWindowScopedFilter` is: a real
        /// `SCContentFilter` cannot be constructed without a live
        /// `SCShareableContent` app/display.
        package let filterIncludesSingleMatchedAppOnly: Bool
        package let excludesCurrentProcessAudio: Bool
        package let channelCount: Int
        package let sampleRate: Double
        package let minimumFrameIntervalFPS: Double
        package let showsCursor: Bool

        package init(
            width: Int,
            height: Int,
            capturesAudio: Bool,
            sampleHandlerQoS: DispatchQoS.QoSClass,
            displayPIDScope: AudioDisplayPIDScope,
            filterIncludesSingleMatchedAppOnly: Bool,
            excludesCurrentProcessAudio: Bool,
            channelCount: Int,
            sampleRate: Double,
            minimumFrameIntervalFPS: Double,
            showsCursor: Bool
        ) {
            self.width = width
            self.height = height
            self.capturesAudio = capturesAudio
            self.sampleHandlerQoS = sampleHandlerQoS
            self.displayPIDScope = displayPIDScope
            self.filterIncludesSingleMatchedAppOnly = filterIncludesSingleMatchedAppOnly
            self.excludesCurrentProcessAudio = excludesCurrentProcessAudio
            self.channelCount = channelCount
            self.sampleRate = sampleRate
            self.minimumFrameIntervalFPS = minimumFrameIntervalFPS
            self.showsCursor = showsCursor
        }
    }

    package struct VideoPlan: Sendable, Equatable {
        package let capturesAudio: Bool
        package let sampleHandlerQoS: DispatchQoS.QoSClass
        /// `true` iff the video stream's filter is
        /// `SCContentFilter(desktopIndependentWindow:)` — the exact-window,
        /// never-app-level filter this design requires. Modeled as a `Bool`
        /// here (rather than constructing a real `SCContentFilter`, which
        /// cannot be built without a live `SCShareableContent` window) so the
        /// plan stays constructible in a check with no window server.
        package let usesWindowScopedFilter: Bool
        package let pixelFormat: CapturedFramePixelFormat
        package let minimumFrameIntervalFPS: Double
        package let showsCursor: Bool
        /// `true` iff the video stream may only ever be created once there is
        /// positive meeting-window evidence (SR-8) — never on exclusion-list
        /// survival alone. Always `true`; modeled explicitly so a future
        /// change that quietly drops the positive-evidence gate is a visible,
        /// asserted regression here rather than only in `resolveMeetingWindowID`'s
        /// own unit checks.
        package let requiresPositiveMeetingEvidence: Bool

        package init(
            capturesAudio: Bool,
            sampleHandlerQoS: DispatchQoS.QoSClass,
            usesWindowScopedFilter: Bool,
            pixelFormat: CapturedFramePixelFormat,
            minimumFrameIntervalFPS: Double,
            showsCursor: Bool,
            requiresPositiveMeetingEvidence: Bool
        ) {
            self.capturesAudio = capturesAudio
            self.sampleHandlerQoS = sampleHandlerQoS
            self.usesWindowScopedFilter = usesWindowScopedFilter
            self.pixelFormat = pixelFormat
            self.minimumFrameIntervalFPS = minimumFrameIntervalFPS
            self.showsCursor = showsCursor
            self.requiresPositiveMeetingEvidence = requiresPositiveMeetingEvidence
        }
    }

    /// Always present, identical for every `mode` and every
    /// `meetingWindowResolved` value — every field here mirrors the literal
    /// constants/scope `start(target:)`'s audio-stream construction block
    /// uses (§0.1/HIGH-1).
    package let audio: AudioPlan
    /// `nil` unless `mode == .audioPlusAttribution && meetingWindowResolved`
    /// — the single condition that ever produces a video plan.
    package let video: VideoPlan?

    package init(audio: AudioPlan, video: VideoPlan?) {
        self.audio = audio
        self.video = video
    }

    /// Pure: given the mode and whether meeting-window resolution succeeded,
    /// returns the plan `start(target:)` will construct. Called with no live
    /// ScreenCaptureKit/AppKit state — the whole point of the seam.
    package static func plan(for mode: ScreenCaptureMode, meetingWindowResolved: Bool) -> ScreenCaptureConfigurationPlan {
        let audio = AudioPlan(
            width: 2,
            height: 2,
            capturesAudio: true,
            sampleHandlerQoS: .userInitiated,
            displayPIDScope: .singleMatchedApp,
            filterIncludesSingleMatchedAppOnly: true,
            excludesCurrentProcessAudio: true,
            channelCount: 2,
            sampleRate: 48_000,
            minimumFrameIntervalFPS: 1,
            showsCursor: false
        )
        guard mode == .audioPlusAttribution, meetingWindowResolved else {
            return ScreenCaptureConfigurationPlan(audio: audio, video: nil)
        }
        return ScreenCaptureConfigurationPlan(
            audio: audio,
            video: VideoPlan(
                capturesAudio: false,
                sampleHandlerQoS: .utility,
                usesWindowScopedFilter: true,
                pixelFormat: .bgra8,
                minimumFrameIntervalFPS: 1,
                showsCursor: false,
                requiresPositiveMeetingEvidence: true
            )
        )
    }
}

/// Namespace (no stored state) for the single production predicate that
/// decides whether a `.screen` sample buffer's attachment dictionary
/// describes a usable frame, and — if so — its session-relative timestamp.
///
/// `package` (not `private`/`internal`-only-by-file) so `AlembicCheck`, a
/// separate executable target, can call this exact function — not a
/// reimplementation of its predicate — with real `SCStreamFrameInfo` keys and
/// real (constructed, not live-captured) attachment dictionaries.
package enum FrameMetadataExtractor {
    /// Pure: given the first per-buffer attachment dictionary ScreenCaptureKit
    /// attaches to a `.screen` `CMSampleBuffer` (keyed by the real
    /// `SCStreamFrameInfo` enum), and the session clock, returns the frame's
    /// session-relative timestamp, or `nil` if the frame must be dropped
    /// (missing/unparseable keys, a non-`.complete` status, or a zero display
    /// time). Never fabricates a timestamp for a rejected frame — callers
    /// must drop the frame entirely on `nil`, with no fallback branch.
    package static func extract(
        from attachments: [SCStreamFrameInfo: Any],
        clock: SessionClock
    ) -> Double? {
        guard
            let statusRaw = attachments[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusRaw),
            status == .complete,
            let displayTimeRaw = attachments[.displayTime] as? UInt64,
            displayTimeRaw != 0
        else {
            return nil // reject: missing/unparseable attachment, non-complete status, or zero display time — never fabricate a timestamp
        }
        let platformSeconds = HostClock.seconds(fromMachHostTime: displayTimeRaw)
        return clock.sessionTime(forPlatformTime: platformSeconds)
    }
}

/// Receives `SCStream` `.screen` callbacks on the video-only sample-handler
/// queue and converts each `CMSampleBuffer` into a `Sendable` `CapturedFrame`
/// **before** yielding it, so no `CVPixelBuffer`/`CMSampleBuffer` ever crosses
/// an actor boundary. Structurally parallel to `StreamAudioOutput`; its own
/// delegate slot on the video-only `SCStream`, entirely separate from
/// `StreamAudioOutput`'s delegate slot on the audio `stream` — a video-stream
/// failure ends attribution capture only, never the audio/transcript side.
///
/// impl-review-2 HIGH-1: this type holds **no reference at all** to the
/// fatal `errors` continuation — only to `diagnostics`
/// (`attributionDiagnosticsContinuation`). This is enforced structurally, not
/// just by convention: there is no `errors`-typed stored property here for a
/// future edit to accidentally yield onto, so a video-only failure cannot
/// reach `MeetingSession`'s fatal `handleSourceError` path even by mistake.
///
/// `@unchecked Sendable` is justified exactly as `StreamAudioOutput`'s is:
/// every stored property is itself `Sendable`, and the object holds no other
/// mutable state.
final class StreamFrameOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let clock: SessionClock
    private let frames: AsyncStream<CapturedFrame>.Continuation
    private let diagnostics: AsyncStream<CaptureSourceError>.Continuation

    init(
        clock: SessionClock,
        frames: AsyncStream<CapturedFrame>.Continuation,
        diagnostics: AsyncStream<CaptureSourceError>.Continuation
    ) {
        self.clock = clock
        self.frames = frames
        self.diagnostics = diagnostics
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        // The status/displayTime validity check is the single shared
        // FrameMetadataExtractor.extract(from:clock:) predicate — not
        // duplicated here — so this callback and AlembicCheck exercise the
        // identical logic against real SCStreamFrameInfo keys.
        guard
            let attachmentsArray = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
            let attachments = attachmentsArray.first,
            let sessionTime = FrameMetadataExtractor.extract(from: attachments, clock: clock),
            let pixelBuffer = sampleBuffer.imageBuffer
        else {
            return // reject: unparseable attachments array, FrameMetadataExtractor rejected the frame, or no image buffer
        }

        // ScreenCaptureKitSource.validatedPixelCopy proves the buffer is
        // actually non-planar 32BGRA with safe, non-overflowing
        // dimensions/stride/data size before making the one owned copy — the
        // CVPixelBuffer/CMSampleBuffer never leave this callback either way.
        // Same shared-helper discipline as FrameMetadataExtractor above: the
        // callback calls the exact function AlembicCheck also calls.
        guard let copy = ScreenCaptureKitSource.validatedPixelCopy(from: pixelBuffer) else { return } // wrong format/geometry — drop, don't mislabel

        frames.yield(CapturedFrame(
            pixelData: copy.data,
            width: copy.width,
            height: copy.height,
            bytesPerRow: copy.bytesPerRow,
            pixelFormat: .bgra8,
            sessionTime: sessionTime
        ))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // impl-review-2 HIGH-1: video stream stop is non-fatal — yields only
        // onto `diagnostics` (never `errors`) and finishes only `frames`.
        // `chunks`/`buffers`/audio are structurally unreachable from this
        // type (see the type doc above), so there is nothing here that could
        // stop the session.
        diagnostics.yield(.streamStopped("video: \(error.localizedDescription)")) // reuses the existing case — no new CaptureSourceError case needed
        frames.finish()
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
///
/// ## Video path (Phase 4, gated by `mode`)
/// When constructed with `mode: .audioPlusAttribution`, `start(target:)` also
/// resolves the single exact meeting `SCWindow` (SR-8) by reusing
/// `WindowTitleProbe`'s own PID-family resolution, `MeetingAppCatalog`
/// title-hint/exclusion policy, small-overlay bounds floor, and
/// `CGWindowList` front-to-back ordering (`candidatePIDs`/
/// `resolveMeetingWindowID`), then starts a **second, fully independent**
/// `SCStream` filtered with `SCContentFilter(desktopIndependentWindow:)` —
/// never an app-level filter — on its own `.utility` queue, with its own
/// `StreamFrameOutput` delegate/output object. Frames are timestamped via
/// `FrameMetadataExtractor.extract` (attachment-based `displayTime`/`status`,
/// same `HostClock`/`SessionClock` basis as audio, SR-7) and their pixel
/// payload is copied into an owned `Data` by `validatedPixelCopy` only after
/// validating the buffer's real format/geometry (SR-4) — no `CVPixelBuffer`/
/// `CMSampleBuffer` ever crosses the actor boundary. The audio `SCStream`'s
/// construction code above never reads `mode` at all: with `mode ==
/// .audioOnly` (every call site until Phase 6), behavior is byte-identical to
/// before this phase landed (UR-4). A video-stream failure surfaces **only**
/// on `attributionDiagnostics` and finishes only `frames` — it is never
/// yielded onto `errors` (the fatal channel `MeetingSession` treats as
/// terminal), so `buffers`/audio/the session are never affected (impl-review-2
/// HIGH-1, NR-6, SR-3, SR-16). This is a real, enforced separation, not just a
/// naming convention: `StreamFrameOutput` (the video delegate/output object)
/// is never constructed with, and holds no reference to, the `errors`
/// continuation at all — it physically cannot yield onto it.
public actor ScreenCaptureKitSource: AudioSource {

    // MARK: Public streams

    public nonisolated let buffers: AsyncStream<AudioChunk>
    /// Live input meters for both sources (`.you` mic + `.them` meeting audio).
    /// Consumed by the orchestrator/UI in Phases 6/7.
    public nonisolated let meterUpdates: AsyncStream<MeterUpdate>
    /// Out-of-band **fatal** capture errors — audio/mic/base-stream failures
    /// only (e.g. the audio `SCStream`'s `didStopWithError`, the mic
    /// `AVAudioEngine` failing to start). A message on this stream is treated
    /// as terminal by `MeetingSession.handleSourceError` (flush + close the
    /// session), so nothing video/attribution-only may ever be yielded here —
    /// see `attributionDiagnostics` below for that (impl-review-2 HIGH-1).
    public nonisolated let errors: AsyncStream<CaptureSourceError>
    /// Meeting-window video frames, gated by `mode`. With `mode == .audioOnly`
    /// (the default, and every production call site's value until Phase 6),
    /// this stream is finished immediately by `start(target:)` — no frame is
    /// ever yielded. Only `mode == .audioPlusAttribution` can ever populate it.
    public nonisolated let frames: AsyncStream<CapturedFrame>
    /// Non-fatal, video/attribution-only diagnostics: no meeting window
    /// resolved, the video `SCStream` failed to start, or the video
    /// `SCStream` stopped mid-session (`StreamFrameOutput.didStopWithError`).
    /// Deliberately **separate** from `errors` (impl-review-2 HIGH-1): video
    /// is best-effort per SR-3/SR-16/NR-4/NR-6, so none of these outcomes may
    /// ever flush/close the session or stop `buffers`. A future
    /// attributor/UI (Phase 6+) may surface this stream for its own
    /// non-fatal status display; nothing consumes it yet, and finishing
    /// `frames` (already done at every yield site) is sufficient for
    /// `MeetingSession` today, which never observes this stream at all.
    public nonisolated let attributionDiagnostics: AsyncStream<CaptureSourceError>

    private let chunkContinuation: AsyncStream<AudioChunk>.Continuation
    private let meterContinuation: AsyncStream<MeterUpdate>.Continuation
    private let errorContinuation: AsyncStream<CaptureSourceError>.Continuation
    private let frameContinuation: AsyncStream<CapturedFrame>.Continuation
    private let attributionDiagnosticsContinuation: AsyncStream<CaptureSourceError>.Continuation

    // MARK: Capture state (actor-isolated)

    private var stream: SCStream?
    private var output: StreamAudioOutput?
    private var videoStream: SCStream?
    private var frameOutput: StreamFrameOutput?
    private var videoStartupTask: Task<Void, Never>?
    private var engine: AVAudioEngine?
    private var clock: SessionClock?
    private var configObserver: (any NSObjectProtocol)?
    private var didStop = false

    private final class VideoStartResume: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }

    private final class VideoStartTasks: @unchecked Sendable {
        private let lock = NSLock()
        private var storedStartTask: Task<Void, Never>?
        private var storedTimerTask: Task<Void, Never>?

        var startTask: Task<Void, Never>? {
            get { lock.withLock { storedStartTask } }
            set { lock.withLock { storedStartTask = newValue } }
        }

        var timerTask: Task<Void, Never>? {
            get { lock.withLock { storedTimerTask } }
            set { lock.withLock { storedTimerTask = newValue } }
        }
    }

    private final class VideoStreamBox: @unchecked Sendable {
        let stream: SCStream

        init(_ capturedStream: SCStream) {
            stream = capturedStream
        }
    }

    /// The capture configuration this instance was constructed with (§0.1).
    /// Immutable for the instance's lifetime — never mutated after `init`.
    private let mode: ScreenCaptureMode

    /// Positive meeting-window evidence supplied by the caller (Phase 6: the
    /// same confirmed title `MeetingDetector`/`WindowTitleProbe.meetingWindowTitle`
    /// already resolved, with `exclusionFallback: false`, before deciding a
    /// meeting exists), used to gate video window resolution (SR-8).
    ///
    /// This exists because a catalog app's static `titleHints` are not always
    /// available — Teams meeting subjects are arbitrary user/organizer text,
    /// so `MeetingApp.titleHints` is empty for Teams — so exclusion-list
    /// survival alone is not positive evidence a candidate window really is
    /// the live meeting. Set via `setExpectedMeetingTitle(_:)` before
    /// `start(target:)`; `nil` by default, which means video resolution for
    /// an app with no static `titleHints` fails closed rather than accepting
    /// any not-yet-excluded window.
    private var expectedMeetingTitle: String?

    private let micBufferSize: AVAudioFrameCount = 4096

    public init(mode: ScreenCaptureMode = .audioOnly) {
        self.mode = mode
        (buffers, chunkContinuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .bufferingNewest(512))
        (meterUpdates, meterContinuation) = AsyncStream<MeterUpdate>.makeStream(bufferingPolicy: .bufferingNewest(64))
        (errors, errorContinuation) = AsyncStream<CaptureSourceError>.makeStream(bufferingPolicy: .bufferingNewest(16))
        // Small: each CapturedFrame carries an owned, full-resolution pixel
        // copy (up to ≈23 MB at the videoStreamPixelSize clamp) — buffering
        // deep would allocate hundreds of MB for a consumer that only ever
        // wants the most recent frame at ~1–2 Hz (§0.7).
        (frames, frameContinuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        // Same small buffering rationale as `errors` — a handful of
        // video-only diagnostic messages, never a hot path.
        (attributionDiagnostics, attributionDiagnosticsContinuation) = AsyncStream<CaptureSourceError>.makeStream(bufferingPolicy: .bufferingNewest(16))
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

    /// Supplies positive meeting-window evidence (§0.1's `expectedMeetingTitle`)
    /// for video window resolution — call before `start(target:)` when the
    /// caller already has a confirmed meeting title (Phase 6). Never
    /// consulted by the audio path, and has no effect at all in `.audioOnly`
    /// mode (every production call site's mode until Phase 6).
    public func setExpectedMeetingTitle(_ title: String?) {
        expectedMeetingTitle = title
    }

    public func start(target: CaptureTarget) async throws {
        guard !didStop, stream == nil else { return }

        // NOTE (minimized-Teams / no-frames): ScreenCaptureKit only renders
        // video frames for windows that are actually on-screen. A minimized or
        // hidden meeting window may deliver no *video* frames — irrelevant for
        // audio transcription. The display used in the content filter is chosen
        // based on where the app's windows live (see below) to satisfy macOS 26's
        // requirement that the filter's display and app windows overlap.
        try await CapturePreflight.requireForCapture()

        // Single session origin shared by both pipelines.
        let clock = SessionClock(originSeconds: HostClock.now())
        self.clock = clock

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let app = content.applications.first(where: { Self.matches(target, $0) }) else {
            throw CaptureSourceError.targetNotFound(target.id)
        }
        guard !content.displays.isEmpty else {
            throw CaptureSourceError.noDisplay
        }

        // Meeting-window resolution (SR-8) — always attempted (cheap,
        // side-effect-free) regardless of `mode`, so this computation
        // genuinely cannot influence the audio-only path below: the audio
        // stream's construction never reads `meetingWindow`/`pids` at all.
        // Reuses the same PID-family resolution and catalog title-hint/
        // exclusion/bounds-floor policy `WindowTitleProbe.swift` already
        // encodes, rather than a weaker parallel implementation.
        let canonicalPrefix = MeetingAppCatalog.match(bundleID: target.id)?.canonicalBundlePrefix ?? target.id
        let matchedApp = MeetingAppCatalog.match(bundleID: target.id)?.app
        let runningProcesses = NSWorkspace.shared.runningApplications.map {
            (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "")
        }
        let pids = Self.candidatePIDs(target: target.id, canonicalBundlePrefix: canonicalPrefix, runningProcesses: runningProcesses)

        let cgWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        let frontToBack = cgWindows.compactMap { dict -> (windowID: Int, ownerPID: Int32, title: String, windowLayer: Int, width: Double, height: Double)? in
            guard
                let id = dict[kCGWindowNumber as String] as? Int,
                let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                let title = dict[kCGWindowName as String] as? String,
                let layer = dict[kCGWindowLayer as String] as? Int,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: Any],
                let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return (windowID: id, ownerPID: pid, title: title, windowLayer: layer, width: Double(rect.width), height: Double(rect.height))
        }

        let meetingWindowID = Self.resolveMeetingWindowID(
            fromFrontToBack: frontToBack,
            candidatePIDs: pids,
            titleHints: matchedApp?.titleHints ?? [],
            nonMeetingTitlePrefixes: matchedApp?.nonMeetingTitlePrefixes ?? [],
            expectedMeetingTitle: expectedMeetingTitle
        )
        let meetingWindow: SCWindow? = meetingWindowID.flatMap { id in content.windows.first { Int($0.windowID) == id } }

        // macOS 26: SCContentFilter(display:including:exceptingWindows:) requires at
        // least one window from the app on the specified display. Pick the display that
        // contains one of the app's windows so the filter is never empty — this prevents
        // an immediate "Failed to find any displays or windows to capture" stream error
        // when the app window lives on a secondary display. Falls back to the first
        // display when the app has no enumerated windows (e.g. hidden/minimised).
        // Deliberately the single matched app's PID (`app.processID`), **not**
        // the broader `pids` process family used for meeting-window resolution
        // above: the content filter below is `including: [app]` — a single
        // `SCRunningApplication` — so the display must be chosen from windows
        // that same single app actually owns. Using the wider family here can
        // select a display where only a *different* helper/renderer process in
        // the family has a window while `app` itself has none there, producing
        // an effectively empty filter (SCK's "no displays or windows to
        // capture" failure) even though `appWindows` looked non-empty. This
        // restores the pre-Phase-4 behavior exactly (HEAD) for the audio path,
        // which must stay byte-identical regardless of `mode`.
        let appPID = app.processID
        let appWindows = content.windows.filter { $0.owningApplication?.processID == appPID }
        let display: SCDisplay = appWindows.lazy
            .compactMap { w in content.displays.first { $0.frame.intersects(w.frame) } }
            .first ?? content.displays[0]

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
        // Without a frame-interval cap, SCK asks WindowServer to composite the
        // captured app at the display refresh rate for the whole meeting, purely
        // to produce frames we discard. 1 fps keeps the capture-side cost
        // negligible; audio delivery is unaffected.
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let output = StreamAudioOutput(
            clock: clock,
            chunks: chunkContinuation,
            meters: meterContinuation,
            errors: errorContinuation
        )
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        // .userInitiated is ample for 48 kHz audio chunks; .userInteractive made
        // the callbacks compete with UI event handling (ours and the meeting
        // app's) for the highest QoS band.
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: DispatchQueue.global(qos: .userInitiated))
        try await stream.startCapture()
        self.output = output
        self.stream = stream

        // Local microphone ("you") starts immediately after the app-level
        // audio stream, and unconditionally before any video-stream work
        // below — regardless of `mode`. Attribution's video stream is
        // optional/best-effort and, per macOS 26's display-overlap
        // requirement and WindowServer/TCC behavior, can be slow to create or
        // block outright; it must never sit on the critical path in front of
        // mic startup (SR-3/NR-4: enabling attribution must not delay or risk
        // the "you" audio path).
        try startMic(clock: clock)

        // Video-frame stream (Phase 4, gated): the block above never reads
        // `mode` — it is identical text regardless of the mode's value, the
        // strongest possible guarantee that the audio path cannot regress
        // when attribution is enabled. Attribution capture is best-effort and
        // additive: a failure here is caught/surfaced **only** on
        // `attributionDiagnostics` (never `errors`) and never propagates out
        // of `start(target:)` — audio/transcription must never be put at
        // risk by an OCR-only failure (impl-review-2 HIGH-1, NR-6, applied at
        // the capture layer). It also runs strictly after `startMic` above so
        // a slow or blocked video-stream startup can never delay microphone
        // capture.
        switch mode {
        case .audioOnly:
            // This phase does not support dynamic re-resolution after
            // `start(target:)` returns, so every outcome for this session is
            // decided once, up front: `.audioOnly` never attempts a video
            // stream, so `frames` is finished immediately — a consumer
            // iterating it (nothing does, until Phase 6) observes clean
            // completion rather than an indefinite hang.
            frameContinuation.finish()
        case .audioPlusAttribution:
            guard let meetingWindow else {
                // impl-review-2 HIGH-1: no-window is a silent, best-effort
                // degrade, not a fatal condition — never yields onto
                // `errorContinuation`, so `MeetingSession`/`buffers` are
                // unaffected. Only `frames` finishes; the non-fatal detail is
                // available on `attributionDiagnostics` for a future
                // non-fatal UI/diagnostic surface, if one is ever wired up.
                attributionDiagnosticsContinuation.yield(.streamStopped("video: no meeting window resolved"))
                frameContinuation.finish()
                break
            }
            let meetingWindowID = meetingWindow.windowID
            videoStartupTask = Task { [weak self] in
                await self?.startAttributionVideo(meetingWindowID: meetingWindowID, clock: clock)
            }
        }
    }

    private func startAttributionVideo(meetingWindowID: CGWindowID, clock: SessionClock) async {
        defer { videoStartupTask = nil }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let meetingWindow = content.windows.first(where: { $0.windowID == meetingWindowID }) else {
                attributionDiagnosticsContinuation.yield(.streamStopped("video: meeting window disappeared before startup"))
                frameContinuation.finish()
                return
            }
            let scale = NSScreen.screens.first { $0.frame.contains(meetingWindow.frame.origin) }?.backingScaleFactor ?? 2
            let (pixelWidth, pixelHeight) = Self.videoStreamPixelSize(windowSize: meetingWindow.frame.size, backingScale: scale)

            let videoConfig = SCStreamConfiguration()
            videoConfig.width = pixelWidth
            videoConfig.height = pixelHeight
            videoConfig.pixelFormat = kCVPixelFormatType_32BGRA
            videoConfig.capturesAudio = false
            videoConfig.showsCursor = false
            videoConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)

            let videoFilter = SCContentFilter(desktopIndependentWindow: meetingWindow)
            let frameOutput = StreamFrameOutput(
                clock: clock,
                frames: frameContinuation,
                diagnostics: attributionDiagnosticsContinuation
            )
            let videoStream = SCStream(filter: videoFilter, configuration: videoConfig, delegate: frameOutput)
            try videoStream.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .utility))

            guard try await Self.startVideoStream(VideoStreamBox(videoStream), timeout: .seconds(3)) else {
                attributionDiagnosticsContinuation.yield(.streamStopped("video: startup timed out"))
                frameContinuation.finish()
                return
            }
            guard !didStop, !Task.isCancelled else {
                try? await videoStream.stopCapture()
                return
            }
            self.frameOutput = frameOutput
            self.videoStream = videoStream
        } catch {
            attributionDiagnosticsContinuation.yield(.streamStopped("video: \(error.localizedDescription)"))
            self.videoStream = nil
            self.frameOutput = nil
            frameContinuation.finish()
        }
    }

    nonisolated private static func startVideoStream(
        _ box: VideoStreamBox,
        timeout: Duration
    ) async throws -> Bool {
        let resume = VideoStartResume()
        let tasks = VideoStartTasks()
        let result: Result<Bool, Error> = await withCheckedContinuation { continuation in
            let startTask = Task {
                do {
                    try await box.stream.startCapture()
                    if resume.tryResume() {
                        tasks.timerTask?.cancel()
                        continuation.resume(returning: .success(true))
                    } else {
                        try? await box.stream.stopCapture()
                    }
                } catch {
                    if resume.tryResume() {
                        tasks.timerTask?.cancel()
                        continuation.resume(returning: .failure(error))
                    }
                }
            }
            tasks.startTask = startTask

            let timerTask = Task {
                try? await Task.sleep(for: timeout)
                if resume.tryResume() {
                    tasks.startTask?.cancel()
                    continuation.resume(returning: .success(false))
                }
            }
            tasks.timerTask = timerTask
        }
        return try result.get()
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
        videoStartupTask?.cancel()
        videoStartupTask = nil
        if let videoStream {
            try? await videoStream.stopCapture()
            self.videoStream = nil
        }
        frameOutput = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
        output = nil

        chunkContinuation.finish()
        meterContinuation.finish()
        errorContinuation.finish()
        // Unconditional and idempotent (finishing a Continuation nothing ever
        // yielded to is a normal no-op): guarantees a Phase 5 consumer
        // iterating `frames` always observes termination when `stop()` is
        // called, in every mode and every resolution outcome — even when a
        // `start(target:)`-time path already finished it first.
        frameContinuation.finish()
        attributionDiagnosticsContinuation.finish()
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

    // MARK: - Meeting-window resolution (SR-8, pure, package-visible for AlembicCheck)

    /// Pure: given a raw `CaptureTarget.id` (`target`), a canonical
    /// bundle-ID prefix already resolved via `MeetingAppCatalog.match` (or a
    /// raw bundle ID fallback, exactly as `WindowTitleProbe.titleCandidates`
    /// resolves it today), and every currently *running* process's
    /// `(pid, bundleID)`, returns the PIDs belonging to that app's process
    /// family — covering helper/renderer processes the same way
    /// `WindowTitleProbe` already does.
    ///
    /// When `target` is itself a raw `pid:<n>` reference (the existing
    /// fallback `CaptureTarget` id used when `SCRunningApplication
    /// .bundleIdentifier` is empty), that PID is used directly — mirroring
    /// `WindowTitleProbe.titleCandidates`'s own `pid:` branch exactly — rather
    /// than falling through to bundle-prefix matching, which can never
    /// succeed for a `pid:`-only target (no running process's bundle ID is
    /// ever literally `"pid:<n>"`).
    ///
    /// `package` so `AlembicCheck` can assert hub-process/chat-helper/
    /// compact-overlay/renderer-PID membership, and the `pid:` fast path,
    /// directly.
    package static func candidatePIDs(
        target: String,
        canonicalBundlePrefix: String,
        runningProcesses: [(pid: Int32, bundleID: String)]
    ) -> Set<Int32> {
        if target.hasPrefix("pid:"), let pid = Int32(target.dropFirst(4)) {
            return [pid]
        }
        let prefix = canonicalBundlePrefix.lowercased()
        return Set(runningProcesses.compactMap { process in
            let id = process.bundleID.lowercased()
            return (id == prefix || id.hasPrefix(prefix + ".")) ? process.pid : nil
        })
    }

    /// Pure: given every on-screen window across the resolved PID family, in
    /// **front-to-back z-order** (the caller's contract — sourced from
    /// `CGWindowListCopyWindowInfo`, never from `SCShareableContent.windows`),
    /// as plain data (windowID, ownerPID, title, windowLayer, width, height),
    /// the PID family to restrict to, and the matched app's catalog
    /// `titleHints`/`nonMeetingTitlePrefixes`, returns the `windowID` of the
    /// single window that is "the meeting window," or `nil` if none qualifies.
    ///
    /// Filtering, in order: (1) `ownerPID` must be in `candidatePIDs`; (2)
    /// `windowLayer == 0` — excludes menu extras/always-on-top HUDs/
    /// screen-share-indicator overlays (SR-8); (3) non-empty title; (4)
    /// `width >= minContentWidth && height >= minContentHeight` — the same
    /// small-overlay floor `WindowTitleProbe` already applies, excluding tiny
    /// Electron helper windows that pass every other filter. Ranking then
    /// delegates to `MeetingContext.bestTitle(..., preferFrontmost: true,
    /// exclusionFallback: false)` — the same catalog-aware, strict
    /// (no-fallback) call `WindowTitleProbe.meetingWindowTitle(for:)` already
    /// makes: a hub/chat/calendar/compact-view-only screen (every candidate
    /// excluded) resolves to `nil` rather than silently falling back to a hub
    /// title.
    ///
    /// Because `windows` is already caller-supplied front-to-back order, the
    /// **first** window (in that order) whose title equals `bestTitle`'s pick
    /// is the frontmost qualifying match — **but is only returned when there
    /// is positive meeting-window evidence** (`hasPositiveMeetingEvidence`
    /// below): exclusion-list survival alone is not sufficient, because
    /// `nonMeetingTitlePrefixes` is a finite, hand-maintained list — a
    /// not-yet-catalogued hub/settings/help-style window (or any future Teams
    /// UI surface) would otherwise be silently accepted as "the meeting."
    /// Positive evidence is either (a) the resolved title actually contains
    /// one of the app's static `titleHints` (e.g. Zoom's "Zoom Meeting"), or
    /// (b) it matches the caller-supplied `expectedMeetingTitle` — the same
    /// confirmed meeting title `WindowTitleProbe.meetingWindowTitle`/the
    /// detection pipeline already resolved before deciding a meeting exists.
    /// Neither present ⇒ fail closed (`nil`), never "arbitrary unexcluded
    /// window."
    ///
    /// `package` so `AlembicCheck` can call it directly.
    package static func resolveMeetingWindowID(
        fromFrontToBack windows: [(windowID: Int, ownerPID: Int32, title: String, windowLayer: Int, width: Double, height: Double)],
        candidatePIDs: Set<Int32>,
        titleHints: [String],
        nonMeetingTitlePrefixes: [String],
        minContentWidth: Double = 200,
        minContentHeight: Double = 120,
        expectedMeetingTitle: String? = nil
    ) -> Int? {
        let candidates = windows.filter {
            candidatePIDs.contains($0.ownerPID) &&
            $0.windowLayer == 0 &&
            !$0.title.isEmpty &&
            $0.width >= minContentWidth &&
            $0.height >= minContentHeight
        }
        guard !candidates.isEmpty else { return nil }
        guard let title = MeetingContext.bestTitle(
            from: candidates.map(\.title),
            appHints: titleHints,
            exclusions: nonMeetingTitlePrefixes,
            preferFrontmost: true,
            exclusionFallback: false
        ) else { return nil }
        guard Self.hasPositiveMeetingEvidence(
            title: title,
            titleHints: titleHints,
            expectedMeetingTitle: expectedMeetingTitle
        ) else { return nil } // fail closed: not-excluded is not the same as confirmed-meeting
        return candidates.first { $0.title == title }?.windowID
    }

    /// Pure: `true` iff `title` carries **positive** evidence of being a live
    /// meeting window, rather than merely having survived
    /// `nonMeetingTitlePrefixes` exclusion. Two independent sources of
    /// evidence, either sufficient on its own:
    ///
    /// 1. `titleHints` is non-empty and `title` contains one of them (e.g.
    ///    Zoom's `"Zoom Meeting"`, Google Meet's `"Meet –"`) — a static,
    ///    catalog-declared positive marker.
    /// 2. `expectedMeetingTitle` is non-empty and `title` starts with it —
    ///    the caller-supplied, already-confirmed meeting title (Phase 6:
    ///    the same title `WindowTitleProbe.meetingWindowTitle` resolved via
    ///    the strict, no-fallback path before a meeting was ever detected).
    ///    `hasPrefix` (not `==`) because `title` may still carry an
    ///    untrimmed app-name suffix (e.g. `" | Microsoft Teams"`) that
    ///    `expectedMeetingTitle` has already had stripped.
    ///
    /// When neither source is available (e.g. Teams, whose meeting subjects
    /// are arbitrary and whose catalog entry has no static `titleHints`, and
    /// no `expectedMeetingTitle` was supplied), returns `false` — the caller
    /// must fail closed rather than accept the title on exclusion-list
    /// survival alone.
    ///
    /// `package` so `AlembicCheck` can exercise it directly.
    package static func hasPositiveMeetingEvidence(
        title: String,
        titleHints: [String],
        expectedMeetingTitle: String?
    ) -> Bool {
        if !titleHints.isEmpty, titleHints.contains(where: { title.contains($0) }) {
            return true
        }
        if let expectedMeetingTitle, !expectedMeetingTitle.isEmpty, title.hasPrefix(expectedMeetingTitle) {
            return true
        }
        return false
    }

    /// Pure: given a window's on-screen point-space size and the screen's
    /// backing scale, returns the pixel dimensions to request from
    /// `SCStreamConfiguration`, clamped so the longer side never exceeds
    /// `maxDimension`. Never returns less than `2×2` (matches the audio
    /// stream's floor and ScreenCaptureKit's own minimum plane size).
    /// `package` so `AlembicCheck` can call it directly.
    package static func videoStreamPixelSize(
        windowSize: CGSize,
        backingScale: CGFloat,
        maxDimension: Double = 2400
    ) -> (width: Int, height: Int) {
        let rawWidth = Double(windowSize.width) * Double(backingScale)
        let rawHeight = Double(windowSize.height) * Double(backingScale)
        let clampScale = Swift.min(1.0, maxDimension / Swift.max(rawWidth, rawHeight, 1))
        return (
            width: Swift.max(2, Int((rawWidth * clampScale).rounded())),
            height: Swift.max(2, Int((rawHeight * clampScale).rounded()))
        )
    }

    // MARK: - Video frame buffer validation (pure geometry, package-visible for AlembicCheck)

    /// Pure: validates that a pixel buffer's reported format and geometry are
    /// safe to copy from — non-planar `32BGRA`, positive non-degenerate
    /// dimensions, a stride wide enough for one BGRA row, and a byte count
    /// that does not overflow `Int` — before any `CVPixelBuffer` is touched.
    ///
    /// Extracted out of `validatedPixelCopy(from:)` as its own arithmetic/
    /// geometry predicate so `AlembicCheck` can exercise the under-stride and
    /// integer-overflow guard branches directly against fabricated
    /// `width`/`bytesPerRow`/`height` values — `CVPixelBufferCreate` will not
    /// itself produce an under-strided or `Int`-max-adjacent buffer, so those
    /// branches are otherwise unreachable from a real `CVPixelBuffer`.
    ///
    /// Returns the exact byte count to copy (`bytesPerRow * height`) when
    /// every invariant holds, or `nil` if any check fails.
    package static func validatedPixelGeometry(
        pixelFormatType: OSType,
        isPlanar: Bool,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        dataSize: Int
    ) -> Int? {
        guard pixelFormatType == kCVPixelFormatType_32BGRA, !isPlanar else {
            return nil // wrong/unexpected format, or a planar buffer — drop, don't mislabel
        }
        guard width > 0, height > 0, bytesPerRow > 0 else {
            return nil // non-positive/degenerate geometry
        }
        // `width * 4` itself must be checked for overflow before comparing it
        // to `bytesPerRow` — for a fabricated/adversarial `width` near
        // `Int.max / 4`, an unchecked `width * 4` can overflow/trap before
        // this predicate ever gets to reject the buffer, defeating the
        // trust-boundary contract this function exists to enforce.
        let (minRowBytes, rowOverflowed) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflowed, bytesPerRow >= minRowBytes else {
            return nil // stride computation overflowed, or stride too small to hold one BGRA row
        }
        let (byteCount, overflowed) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !overflowed else { return nil } // reject rather than compute a wrapped/undersized allocation size
        // `CVPixelBufferGetDataSize` returns 0 for some non-IOSurface-backed buffers
        // where the value is not meaningful — only enforced as a lower bound when
        // CoreVideo reports a nonzero size, so a genuinely valid buffer is never
        // rejected on a spurious 0.
        guard dataSize == 0 || dataSize >= byteCount else { return nil }
        return byteCount
    }

    /// Validates that `pixelBuffer` is actually non-planar `32BGRA` with safe,
    /// non-degenerate geometry (via `validatedPixelGeometry`), then returns an
    /// owned copy of its bytes plus the geometry the copy was made against —
    /// or `nil` if any invariant fails, in which case the caller must drop
    /// the frame (no fallback). Locks/unlocks the buffer internally so
    /// callers never need to manage the lock themselves, and checks the
    /// `CVPixelBufferLockBaseAddress` return code rather than assuming the
    /// lock succeeded.
    ///
    /// `package` so `AlembicCheck` can call this exact function against
    /// `CVPixelBufferCreate`-constructed test buffers (valid BGRA, planar
    /// YUV, wrong packed format, zero/degenerate dimensions) — not a
    /// reimplementation of its predicate.
    package static func validatedPixelCopy(from pixelBuffer: CVPixelBuffer) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil // could not lock the buffer — do not read format/geometry/base-address state
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil } // no addressable base — drop, don't mislabel

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)

        guard let byteCount = Self.validatedPixelGeometry(
            pixelFormatType: CVPixelBufferGetPixelFormatType(pixelBuffer),
            isPlanar: CVPixelBufferIsPlanar(pixelBuffer),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            dataSize: CVPixelBufferGetDataSize(pixelBuffer)
        ) else { return nil }

        return (data: Data(bytes: base, count: byteCount), width: width, height: height, bytesPerRow: bytesPerRow)
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
