import Foundation
import AppKit
import AudioToolbox
import CoreAudio

// MARK: - Tap membership (pure, package-visible for AlembicCheck)

/// Core Audio identity of one audio-registered process, as needed to decide
/// whether it belongs to the meeting app's tap.
package struct TapProcessInfo: Sendable, Equatable {
    package let objectID: UInt32
    package let pid: Int32
    /// Empty when the process has no bundle ID.
    package let bundleID: String
    /// The process macOS holds responsible for this one (e.g. the browser that
    /// owns a WebKit GPU helper); equals `pid` when unknown.
    package let responsiblePID: Int32

    package init(objectID: UInt32, pid: Int32, bundleID: String, responsiblePID: Int32) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.responsiblePID = responsiblePID
    }
}

// MARK: - ProcessTapCapture

/// Captures the meeting app's output audio ("them") with a Core Audio process
/// tap — the replacement for the former app-level `SCStream` audio capture.
///
/// ## Why not ScreenCaptureKit
/// Any active `SCStream` makes macOS mark the screen as *shared* for Focus
/// (`DNDAuxiliaryState isScreenShared=1`). With the common "Allow notifications
/// when mirroring or sharing the display" setting off, every notification is
/// then silenced for the entire meeting. A process tap is not a screen-capture
/// session, so notifications behave normally while Alembic transcribes.
///
/// ## Shape
/// - A private, **unmuted** `CATapDescription` stereo mixdown of the target's
///   process family (`tapProcessObjectIDs`), so the user still hears the call.
/// - A private aggregate device containing **only** the tap (no hardware
///   sub-device), so capture does not depend on the current output device and
///   survives headphone/AirPods switches mid-call.
/// - An IOProc on a `.userInitiated` queue that converts each buffer list into
///   `.them` audio placed by its host time (the same `HostClock` basis as the
///   mic) on a `ContiguousAudioTimeline`, plus a heartbeat that pads silence
///   while the app produces no audio. The tap only delivers buffers while the
///   app plays sound, but the analyzer times results by audio fed, so the
///   stream must stay contiguous from session start — the mic path does the
///   same, so "you" and "them" share one timeline.
/// - Listeners that re-target the running tap as the family's processes come
///   and go (Electron helpers open audio lazily), follow tap format changes
///   (sample rate), and surface the device dying as a fatal `.streamStopped`.
///
/// Requires the System Audio Recording permission (`kTCCServiceAudioCapture`).
///
/// ## Concurrency
/// `start`/`stop` are called from the owning `ScreenCaptureKitSource` actor.
/// Listener handlers run on `controlQueue` and bail once `stopped` is set;
/// `stop()` drains `controlQueue` before destroying any Core Audio object.
/// `@unchecked Sendable`: every mutable property is guarded by `lock`.
package final class ProcessTapCapture: @unchecked Sendable {
    private let targetID: String
    private let canonicalBundlePrefix: String
    private let ownPID: Int32
    private let monitor = AudioProcessMonitor()

    private let controlQueue = DispatchQueue(label: "com.alembic.process-tap.control", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "com.alembic.process-tap.io", qos: .userInitiated)

    private let lock = NSLock()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var tapDescription: CATapDescription?
    private var tappedObjectIDs: [UInt32] = []
    private var sampleRate: Double = 0
    private var channelCount = 2
    private var timeline = ContiguousAudioTimeline()
    private var chunks: AsyncStream<AudioChunk>.Continuation?
    private var meters: AsyncStream<MeterUpdate>.Continuation?
    private var heartbeat: DispatchSourceTimer?
    private var listeners: [(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)] = []
    private var stopped = false

    init(targetID: String, canonicalBundlePrefix: String, ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.targetID = targetID
        self.canonicalBundlePrefix = canonicalBundlePrefix
        self.ownPID = ownPID
    }

    // MARK: Lifecycle

    /// Creates the tap + aggregate device and starts delivering `.them` chunks.
    /// Throws `.systemAudioRecordingDenied` when Core Audio refuses the tap for
    /// lack of permission, `.audioTapFailed` for any other setup failure; any
    /// partially created Core Audio objects are torn down before throwing.
    func start(
        clock: SessionClock,
        chunks: AsyncStream<AudioChunk>.Continuation,
        meters: AsyncStream<MeterUpdate>.Continuation,
        errors: AsyncStream<CaptureSourceError>.Continuation
    ) throws {
        lock.withLock {
            self.chunks = chunks
            self.meters = meters
        }
        do {
            try startTapAndDevice(clock: clock)
        } catch {
            stop()
            throw error
        }
        startHeartbeat(clock: clock)
        addListener(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) { [weak self] in
            self?.retargetTap()
        }
        let (tap, aggregate) = lock.withLock { (tapID, aggregateID) }
        addListener(tap, kAudioTapPropertyFormat) { [weak self] in
            self?.refreshSampleRate()
        }
        addListener(aggregate, kAudioDevicePropertyDeviceIsAlive) { [weak self] in
            guard let self, !self.isStopped, !Self.isAlive(aggregate) else { return }
            errors.yield(.streamStopped("meeting audio tap device stopped"))
        }
    }

    /// Idempotent teardown of every Core Audio object this instance created.
    func stop() {
        let (registered, timer): ([(object: AudioObjectID, address: AudioObjectPropertyAddress, block: AudioObjectPropertyListenerBlock)], DispatchSourceTimer?) = lock.withLock {
            stopped = true
            defer {
                listeners = []
                heartbeat = nil
            }
            return (listeners, heartbeat)
        }
        timer?.cancel()
        for listener in registered {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, controlQueue, listener.block)
        }
        // Barrier: any handler already running finishes before teardown.
        controlQueue.sync {}

        let (tap, aggregate, procID) = lock.withLock {
            defer {
                tapID = AudioObjectID(kAudioObjectUnknown)
                aggregateID = AudioObjectID(kAudioObjectUnknown)
                ioProcID = nil
                tapDescription = nil
            }
            return (tapID, aggregateID, ioProcID)
        }
        if aggregate != kAudioObjectUnknown, let procID {
            AudioDeviceStop(aggregate, procID)
            AudioDeviceDestroyIOProcID(aggregate, procID)
            ioQueue.sync {}
        }
        if aggregate != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregate)
        }
        if tap != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tap)
        }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private var currentSampleRate: Double { lock.withLock { sampleRate } }

    private func startTapAndDevice(clock: SessionClock) throws {
        let objectIDs = familyObjectIDs()
        let description = CATapDescription(stereoMixdownOfProcesses: objectIDs.map { AudioObjectID($0) })
        description.uuid = UUID()
        description.name = "Alembic meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { throw Self.tapError("create the process tap", status) }
        lock.withLock {
            tapID = tap
            tapDescription = description
            tappedObjectIDs = objectIDs
        }

        let format = try Self.readTapFormat(tap)
        lock.withLock {
            sampleRate = format.mSampleRate
            channelCount = max(Int(format.mChannelsPerFrame), 1)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Alembic Meeting Audio",
            kAudioAggregateDeviceUIDKey: "com.alembic.meeting-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate)
        guard status == noErr else { throw Self.tapError("create the tap device", status) }
        lock.withLock { aggregateID = aggregate }

        var procID: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, ioQueue) { [weak self] _, inputData, inputTime, _, _ in
            guard let self else { return }
            let time = inputTime.pointee
            let hostSeconds = time.mFlags.contains(.hostTimeValid)
                ? HostClock.seconds(fromMachHostTime: time.mHostTime)
                : nil
            guard let block = AudioBufferConversion.decode(
                bufferList: inputData,
                sampleRate: self.currentSampleRate,
                hostSeconds: hostSeconds
            ) else { return }
            let start = clock.sessionTime(forPlatformTime: block.presentationSeconds ?? HostClock.now())
            self.lock.withLock {
                guard !self.stopped else { return }
                self.emit(self.timeline.place(block.monoSamples, sampleRate: block.sampleRate, at: start))
            }
        }
        guard status == noErr, let procID else { throw Self.tapError("create the tap reader", status) }
        lock.withLock { ioProcID = procID }

        status = AudioDeviceStart(aggregate, procID)
        guard status == noErr else { throw Self.tapError("start the tap device", status) }
    }

    // MARK: Contiguous timeline

    /// Heartbeat period, and how far behind "now" it pads — comfortably more
    /// than the IOProc's delivery latency (~30 ms + one 512-frame buffer), so
    /// padding never runs ahead of audio that is still in flight.
    private static let heartbeatInterval: DispatchTimeInterval = .milliseconds(250)
    private static let silenceLag: Double = 0.2

    private func startHeartbeat(clock: SessionClock) {
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let through = clock.sessionTime(forPlatformTime: HostClock.now()) - Self.silenceLag
            self.lock.withLock {
                guard !self.stopped,
                      let silence = self.timeline.fillSilence(through: through, sampleRate: self.sampleRate)
                else { return }
                self.emit([silence])
            }
        }
        lock.withLock { heartbeat = timer }
        timer.resume()
    }

    /// Yields timeline segments as `.them` chunks plus meter updates, in order.
    /// Must be called with `lock` held so chunks never interleave.
    private func emit(_ segments: [ContiguousAudioTimeline.Segment]) {
        for segment in segments {
            chunks?.yield(AudioChunk(
                samples: segment.samples,
                sampleRate: segment.sampleRate,
                channelCount: channelCount,
                source: .them,
                startTime: segment.start
            ))
            meters?.yield(MeterUpdate(source: .them, level: .measuring(segment.samples)))
        }
    }

    // MARK: Listeners

    private func addListener(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ handler: @escaping @Sendable () -> Void) {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, controlQueue, block) == noErr else {
            print("[alembic] Meeting audio tap: could not observe property \(Self.fourCC(selector))")
            return
        }
        lock.withLock { listeners.append((object: object, address: address, block: block)) }
    }

    /// Re-targets the running tap when the app family's audio processes change
    /// (runs on `controlQueue`).
    private func retargetTap() {
        let ids = familyObjectIDs()
        let current: (tap: AudioObjectID, description: CATapDescription)? = lock.withLock {
            guard !stopped, ids != tappedObjectIDs, let tapDescription else { return nil }
            return (tapID, tapDescription)
        }
        guard let current else { return }

        current.description.processes = ids.map { AudioObjectID($0) }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyDescription,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var reference = current.description
        let status = withUnsafeMutablePointer(to: &reference) { pointer in
            AudioObjectSetPropertyData(current.tap, &address, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), pointer)
        }
        if status == noErr {
            lock.withLock { tappedObjectIDs = ids }
        } else {
            print("[alembic] Meeting audio tap: re-target failed (\(Self.fourCC(UInt32(bitPattern: status))))")
        }
    }

    /// Follows tap format changes (e.g. the output device's sample rate) so
    /// chunks always report the rate their samples were produced at.
    private func refreshSampleRate() {
        let tap: AudioObjectID? = lock.withLock { stopped ? nil : tapID }
        guard let tap, let format = try? Self.readTapFormat(tap) else { return }
        lock.withLock { sampleRate = format.mSampleRate }
    }

    // MARK: Family resolution

    private func familyObjectIDs() -> [UInt32] {
        let running = NSWorkspace.shared.runningApplications.map {
            (pid: $0.processIdentifier, bundleID: $0.bundleIdentifier ?? "")
        }
        let familyPIDs = ScreenCaptureKitSource.candidatePIDs(
            target: targetID,
            canonicalBundlePrefix: canonicalBundlePrefix,
            runningProcesses: running
        )
        let processes = monitor.processObjects().map { process in
            TapProcessInfo(
                objectID: process.objectID,
                pid: process.pid,
                bundleID: process.bundleID,
                responsiblePID: Responsibility.responsiblePID(for: process.pid)
            )
        }
        return Self.tapProcessObjectIDs(
            canonicalBundlePrefix: canonicalBundlePrefix,
            familyPIDs: familyPIDs,
            ownPID: ownPID,
            processes: processes
        )
    }

    /// Pure: which audio process objects the meeting tap should include —
    /// sorted, de-duplicated object IDs of every process that is
    /// 1. in the target's bundle family (`canonicalBundlePrefix` or a
    ///    dot-delimited child, case-insensitive — Electron/Chromium helpers), or
    /// 2. one of `familyPIDs` (the target's running process family; for a
    ///    `pid:` target, exactly that PID), or
    /// 3. a process one of `familyPIDs` is responsible for (e.g. a WebKit GPU
    ///    helper playing a browser tab's audio) — the same attribution
    ///    ScreenCaptureKit's app-level audio filter used,
    ///
    /// excluding Alembic itself.
    package static func tapProcessObjectIDs(
        canonicalBundlePrefix: String,
        familyPIDs: Set<Int32>,
        ownPID: Int32,
        processes: [TapProcessInfo]
    ) -> [UInt32] {
        let prefix = canonicalBundlePrefix.lowercased()
        let ids = processes.filter { process in
            guard process.pid != ownPID else { return false }
            let bundleID = process.bundleID.lowercased()
            let inBundleFamily = !bundleID.isEmpty && (bundleID == prefix || bundleID.hasPrefix(prefix + "."))
            return inBundleFamily
                || familyPIDs.contains(process.pid)
                || familyPIDs.contains(process.responsiblePID)
        }.map(\.objectID)
        return Array(Set(ids)).sorted()
    }

    // MARK: Helpers

    private static func readTapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format)
        guard status == noErr else { throw tapError("read the tap format", status) }
        let isFloat32 = format.mFormatID == kAudioFormatLinearPCM
            && (format.mFormatFlags & kAudioFormatFlagIsFloat) != 0
            && format.mBitsPerChannel == 32
        guard isFloat32, format.mSampleRate > 0 else {
            throw CaptureSourceError.audioTapFailed(
                "unsupported tap format (\(format.mBitsPerChannel)-bit, flags 0x\(String(format.mFormatFlags, radix: 16)), \(format.mSampleRate) Hz)")
        }
        return format
    }

    private static func isAlive(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    /// Maps a Core Audio failure to a capture error; a permissions failure
    /// means System Audio Recording was not granted.
    private static func tapError(_ action: String, _ status: OSStatus) -> CaptureSourceError {
        if status == kAudioDevicePermissionsError {
            return .systemAudioRecordingDenied
        }
        return .audioTapFailed("could not \(action) (\(fourCC(UInt32(bitPattern: status))))")
    }

    /// Renders an OSStatus / selector as its four-character code when printable.
    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "OSStatus \(Int32(bitPattern: value))" }
        return "'" + String(decoding: bytes, as: UTF8.self) + "'"
    }
}

// MARK: - Responsibility (libsystem SPI)

/// `responsibility_get_pid_responsible_for_pid`, resolved at runtime: maps a
/// helper process (e.g. a WebKit GPU process playing a browser tab's audio) to
/// the app macOS holds responsible for it. Falls back to the PID itself when
/// the symbol is unavailable, which only narrows the tap to bundle-family and
/// direct-PID members.
private enum Responsibility {
    private typealias Function = @convention(c) (pid_t) -> pid_t

    private static let function: Function? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Function.self)
    }()

    static func responsiblePID(for pid: pid_t) -> pid_t {
        guard let function else { return pid }
        let responsible = function(pid)
        return responsible > 0 ? responsible : pid
    }
}
