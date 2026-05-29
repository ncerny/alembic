import Foundation

/// A deterministic, hardware-free `AudioSource` test seam.
///
/// Emits a *scripted* sequence of `AudioChunk`s on `buffers` so later phases
/// (orchestrator state machine, source-merge ordering, writer drain) can be
/// tested without a live Teams meeting or any Apple capture framework. Lives in
/// `AlembicKit` (not `Platform/macOS`) precisely because it is platform-neutral
/// and used by `AlembicCheck`.
///
/// ## Behaviour
/// - `availableTargets()` returns whatever targets it was configured with.
/// - `start(target:)` yields the entire script (in order) on `buffers`. If
///   `finishAfterScript` is `true`, the stream is finished immediately after the
///   script so a consumer can drain it to completion; otherwise it stays open
///   until `stop()`.
/// - `stop()` is idempotent and always finishes `buffers`.
///
/// Modeled as an `actor` so its small amount of lifecycle state is isolated and
/// the type satisfies `AudioSource: Sendable` without locks.
public actor FakeAudioSource: AudioSource {
    public nonisolated let buffers: AsyncStream<AudioChunk>
    private let continuation: AsyncStream<AudioChunk>.Continuation

    private let script: [AudioChunk]
    private let targets: [CaptureTarget]
    private let finishAfterScript: Bool
    private var didStart = false
    private var didStop = false

    /// - Parameters:
    ///   - script: the chunks to emit, in order, on `start`.
    ///   - targets: targets returned from `availableTargets()`.
    ///   - finishAfterScript: when `true`, finish `buffers` right after emitting
    ///     the script (handy for "drain to end" checks); when `false`, keep the
    ///     stream open until `stop()`.
    public init(
        script: [AudioChunk],
        targets: [CaptureTarget] = [CaptureTarget(id: "fake.target", displayName: "Fake Target")],
        finishAfterScript: Bool = true
    ) {
        self.script = script
        self.targets = targets
        self.finishAfterScript = finishAfterScript
        (buffers, continuation) = AsyncStream<AudioChunk>.makeStream(bufferingPolicy: .unbounded)
    }

    public func availableTargets() async throws -> [CaptureTarget] {
        targets
    }

    public func start(target: CaptureTarget) async throws {
        guard !didStart else { return }
        didStart = true
        for chunk in script {
            continuation.yield(chunk)
        }
        if finishAfterScript {
            continuation.finish()
            didStop = true
        }
    }

    public func stop() async {
        guard !didStop else { return }
        didStop = true
        continuation.finish()
    }
}
