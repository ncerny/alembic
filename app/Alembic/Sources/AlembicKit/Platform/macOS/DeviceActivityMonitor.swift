import Foundation
import CoreAudio

/// Bridges CoreAudio's `kAudioDevicePropertyDeviceIsRunningSomewhere` events
/// for every audio device to an `AsyncStream<Bool>`.
///
/// Emits `true` when at least one device starts running (cheap trigger to
/// initiate a full `AudioProcessMonitor.snapshot()`) and `false` when all
/// known devices are silent. The false edge is debounced ~300 ms to avoid
/// spurious idle transitions between rapid start/stop bursts.
///
/// Device-list changes (`kAudioHardwarePropertyDevices`) automatically rebind
/// the listener set so newly attached (or removed) devices are tracked.
///
/// Store the CoreAudio listener blocks `nonisolated(unsafe)` — they are
/// invoked on an arbitrary CoreAudio kernel thread.
public final class DeviceActivityMonitor: @unchecked Sendable {

    public let stream: AsyncStream<Bool>
    private let continuation: AsyncStream<Bool>.Continuation

    /// Registered `kAudioDevicePropertyDeviceIsRunningSomewhere` listeners,
    /// keyed by the `AudioObjectID` of each device.
    nonisolated(unsafe) private var deviceListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    /// Listener for device-list changes on the system object.
    nonisolated(unsafe) private var systemListener: AudioObjectPropertyListenerBlock?

    private let lock = NSLock()
    private var debounceTask: Task<Void, Never>?

    public init() {
        (stream, continuation) = AsyncStream<Bool>.makeStream()
        bindAll()
        registerSystemListener()
    }

    deinit {
        removeAllDeviceListeners()
        removeSystemListener()
        continuation.finish()
    }

    // MARK: - Setup

    private func registerSystemListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebind()
        }
        systemListener = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    }

    private func removeSystemListener() {
        guard let block = systemListener else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
    }

    /// Enumerates all devices and adds/removes listeners to match.
    private func rebind() {
        let current = currentDeviceIDs()
        lock.lock(); defer { lock.unlock() }
        let existing = Set(deviceListeners.keys)
        let toAdd = current.subtracting(existing)
        let toRemove = existing.subtracting(current)
        for id in toRemove { removeDeviceListener(id) }
        for id in toAdd    { addDeviceListener(id) }
    }

    private func bindAll() {
        let ids = currentDeviceIDs()
        lock.lock(); defer { lock.unlock() }
        for id in ids { addDeviceListener(id) }
    }

    private func removeAllDeviceListeners() {
        lock.lock(); defer { lock.unlock() }
        for id in deviceListeners.keys { removeDeviceListener(id) }
    }

    // MARK: - Per-device listener (must be called under lock)

    private func addDeviceListener(_ deviceID: AudioObjectID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.deviceActivityChanged(deviceID)
        }
        deviceListeners[deviceID] = block
        AudioObjectAddPropertyListenerBlock(deviceID, &address, nil, block)
    }

    private func removeDeviceListener(_ deviceID: AudioObjectID) {
        guard let block = deviceListeners.removeValue(forKey: deviceID) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
    }

    // MARK: - Event handling

    private func deviceActivityChanged(_ deviceID: AudioObjectID) {
        let isRunning = readIsRunning(deviceID)
        if isRunning {
            // Emit true immediately; cancel any pending false debounce
            lock.lock()
            debounceTask?.cancel()
            debounceTask = nil
            lock.unlock()
            continuation.yield(true)
        } else {
            // Debounce the false edge 300 ms
            let cont = continuation
            let task = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                cont.yield(false)
            }
            lock.lock()
            debounceTask?.cancel()
            debounceTask = task
            lock.unlock()
        }
    }

    // MARK: - CoreAudio helpers

    private func currentDeviceIDs() -> Set<AudioObjectID> {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return [] }
        return Set(ids)
    }

    private func readIsRunning(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }
}
