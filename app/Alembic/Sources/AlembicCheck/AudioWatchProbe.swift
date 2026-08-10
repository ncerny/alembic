import Foundation
import AlembicKit

/// Live diagnostic: `swift run AlembicCheck audio-watch [seconds]`
///
/// Polls `AudioProcessMonitor` and prints every per-process CoreAudio
/// input/output state transition with a timestamp, annotated with the catalog
/// match and the tier the detector would assign. Run it during a real call to
/// answer empirical questions the harness cannot:
///
/// - Does Teams keep `isRunningInput` while muted in a call?
/// - How quickly is the mic released at hang-up?
/// - How long does a notification chime hold `isRunningOutput`?
///
/// The answers gate the future "end on input-drop" fast path (see the
/// 2026-08-10 tiered-detection research doc).
enum AudioWatchProbe {

    static func run(seconds: Double) async {
        let monitor = AudioProcessMonitor()
        let started = ProcessInfo.processInfo.systemUptime
        var previous: [Int32: AudioProcessState] = [:]

        print("audio-watch: logging CoreAudio process transitions for \(Int(seconds))s…")
        print("audio-watch: join/leave/mute/unmute a call now; Ctrl-C to stop early.\n")

        while ProcessInfo.processInfo.systemUptime - started < seconds {
            let now = ProcessInfo.processInfo.systemUptime - started
            let snapshot = monitor.snapshot()
            var current: [Int32: AudioProcessState] = [:]
            for state in snapshot { current[state.pid] = state }

            for (pid, state) in current.sorted(by: { $0.key < $1.key }) {
                let old = previous[pid]
                guard old == nil
                    || old?.isRunningInput != state.isRunningInput
                    || old?.isRunningOutput != state.isRunningOutput else { continue }
                log(now: now, state: state, appeared: old == nil)
            }
            for (pid, state) in previous.sorted(by: { $0.key < $1.key }) where current[pid] == nil {
                print(stamp(now) + " gone      \(state.bundleID) pid=\(pid)")
            }

            // What would the detector make of this snapshot?
            let candidates = MeetingAppCatalog.detectCandidates(processStates: snapshot)
            for c in candidates where changedCandidate(c, previousStates: previous, currentStates: current) {
                print(stamp(now) + " candidate \(c.match.app.displayName) tier=\(c.tier) input=\(c.hasInput) output=\(c.hasOutput)")
            }

            previous = current
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("\naudio-watch: done.")
    }

    private static func log(now: TimeInterval, state: AudioProcessState, appeared: Bool) {
        let match = MeetingAppCatalog.match(bundleID: state.bundleID)
        let annotation = match.map { " [\($0.app.displayName)]" } ?? ""
        let verb = appeared ? "appeared " : "changed  "
        print(stamp(now) + " \(verb) \(state.bundleID) pid=\(state.pid) input=\(state.isRunningInput) output=\(state.isRunningOutput)\(annotation)")
    }

    /// Only re-print a candidate line when some member of the app family
    /// actually changed this poll, to keep the log readable.
    private static func changedCandidate(
        _ candidate: MeetingAppCatalog.InCallCandidate,
        previousStates: [Int32: AudioProcessState],
        currentStates: [Int32: AudioProcessState]
    ) -> Bool {
        for (pid, state) in currentStates {
            let id = state.bundleID.lowercased()
            let inFamily = candidate.match.app.bundlePrefixes.contains { prefix in
                let p = prefix.lowercased()
                return id == p || id.hasPrefix(p + ".")
            }
            guard inFamily else { continue }
            let old = previousStates[pid]
            if old == nil
                || old?.isRunningInput != state.isRunningInput
                || old?.isRunningOutput != state.isRunningOutput {
                return true
            }
        }
        return false
    }

    private static func stamp(_ t: TimeInterval) -> String {
        String(format: "[%7.1fs]", t)
    }
}
