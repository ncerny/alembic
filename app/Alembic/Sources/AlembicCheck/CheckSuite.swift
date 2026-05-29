import Foundation

/// A tiny, dependency-free assertion harness for the `AlembicCheck` executable.
///
/// ## Why this exists
/// Under Xcode Command Line Tools only (no Xcode.app), `swift test` builds but
/// does **not execute** swift-testing/XCTest cases — a deliberately failing test
/// still exits 0. `AlembicCheck` is a plain executable that genuinely runs, so
/// it is the authoritative acceptance command:
///
///     swift run AlembicCheck
///
/// ## Contract
/// - Every `check`/`checkAsync` records a pass or a failure.
/// - Failures are printed to **stderr**; passes to stdout.
/// - `finishAndExit()` prints a summary and calls `exit(1)` if anything failed,
///   `exit(0)` otherwise — so CI / scripts can rely on the exit code.
/// - Use deterministic fakes and an injected clock; never sleep or touch
///   hardware. (Real capture/transcription have manual hardware gates.)
final class CheckSuite {
    private var passed = 0
    private var failures: [String] = []

    /// Records a boolean expectation.
    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if condition {
            passed += 1
        } else {
            failures.append(message())
        }
    }

    /// Records equality of two `Equatable` values, with a descriptive failure.
    func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ label: String) {
        if lhs == rhs {
            passed += 1
        } else {
            failures.append("\(label): expected \(rhs), got \(lhs)")
        }
    }

    /// Runs a synchronous group of expectations, capturing thrown errors as a
    /// failure rather than crashing the whole run.
    func check(_ name: String, _ body: (CheckSuite) throws -> Void) {
        do {
            try body(self)
            FileHandle.standardOutput.write(Data("  ok  \(name)\n".utf8))
        } catch {
            failures.append("\(name): threw \(error)")
            FileHandle.standardError.write(Data("FAIL  \(name): threw \(error)\n".utf8))
        }
    }

    /// Runs an asynchronous group of expectations (for actors / @MainActor /
    /// AsyncStream-driven logic), capturing thrown errors as a failure.
    func checkAsync(_ name: String, _ body: (CheckSuite) async throws -> Void) async {
        let before = failures.count
        do {
            try await body(self)
            if failures.count == before {
                FileHandle.standardOutput.write(Data("  ok  \(name)\n".utf8))
            } else {
                FileHandle.standardError.write(Data("FAIL  \(name)\n".utf8))
            }
        } catch {
            failures.append("\(name): threw \(error)")
            FileHandle.standardError.write(Data("FAIL  \(name): threw \(error)\n".utf8))
        }
    }

    /// Prints a summary and terminates with a nonzero status if anything failed.
    func finishAndExit() -> Never {
        let summary = "\n\(passed) checks passed, \(failures.count) failed\n"
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data(summary.utf8))
            exit(0)
        } else {
            for f in failures {
                FileHandle.standardError.write(Data("  - \(f)\n".utf8))
            }
            FileHandle.standardError.write(Data(summary.utf8))
            exit(1)
        }
    }
}
