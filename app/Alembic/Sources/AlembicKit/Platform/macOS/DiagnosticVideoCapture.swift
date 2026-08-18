import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreGraphics
import AppKit

/// A narrow, **video-only** capture seam for `AlembicCheck`'s `frame-dump`
/// diagnostic (SR-22, Phase 7 §1).
///
/// Unlike `ScreenCaptureKitSource.start(target:)`, this type:
/// - Never calls `CapturePreflight.requireForCapture()` — it checks **only**
///   `CapturePreflight.screenRecordingStatus()` (`CGPreflightScreenCaptureAccess()`
///   under the hood), so it never requests or depends on Microphone or Speech
///   Recognition access.
/// - Never starts `AVAudioEngine`, the local microphone, or `SpeechAnalyzer` —
///   there is no audio state anywhere on this type.
/// - Starts exactly one window-scoped `.screen` `SCStream`, mirroring
///   `ScreenCaptureKitSource`'s existing `.audioPlusAttribution` video-stream
///   construction (`SCContentFilter(desktopIndependentWindow:)`,
///   `StreamFrameOutput`, `FrameMetadataExtractor`, `validatedPixelCopy`) —
///   the same trusted pixel-copy path, not a second, parallel implementation.
///
/// **Target resolution** mirrors `ScreenCaptureKitSource.resolveMeetingWindowID`/
/// `hasPositiveMeetingEvidence`'s fail-closed contract: a bare bundle-prefix
/// alone cannot resolve a window (Teams has no static `titleHints`) — the
/// caller must supply either `expectedMeetingTitle` or an exact `windowID`
/// (`FrameDumpProbe.validate(...)` enforces this before this type is ever
/// touched).
///
/// **Stop/error behavior:** the stream is torn down (a) when `stop()` is
/// called, (b) when the consuming `Task` iterating the returned
/// `AsyncStream<CapturedFrame>` is cancelled, or (c) on any capture error —
/// always releasing the underlying `SCStream` before returning, exactly like
/// `ScreenCaptureKitSource.stop()`.
///
/// **Visibility (Phase 7 impl-review-1 MEDIUM-2):** this is a diagnostic,
/// raw-frame capture seam for `AlembicCheck`'s `frame-dump` tool only — it is
/// package-visible, not `public`, so no module outside this Swift package
/// (in particular, no consumer of `AlembicKit` as a library dependency) can
/// see or call a raw meeting-window screenshot/OCR-enabling primitive.
/// `AlembicCheck` can still see it because it is a target in the same
/// package (`Package.swift`).
package actor DiagnosticVideoCapture {

    package enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case screenRecordingNotAuthorized
        case noRunningApp(bundlePrefix: String)
        case noDisplay
        case noWindowResolved
        case windowIDNotOwnedByMatchedApp(UInt32)

        package var description: String {
            switch self {
            case .screenRecordingNotAuthorized:
                return "Screen Recording is not authorized — grant access in System Settings → Privacy & Security → Screen Recording, then re-run."
            case .noRunningApp(let prefix):
                return "no running app matches bundle prefix \"\(prefix)\""
            case .noDisplay:
                return "no display available to capture"
            case .noWindowResolved:
                return "no meeting window resolved — pass --meeting-title or --window-id (see --list-windows)"
            case .windowIDNotOwnedByMatchedApp(let id):
                return "--window-id \(id) does not belong to a window owned by the matched app"
            }
        }
    }

    /// Failure modes specific to the bounded `captureFrames(...)` seam
    /// (Phase 7 impl-review-1 MEDIUM-1): a live capture that starts
    /// successfully but never (or no longer) yields frames must fail closed
    /// rather than hang the diagnostic indefinitely.
    package enum CaptureError: Error, Equatable, CustomStringConvertible {
        /// No frame arrived within `firstFrameTimeout` of `captureFrames`
        /// starting the stream — e.g. a hidden/minimized meeting window or a
        /// WindowServer condition that never produces a `.screen` sample.
        case timedOutWaitingForFirstFrame
        /// A subsequent frame did not arrive within `interFrameTimeout` of
        /// the previous accepted frame.
        case timedOutWaitingForNextFrame
        /// The underlying stream finished (capture error/teardown) before
        /// `count` frames were collected.
        case streamEndedBeforeReachingCount(received: Int, expected: Int)

        package var description: String {
            switch self {
            case .timedOutWaitingForFirstFrame:
                return "no frame arrived within the first-frame timeout — the meeting window may be hidden/minimized or otherwise not producing frames"
            case .timedOutWaitingForNextFrame:
                return "no further frame arrived within the inter-frame timeout"
            case .streamEndedBeforeReachingCount(let received, let expected):
                return "capture stream ended after \(received) of \(expected) requested frame(s)"
            }
        }
    }

    private var stream: SCStream?
    private var output: StreamFrameOutput?
    private var didStop = false
    /// Iterator over the current `start()` call's `AsyncStream<CapturedFrame>`,
    /// stored on the actor so `captureFrames`'s bounded timeout race
    /// (`nextFrame(timeout:)`) can drive it from a `TaskGroup` child task via
    /// an actor-isolated method call, instead of capturing an `inout`
    /// iterator in an escaping closure (which Swift disallows).
    private var frameIteratorBox: IteratorBox?

    package init() {}

    /// Read-only discovery: enumerates every on-screen window belonging to
    /// `bundlePrefix` — no `SCStream` started, no frame captured. This is
    /// `frame-dump --list-windows` (§1). Requires the same Screen Recording
    /// precondition as capture (window titles are hidden from an untrusted
    /// process) but performs no capture itself.
    package static func listWindows(bundlePrefix: String) throws -> [(windowID: UInt32, title: String, ownerName: String)] {
        guard CapturePreflight.screenRecordingStatus() == .authorized else {
            throw ResolutionError.screenRecordingNotAuthorized
        }
        let prefix = bundlePrefix.lowercased()
        let matchingPIDs = Set(
            NSWorkspace.shared.runningApplications.compactMap { app -> Int32? in
                guard let bundleID = app.bundleIdentifier?.lowercased() else { return nil }
                guard bundleID == prefix || bundleID.hasPrefix(prefix + ".") else { return nil }
                return app.processIdentifier
            }
        )
        let cgWindows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]) ?? []
        return cgWindows.compactMap { dict in
            guard
                let id = dict[kCGWindowNumber as String] as? Int,
                let pid = dict[kCGWindowOwnerPID as String] as? Int32,
                matchingPIDs.contains(pid),
                let title = dict[kCGWindowName as String] as? String,
                let ownerName = dict[kCGWindowOwnerName as String] as? String
            else { return nil }
            return (windowID: UInt32(id), title: title, ownerName: ownerName)
        }
    }

    /// Starts video-only capture of the resolved window. Returns an
    /// `AsyncStream<CapturedFrame>` the caller consumes directly; call
    /// `stop()` (or cancel the consuming `Task`) to tear the stream down.
    ///
    /// Exactly one of `expectedMeetingTitle`/`explicitWindowID` should be
    /// supplied by the caller (`FrameDumpProbe.validate(...)` already
    /// enforces this contract before this method is ever called).
    ///
    /// **Not the recommended entry point (Phase 7 impl-review-1 MEDIUM-1):**
    /// this raw `start()`/`stop()` pair has no first-frame or inter-frame
    /// timeout of its own — a caller that consumes the returned stream with
    /// a bare `for await` can hang indefinitely if the resolved window never
    /// produces a frame. `private` because the only in-package caller is
    /// `captureFrames(...)` below, which owns the bounded consumption loop
    /// and guaranteed `stop()` teardown; kept as a separate method (rather
    /// than inlined) only so the window-resolution logic stays independently
    /// readable.
    private func start(
        bundlePrefix: String,
        expectedMeetingTitle: String? = nil,
        explicitWindowID: UInt32? = nil,
        intervalSeconds: Double = 1.0
    ) async throws -> AsyncStream<CapturedFrame> {
        guard CapturePreflight.screenRecordingStatus() == .authorized else {
            throw ResolutionError.screenRecordingNotAuthorized
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let prefix = bundlePrefix.lowercased()
        guard let app = content.applications.first(where: { candidate in
            let id = candidate.bundleIdentifier.lowercased()
            return id == prefix || id.hasPrefix(prefix + ".")
        }) else {
            throw ResolutionError.noRunningApp(bundlePrefix: bundlePrefix)
        }
        guard !content.displays.isEmpty else { throw ResolutionError.noDisplay }

        let resolvedWindow: SCWindow
        if let explicitWindowID {
            guard let match = content.windows.first(where: { $0.windowID == explicitWindowID }) else {
                throw ResolutionError.windowIDNotOwnedByMatchedApp(explicitWindowID)
            }
            let canonicalPrefix = MeetingAppCatalog.match(bundleID: app.bundleIdentifier)?.canonicalBundlePrefix ?? app.bundleIdentifier
            let runningProcesses = NSWorkspace.shared.runningApplications.map {
                (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "")
            }
            let ownerFamily = ScreenCaptureKitSource.candidatePIDs(
                target: app.bundleIdentifier,
                canonicalBundlePrefix: canonicalPrefix,
                runningProcesses: runningProcesses
            )
            guard let ownerPID = match.owningApplication?.processID, ownerFamily.contains(ownerPID) else {
                throw ResolutionError.windowIDNotOwnedByMatchedApp(explicitWindowID)
            }
            resolvedWindow = match
        } else {
            let canonicalPrefix = MeetingAppCatalog.match(bundleID: app.bundleIdentifier)?.canonicalBundlePrefix ?? app.bundleIdentifier
            let matchedApp = MeetingAppCatalog.match(bundleID: app.bundleIdentifier)?.app
            let runningProcesses = NSWorkspace.shared.runningApplications.map {
                (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "")
            }
            let pids = ScreenCaptureKitSource.candidatePIDs(
                target: app.bundleIdentifier,
                canonicalBundlePrefix: canonicalPrefix,
                runningProcesses: runningProcesses
            )
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
            guard let meetingWindowID = ScreenCaptureKitSource.resolveMeetingWindowID(
                fromFrontToBack: frontToBack,
                candidatePIDs: pids,
                titleHints: matchedApp?.titleHints ?? [],
                nonMeetingTitlePrefixes: matchedApp?.nonMeetingTitlePrefixes ?? [],
                expectedMeetingTitle: expectedMeetingTitle
            ), let window = content.windows.first(where: { Int($0.windowID) == meetingWindowID }) else {
                throw ResolutionError.noWindowResolved
            }
            resolvedWindow = window
        }

        let clock = SessionClock(originSeconds: HostClock.now())
        let scale = NSScreen.screens.first { $0.frame.contains(resolvedWindow.frame.origin) }?.backingScaleFactor ?? 2
        let (pixelWidth, pixelHeight) = ScreenCaptureKitSource.videoStreamPixelSize(windowSize: resolvedWindow.frame.size, backingScale: scale)

        let (frames, frameContinuation) = AsyncStream<CapturedFrame>.makeStream(bufferingPolicy: .bufferingNewest(2))
        let (diagnostics, diagnosticsContinuation) = AsyncStream<CaptureSourceError>.makeStream(bufferingPolicy: .bufferingNewest(16))

        let videoConfig = SCStreamConfiguration()
        videoConfig.width = pixelWidth
        videoConfig.height = pixelHeight
        videoConfig.pixelFormat = kCVPixelFormatType_32BGRA
        videoConfig.capturesAudio = false
        videoConfig.showsCursor = false
        videoConfig.minimumFrameInterval = CMTime(seconds: max(intervalSeconds, 1.0 / 30.0), preferredTimescale: 600)

        let videoFilter = SCContentFilter(desktopIndependentWindow: resolvedWindow)
        let frameOutput = StreamFrameOutput(clock: clock, frames: frameContinuation, diagnostics: diagnosticsContinuation)
        let videoStream = SCStream(filter: videoFilter, configuration: videoConfig, delegate: frameOutput)
        try videoStream.addStreamOutput(frameOutput, type: .screen, sampleHandlerQueue: DispatchQueue.global(qos: .utility))
        try await videoStream.startCapture()

        self.stream = videoStream
        self.output = frameOutput
        // `diagnostics` is intentionally unused by `FrameDumpProbe` beyond a
        // best-effort drain — the tool already prints capture errors from its
        // own `do/catch`; nothing here needs a second consumer of this
        // stream. Finishing it eagerly avoids leaking an unread continuation
        // for the lifetime of this actor.
        Task.detached { for await _ in diagnostics {} }

        self.frameIteratorBox = IteratorBox(frames.makeAsyncIterator())

        return frames
    }

    /// Tears down the video stream — idempotent, safe to call even if
    /// `start` was never called or already finished on its own.
    package func stop() async {
        guard !didStop else { return }
        didStop = true
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        output = nil
        frameIteratorBox = nil
    }

    /// The recommended, scoped capture entry point (Phase 7 impl-review-1
    /// MEDIUM-1): starts video-only capture, collects up to `count`
    /// interval-spaced frames, and **always** tears down the stream via
    /// `stop()` before returning or throwing — on success, on any
    /// resolution/capture error, on a first-frame/inter-frame timeout, and
    /// on cancellation of the calling `Task`. Callers never need their own
    /// `defer`/cancellation-handler boilerplate around `start()`/`stop()`.
    ///
    /// - `firstFrameTimeout` bounds the wait for the very first frame after
    ///   the stream starts (measured from this call, not from `start()`
    ///   returning, since both happen inside this same method).
    /// - `interFrameTimeout` bounds the wait for every subsequent frame,
    ///   measured from the previously *accepted* (interval-spaced) frame.
    /// - Frame spacing: a raw frame is only accepted (counted toward
    ///   `count`) if at least `intervalSeconds` has elapsed since the last
    ///   accepted frame's `sessionTime` — mirrors the spacing `FrameDumpProbe`
    ///   previously enforced itself at the call site, now centralized here
    ///   so every caller of this seam gets it for free.
    package func captureFrames(
        bundlePrefix: String,
        expectedMeetingTitle: String? = nil,
        explicitWindowID: UInt32? = nil,
        intervalSeconds: Double = 1.0,
        count: Int,
        firstFrameTimeout: Duration = .seconds(20),
        interFrameTimeout: Duration = .seconds(15)
    ) async throws -> [CapturedFrame] {
        _ = try await start(
            bundlePrefix: bundlePrefix,
            expectedMeetingTitle: expectedMeetingTitle,
            explicitWindowID: explicitWindowID,
            intervalSeconds: intervalSeconds
        )

        do {
            let result = try await withTaskCancellationHandler {
                try await collectFrames(
                    count: count,
                    intervalSeconds: intervalSeconds,
                    firstFrameTimeout: firstFrameTimeout,
                    interFrameTimeout: interFrameTimeout
                )
            } onCancel: {
                // `withTaskCancellationHandler`'s `onCancel` closure is
                // synchronous and non-isolated, so it cannot `await` this
                // actor's `stop()` directly — spawn a detached task instead.
                // This is a best-effort backstop only: the primary teardown
                // guarantee comes from the `do`/`catch` below and the
                // `CancellationError` thrown out of `collectFrames` (via
                // `Task.checkCancellation()`), both of which run on this
                // actor and call `stop()` before returning/rethrowing.
                Task.detached { await self.stop() }
            }
            await stop()
            return result
        } catch {
            await stop()
            throw error
        }
    }

    /// The inner bounded-collection loop for `captureFrames`. Not itself
    /// responsible for `stop()` — the caller (`captureFrames`) guarantees
    /// teardown around every exit path of this function.
    private func collectFrames(
        count: Int,
        intervalSeconds: Double,
        firstFrameTimeout: Duration,
        interFrameTimeout: Duration
    ) async throws -> [CapturedFrame] {
        var accepted: [CapturedFrame] = []
        var lastAcceptedTime: Double?

        while accepted.count < count {
            try Task.checkCancellation()
            let timeout = lastAcceptedTime == nil ? firstFrameTimeout : interFrameTimeout
            guard let frame = try await nextFrame(timeout: timeout) else {
                throw CaptureError.streamEndedBeforeReachingCount(received: accepted.count, expected: count)
            }
            if let lastAcceptedTime, frame.sessionTime - lastAcceptedTime < intervalSeconds {
                continue
            }
            lastAcceptedTime = frame.sessionTime
            accepted.append(frame)
        }
        return accepted
    }

    /// Result of racing "the next raw frame" against "the timeout" in
    /// `nextFrame(timeout:)` — `Sendable` so it can cross the `TaskGroup`
    /// child-task boundary.
    private enum FrameOrTimeout: Sendable {
        case frame(CapturedFrame?)
        case timedOut
    }

    /// Races `advanceIterator()` (the next raw frame, or `nil` at stream
    /// end/cancellation) against a `Task.sleep(for: timeout)`, whichever
    /// completes first. On timeout, cancels the still-pending frame-fetch
    /// task — `AsyncStream.Iterator.next()` observes task cancellation and
    /// returns `nil` promptly (verified: cancelling the consuming task
    /// resumes a pending `next()` immediately rather than hanging), so this
    /// never leaves an orphaned child task for `withThrowingTaskGroup` to
    /// wait on indefinitely.
    private func nextFrame(timeout: Duration) async throws -> CapturedFrame? {
        let outcome = try await withThrowingTaskGroup(of: FrameOrTimeout.self) { group -> FrameOrTimeout in
            group.addTask {
                .frame(await self.advanceIterator())
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            // Only two tasks were added; the first to complete decides the
            // outcome, and `cancelAll()` (in `defer`) ensures the other
            // finishes promptly (either the sleep is cancelled, or the
            // frame-fetch observes cancellation via `next()`, per above).
            guard let first = try await group.next() else {
                return .frame(nil)
            }
            return first
        }

        switch outcome {
        case .frame(let frame):
            return frame
        case .timedOut:
            throw lastFrameSeen ? CaptureError.timedOutWaitingForNextFrame : CaptureError.timedOutWaitingForFirstFrame
        }
    }

    /// Tracks whether any frame has ever been produced by `advanceIterator()`
    /// during the current `captureFrames` call — purely so `nextFrame`'s
    /// timeout branch can distinguish `.timedOutWaitingForFirstFrame` from
    /// `.timedOutWaitingForNextFrame` without threading that state through
    /// every call site.
    private var lastFrameSeen = false

    /// Class wrapper around `AsyncStream<CapturedFrame>.Iterator` so it can
    /// be stored as actor state and awaited on across the actor-isolation
    /// boundary without the compiler flagging a data race: `next()` is a
    /// non-actor-isolated `mutating async` method, so calling it directly on
    /// a `var` held in actor storage triggers Swift 6 strict concurrency's
    /// "sending risks data race" diagnostic (the iterator value would need
    /// to be sent to a nonisolated context for the call). `@unchecked
    /// Sendable` is safe here because every access is funneled through
    /// `advanceIterator()`, an actor-isolated method — the actor's own
    /// isolation already guarantees at most one in-flight call to `next()`
    /// at a time; this box only works around the compiler's inability to see
    /// that a `mutating async` call site is safely serialized by the
    /// surrounding actor.
    private final class IteratorBox: @unchecked Sendable {
        var iterator: AsyncStream<CapturedFrame>.Iterator
        init(_ iterator: AsyncStream<CapturedFrame>.Iterator) { self.iterator = iterator }
        func next() async -> CapturedFrame? { await iterator.next() }
    }

    /// Advances the actor-owned `frameIterator` by exactly one element.
    /// Actor-isolated so it is safe to call from a `TaskGroup` child task
    /// (the call itself hops back onto the actor; the underlying
    /// `AsyncStream.Iterator` is never touched concurrently).
    private func advanceIterator() async -> CapturedFrame? {
        guard let box = frameIteratorBox else { return nil }
        let frame = await box.next()
        if frame != nil { lastFrameSeen = true }
        return frame
    }

    deinit {
        // No async teardown attempted here (unlike `stop()`): actor `deinit`
        // is non-isolated and `SCStream` is not `Sendable`, so there is no
        // safe way to `await stream.stopCapture()` from this context (same
        // constraint `VisionSpeakerAttributor.deinit` documents for its own
        // `Task` cancellation). `captureFrames(...)` always calls `stop()`
        // itself (success, error, timeout, and cancellation paths all call
        // it) before this type is ever dropped, so this is a documented gap,
        // not a load-bearing cleanup path.
    }
}

