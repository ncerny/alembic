import Foundation
import CoreAudio

/// Reads a point-in-time snapshot of all CoreAudio-registered audio processes.
///
/// Call `snapshot()` when a cheap trigger fires (device-activity wake-up from
/// `DeviceActivityMonitor` or a low-frequency safety poll). Do **not** poll at
/// high frequency — CoreAudio process enumeration has non-trivial overhead.
///
/// Alembic's own PID is excluded from every snapshot so our own mic tap never
/// triggers a self-detection.
public struct AudioProcessMonitor: Sendable {
    private let ownPID: Int32

    public init(ownPID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.ownPID = ownPID
    }

    /// Returns a snapshot of all audio processes known to CoreAudio, with
    /// Alembic's own PID filtered out.
    public func snapshot() -> [AudioProcessState] {
        guard let objectIDs = processObjectList() else { return [] }
        return objectIDs.compactMap { buildState(for: $0) }.filter { $0.pid != ownPID }
    }

    // MARK: - Private helpers

    private func processObjectList() -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else { return nil }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else { return nil }
        return ids
    }

    private func buildState(for objectID: AudioObjectID) -> AudioProcessState? {
        guard let pid = readPID(from: objectID),
              let bundleID = readBundleID(from: objectID) else { return nil }
        return AudioProcessState(
            pid: pid,
            bundleID: bundleID,
            isRunningInput: readBool(kAudioProcessPropertyIsRunningInput, from: objectID),
            isRunningOutput: readBool(kAudioProcessPropertyIsRunningOutput, from: objectID)
        )
    }

    private func readPID(from objectID: AudioObjectID) -> Int32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return pid
    }

    private func readBundleID(from objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // kAudioProcessPropertyBundleID returns a create-rule CFString (+1 retained).
        // Capture the raw pointer bits, then take retained ownership via Unmanaged.
        var rawBits: UInt = 0
        var size = UInt32(MemoryLayout<UInt>.size)
        let status = withUnsafeMutableBytes(of: &rawBits) { buf in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, buf.baseAddress!)
        }
        guard status == noErr, rawBits != 0 else { return nil }
        let cfStr = Unmanaged<CFString>
            .fromOpaque(UnsafeRawPointer(bitPattern: rawBits)!)
            .takeRetainedValue()
        return cfStr as String
    }

    private func readBool(_ selector: AudioObjectPropertySelector, from objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr
            && value != 0
    }
}
