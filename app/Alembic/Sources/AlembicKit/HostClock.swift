import Foundation

/// Monotonic host-time helper shared by the macOS capture paths.
///
/// ## Why this lives in the core (and not under `Platform/macOS`)
/// The session timeline must be anchored to a single **monotonic** origin so the
/// two capture pipelines ("you" mic + "them" `SCStream`) land on one axis. Both
/// of macOS's audio time bases reduce to mach host time:
///
/// - `SCStream` audio: `CMSampleBufferGetPresentationTimeStamp` is on the host
///   time clock (`CMClockGetHostTimeClock`), so `CMTimeGetSeconds` already yields
///   seconds in this basis.
/// - Microphone tap: `AVAudioTime.hostTime` is raw `mach_absolute_time` ticks,
///   converted to seconds here.
///
/// Both therefore map to the **same** seconds basis, and subtracting a single
/// `SessionClock.originSeconds` (captured once at session start via `now()`)
/// yields session-relative times for both. The conversion uses only
/// `mach_timebase_info` / `mach_absolute_time` (Foundation/Darwin), never an
/// Apple *media* framework, so it stays out of the AVFoundation/CoreMedia
/// portability boundary and remains deterministically testable.
public enum HostClock {
    /// Converts raw mach host-time ticks to seconds using the system timebase.
    ///
    /// Pure given the (process-constant) timebase: `0` maps to `0`, and the
    /// result scales linearly with `hostTime`.
    public static func seconds(fromMachHostTime hostTime: UInt64) -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        // ticks -> nanoseconds: ticks * numer / denom
        let nanos = Double(hostTime) * Double(info.numer) / Double(info.denom)
        return nanos / 1_000_000_000
    }

    /// The current monotonic host time, in seconds. Captured once at session
    /// start to seed `SessionClock.originSeconds`.
    public static func now() -> Double {
        seconds(fromMachHostTime: mach_absolute_time())
    }
}
