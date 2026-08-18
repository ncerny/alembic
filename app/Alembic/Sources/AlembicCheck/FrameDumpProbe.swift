import Foundation
import AlembicKit
import Vision
import CoreGraphics
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// Live diagnostic: `swift run AlembicCheck frame-dump [bundle-prefix]
/// [--meeting-title <title-prefix> | --window-id <CGWindowID> |
/// --list-windows] [--out <path>] [--frames <n>] [--interval <seconds>]
/// [--catalog <name>] [--include-images]`
///
/// Captures real Teams (or other catalogued app) meeting frames — **video
/// only, no microphone/Speech Recognition** — and dumps OCR text + bounding
/// boxes + the currently-catalogued `SpeakerLabelCatalog` regions overlaid, so
/// a maintainer can read off real pixel geometry and active-tile marker
/// colors and hand-update `SpeakerLabelCatalog.teamsDefaults` (SR-22). Modeled
/// directly on `AXDumpProbe.swift` — a live diagnostic, not a check — but
/// scoped to Screen Recording only via `DiagnosticVideoCapture` (Phase 7 §1),
/// never `CapturePreflight.requireForCapture()`.
///
/// **Requirements:** Screen Recording only (System Settings → Privacy &
/// Security → Screen Recording for your terminal app). Never requests or
/// depends on Microphone or Speech Recognition access, and never starts any
/// audio capture.
///
/// **Non-goals:** this tool does not call `SpeakerNameNormalizer`,
/// `ActiveSpeakerTimeline`, or `SpeakerLabelCatalog.match` beyond read-only
/// region lookup — it is a measurement instrument, not a second
/// implementation of the attribution pipeline. It never runs during normal
/// recording and is not on any production code path.
enum FrameDumpProbe {

    // MARK: - Pure argument/path validation (plan-review-2 MEDIUM-2)

    /// How `frame-dump` resolves the target window (§1's positive-evidence
    /// contract — a bare bundle-prefix can never resolve a Teams window,
    /// since Teams has no static `titleHints`).
    package enum ResolutionMode: Sendable, Equatable {
        case listWindows
        case meetingTitle(String)
        case windowID(UInt32)
    }

    /// A fully-resolved, ready-to-run plan — the `.success` output of
    /// `validate(...)`. Contains no live TCC/window-server state; every field
    /// is derived purely from `arguments` plus the caller-supplied
    /// `packageRoot`/`repoRoot`/`gitignorePatterns`/`now`.
    package struct Plan: Sendable, Equatable {
        package let bundlePrefix: String
        package let resolution: ResolutionMode
        package let frames: Int
        package let intervalSeconds: Double
        /// Fully-resolved output directory. Empty for `.listWindows` (no
        /// output is ever written in that mode).
        package let outPath: String
        package let includeImages: Bool
    }

    package enum ValidationError: Error, Sendable, Equatable {
        /// Neither `--meeting-title`, `--window-id`, nor `--list-windows` was
        /// supplied — `bundle-prefix` alone can never resolve a window
        /// (resolves plan-review-2 HIGH-1).
        case missingPositiveEvidence
        /// `--meeting-title` and `--window-id` were both supplied —
        /// ambiguous; pick one.
        case ambiguousPositiveEvidence
        /// `--list-windows` combined with `--meeting-title`/`--window-id`/any
        /// capture-only flag (`--frames`/`--interval`/`--out`/
        /// `--include-images`).
        case listWindowsMutuallyExclusive
        /// `--include-images` was passed without an explicit `--out`.
        case includeImagesRequiresExplicitOut
        /// An explicit `--out` resolves inside the repository working tree
        /// and is not covered by a dedicated gitignore pattern.
        case outInsideRepoNotGitignored(String)
        /// `--frames` failed to parse as a positive integer.
        case invalidFramesCount(String)
        /// `--interval` failed to parse as a non-negative number.
        case invalidInterval(String)
        /// `--window-id` failed to parse as an unsigned integer.
        case invalidWindowID(String)
        /// A flag that requires a value (`--out`, `--meeting-title`, etc.)
        /// was the last argument, with nothing following it.
        case missingValueForFlag(String)
        /// An argument beginning with `--` matched none of the recognized
        /// flags (resolves impl-review-1 LOW-1) — previously fell through
        /// to the default case and was silently accepted as the bundle
        /// prefix, masking a typo'd flag rather than failing deterministically
        /// before any TCC/window-server access.
        case unknownFlag(String)
        /// More than one positional (non-flag) argument was supplied — only
        /// a single bundle-prefix positional argument is accepted (resolves
        /// impl-review-1 LOW-1).
        case multipleBundlePrefixes(first: String, second: String)
        /// Defensive-only: the *default* scratch output path (computed when
        /// `--out` is omitted) did not resolve under a gitignored diagnostics
        /// directory relative to `repoRoot` — this can only happen if
        /// `packageRoot(startingAt:)` fell back to a directory outside the
        /// expected `app/Alembic` package layout (impl-review-1 HIGH-1
        /// recommendation: "run the same allowlist check for default paths
        /// when package-root detection falls back"). Never observed with a
        /// correctly-checked-out repository.
        case defaultOutPathNotAllowlisted(String)
    }

    /// Pure: parses `arguments` and the `--out`/`--include-images`/
    /// `--meeting-title`/`--window-id`/`--list-windows` contract (§1) into a
    /// `Plan`, or a typed `ValidationError` — no live TCC/window-server state
    /// read (`packageRoot`/`repoRoot`/`gitignorePatterns`/`now` are all
    /// caller-supplied, not queried from the filesystem here), so
    /// `AlembicCheck` can call this directly with representative argument
    /// arrays and assert the returned `Result` deterministically.
    ///
    /// `cwd` (impl-review-1 HIGH-1) is the caller's current working
    /// directory, used only to resolve a *relative* explicit `--out` to an
    /// absolute path before it is canonicalized/allowlist-checked — this
    /// function still performs no filesystem *mutation* and reads only
    /// existing-path/symlink metadata (see `canonicalizePath`), never TCC or
    /// window-server state, so it remains safe to call from pure tests with
    /// fabricated `packageRoot`/`repoRoot`/`cwd` values that do not exist on
    /// disk.
    ///
    /// Default output-path contract (resolves plan-review-1 MEDIUM-2/
    /// plan-review-3 MEDIUM-2): when `--out` is omitted and
    /// `--include-images` is false, defaults to
    /// `<packageRoot>/.frame-dump-scratch/<timestamp>/` — the Swift package
    /// root resolved by the caller at runtime (`FrameDumpProbe.run` resolves
    /// it via `packageRoot(startingAt:)`, below), never a literal
    /// `app/Alembic/...` string hardcoded here (which would double up to
    /// `app/Alembic/app/Alembic/...` given the repo's documented `cd
    /// app/Alembic` precondition for `swift run AlembicCheck`).
    package static func validate(
        arguments: [String],
        packageRoot: String,
        repoRoot: String,
        gitignorePatterns: [String],
        cwd: String = FileManager.default.currentDirectoryPath,
        now: Date = Date()
    ) -> Result<Plan, ValidationError> {
        var bundlePrefix = "com.microsoft.teams"
        var bundlePrefixExplicitlySet = false
        var outPath: String?
        var framesCount = 5
        var intervalSeconds = 1.0
        var includeImages = false
        var meetingTitle: String?
        var windowID: UInt32?
        var listWindowsFlag = false
        var framesExplicit = false
        var intervalExplicit = false

        var iterator = arguments.makeIterator()
        while let arg = iterator.next() {
            switch arg {
            case "--out":
                guard let value = iterator.next() else { return .failure(.missingValueForFlag("--out")) }
                outPath = value
            case "--frames":
                guard let value = iterator.next() else { return .failure(.missingValueForFlag("--frames")) }
                guard let parsed = Int(value), parsed > 0 else { return .failure(.invalidFramesCount(value)) }
                framesCount = parsed
                framesExplicit = true
            case "--interval":
                guard let value = iterator.next() else { return .failure(.missingValueForFlag("--interval")) }
                guard let parsed = Double(value), parsed.isFinite, parsed >= 0 else { return .failure(.invalidInterval(value)) }
                intervalSeconds = parsed
                intervalExplicit = true
            case "--catalog":
                // Accepted and discarded at the validate layer: this phase
                // ships exactly one catalog entry (`teamsDefaults`); the flag
                // is parsed here only so a future multi-app catalog does not
                // require re-touching this argument loop. Still requires a
                // value (impl-review-1 LOW-1) — a trailing, value-less
                // `--catalog` must fail deterministically, not silently
                // consume whatever argument (or nothing) follows.
                guard iterator.next() != nil else { return .failure(.missingValueForFlag("--catalog")) }
            case "--include-images":
                includeImages = true
            case "--meeting-title":
                guard let value = iterator.next() else { return .failure(.missingValueForFlag("--meeting-title")) }
                meetingTitle = value
            case "--window-id":
                guard let value = iterator.next() else { return .failure(.missingValueForFlag("--window-id")) }
                guard let parsed = UInt32(value) else { return .failure(.invalidWindowID(value)) }
                windowID = parsed
            case "--list-windows":
                listWindowsFlag = true
            default:
                // impl-review-1 LOW-1: an unrecognized `--flag` must be a
                // deterministic parser error, not silently accepted as the
                // bundle-prefix positional argument (which previously masked
                // typos and made `--include-images`/`--out`-adjacent typos
                // fail for the wrong reason, or not fail at all). Likewise,
                // a second positional argument is rejected outright rather
                // than silently overwriting the first.
                guard !arg.hasPrefix("--") else { return .failure(.unknownFlag(arg)) }
                guard !bundlePrefixExplicitlySet else {
                    return .failure(.multipleBundlePrefixes(first: bundlePrefix, second: arg))
                }
                bundlePrefix = arg
                bundlePrefixExplicitlySet = true
            }
        }

        if listWindowsFlag {
            let anyCaptureOnlyFlag = meetingTitle != nil || windowID != nil || outPath != nil
                || includeImages || framesExplicit || intervalExplicit
            guard !anyCaptureOnlyFlag else { return .failure(.listWindowsMutuallyExclusive) }
            return .success(Plan(
                bundlePrefix: bundlePrefix,
                resolution: .listWindows,
                frames: 0,
                intervalSeconds: 0,
                outPath: "",
                includeImages: false
            ))
        }

        guard meetingTitle != nil || windowID != nil else { return .failure(.missingPositiveEvidence) }
        guard !(meetingTitle != nil && windowID != nil) else { return .failure(.ambiguousPositiveEvidence) }

        if includeImages {
            guard outPath != nil else { return .failure(.includeImagesRequiresExplicitOut) }
        }

        let resolvedOutPath: String
        if let outPath {
            // impl-review-1 HIGH-1: canonicalize (resolve relative-to-`cwd`,
            // normalize `.`/`..` components, resolve symlinks on the
            // existing-on-disk prefix) *before* the privacy allowlist check
            // — a raw relative string (e.g. `frame-dump-out`) previously
            // never started with the absolute `repoRoot` string and was
            // therefore treated as "outside the repo entirely" and allowed,
            // even when it actually resolved inside the repository working
            // tree. `outInsideRepoNotGitignored`'s associated value still
            // echoes the caller's original (uncanonicalized) `--out` string,
            // since that is what the caller typed and needs to recognize.
            let canonicalOutPath = canonicalizePath(outPath, cwd: cwd)
            guard isPathAllowed(canonicalOutPath, repoRoot: repoRoot, gitignorePatterns: gitignorePatterns) else {
                return .failure(.outInsideRepoNotGitignored(outPath))
            }
            resolvedOutPath = canonicalOutPath
        } else {
            // Default scratch directory (§1) — package-root relative, with a
            // caller-supplied timestamp (`now`, defaulted to `Date()` for
            // production callers, fixed by tests that need determinism), so
            // this stays pure/testable rather than reading the wall clock
            // itself.
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd_HHmmss"
            formatter.timeZone = TimeZone(identifier: "UTC")
            let defaultOutPath = packageRoot + "/.frame-dump-scratch/" + formatter.string(from: now)
            // impl-review-1 HIGH-1 recommendation: apply the same allowlist
            // check to the default path too, so a `packageRoot(startingAt:)`
            // fallback that lands outside the expected `app/Alembic` layout
            // (and therefore outside `gitignorePatterns`' coverage) fails
            // closed instead of silently writing to an unreviewed, possibly
            // committable location.
            let canonicalDefaultOutPath = canonicalizePath(defaultOutPath, cwd: cwd)
            guard isPathAllowed(canonicalDefaultOutPath, repoRoot: repoRoot, gitignorePatterns: gitignorePatterns) else {
                return .failure(.defaultOutPathNotAllowlisted(canonicalDefaultOutPath))
            }
            resolvedOutPath = canonicalDefaultOutPath
        }

        let resolution: ResolutionMode = meetingTitle.map { .meetingTitle($0) } ?? .windowID(windowID!)

        return .success(Plan(
            bundlePrefix: bundlePrefix,
            resolution: resolution,
            frames: framesCount,
            intervalSeconds: intervalSeconds,
            outPath: resolvedOutPath,
            includeImages: includeImages
        ))
    }

    /// Pure: `true` iff `path` is either outside `repoRoot` entirely, or
    /// inside a directory matched by one of `gitignorePatterns` (each a
    /// repo-root-relative directory prefix, e.g.
    /// `"app/Alembic/.frame-dump-scratch/"`). A simplified prefix match, not
    /// a full `.gitignore` glob engine — sufficient for this diagnostic's
    /// own dedicated scratch pattern and any additional explicitly-gitignored
    /// directory a maintainer points `--out` at.
    ///
    /// **Must only ever be called with an already-canonicalized `path`**
    /// (see `canonicalizePath`, below) — this function does a raw string
    /// prefix comparison against `repoRoot` and has no way of knowing
    /// whether an uncanonicalized relative path, a `..`-escape, or a
    /// symlink actually resolves inside or outside `repoRoot` (impl-review-1
    /// HIGH-1).
    package static func isPathAllowed(_ path: String, repoRoot: String, gitignorePatterns: [String]) -> Bool {
        let normalizedRepoRoot = repoRoot.hasSuffix("/") ? String(repoRoot.dropLast()) : repoRoot
        guard path == normalizedRepoRoot || path.hasPrefix(normalizedRepoRoot + "/") else {
            return true // outside the repo entirely
        }
        let relative = String(path.dropFirst(normalizedRepoRoot.count + 1))
        return gitignorePatterns.contains { pattern in
            let normalizedPattern = pattern.hasSuffix("/") ? pattern : pattern + "/"
            return relative == pattern || (relative + "/").hasPrefix(normalizedPattern)
        }
    }

    /// Resolves `path` to an absolute, standardized, symlink-resolved path
    /// (impl-review-1 HIGH-1): a relative `path` is first resolved against
    /// `cwd` — never assumed to already be repo-root-relative or already
    /// absolute — then every `.`/`..` path component is normalized away
    /// (`URL.standardizedFileURL`), then the *longest existing* ancestor
    /// directory of the result is resolved through any symlinks
    /// (`URL.resolvingSymlinksInPath()`), with any still-nonexistent
    /// remainder (e.g. a not-yet-created output directory) appended
    /// unresolved — a path that does not exist yet cannot itself be a
    /// symlink, so there is nothing further to resolve there.
    ///
    /// This closes two bypasses of `isPathAllowed`'s raw string-prefix
    /// comparison: (a) a relative `--out` (e.g. `frame-dump-out`) or a
    /// `..`-escaping `--out` that resolves *inside* `repoRoot` but does not
    /// start with `repoRoot`'s absolute string, previously treated as
    /// "outside the repo entirely" and allowed; (b) a path that traverses a
    /// symlink into (or out of) `repoRoot`, previously compared only as a
    /// literal string against the pre-symlink-resolution path.
    ///
    /// Only reads filesystem existence/symlink metadata — never mutates the
    /// filesystem, never touches TCC/window-server state — so this remains
    /// safe to call from pure tests with fabricated `path`/`cwd` values that
    /// do not exist on disk (in which case no existing prefix is found and
    /// this degrades to plain `.`/`..` normalization with no symlink
    /// resolution, which is exactly correct: a nonexistent path cannot
    /// contain a symlink).
    package static func canonicalizePath(_ path: String, cwd: String) -> String {
        let cwdURL = URL(fileURLWithPath: cwd, isDirectory: true)
        let standardized = URL(fileURLWithPath: path, relativeTo: cwdURL).standardizedFileURL
        let components = standardized.pathComponents
        let fileManager = FileManager.default

        func prefix(upTo count: Int) -> String {
            guard count > 1 else { return "/" }
            return "/" + components[1..<count].joined(separator: "/")
        }

        var existingCount = components.count
        while existingCount > 0, !fileManager.fileExists(atPath: prefix(upTo: existingCount)) {
            existingCount -= 1
        }

        let resolvedPrefix = URL(fileURLWithPath: prefix(upTo: existingCount)).resolvingSymlinksInPath().path
        guard existingCount < components.count else { return resolvedPrefix }

        let remainder = components[existingCount...].joined(separator: "/")
        return resolvedPrefix.hasSuffix("/") ? resolvedPrefix + remainder : resolvedPrefix + "/" + remainder
    }

    /// Walks up from `startingAt` looking for the nearest ancestor directory
    /// containing `Package.swift` — the Swift package root, resolved at
    /// runtime rather than hardcoded, so this diagnostic works correctly
    /// regardless of the shell's current directory at invocation time (§1).
    /// Returns `nil` if no such ancestor exists.
    package static func packageRoot(startingAt: String) -> String? {
        var directory = URL(fileURLWithPath: startingAt, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while true {
            let candidate = directory.appendingPathComponent("Package.swift")
            if fileManager.fileExists(atPath: candidate.path) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    // MARK: - Live glue (not independently pure-testable — TCC/window-server/capture)

    static func run(arguments: [String]) async {
        let packageRootPath = packageRoot(startingAt: FileManager.default.currentDirectoryPath)
            ?? FileManager.default.currentDirectoryPath
        // Best-effort repo root: walk up from the package root looking for
        // `.git` — falls back to the package root itself (never crashes) if
        // this diagnostic is ever run from outside a git checkout.
        let repoRootPath = gitRoot(startingAt: packageRootPath) ?? packageRootPath
        let gitignorePatterns = ["app/Alembic/.frame-dump-scratch/"]

        switch validate(
            arguments: arguments,
            packageRoot: packageRootPath,
            repoRoot: repoRootPath,
            gitignorePatterns: gitignorePatterns
        ) {
        case .failure(let error):
            print("frame-dump: \(describe(error))")
            exit(1)
        case .success(let plan):
            await execute(plan: plan)
        }
    }

    private static func gitRoot(startingAt: String) -> String? {
        var directory = URL(fileURLWithPath: startingAt, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while true {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return directory.path
            }
            let parent = directory.deletingLastPathComponent()
            guard parent.path != directory.path else { return nil }
            directory = parent
        }
    }

    private static func describe(_ error: ValidationError) -> String {
        switch error {
        case .missingPositiveEvidence:
            return "requires --meeting-title, --window-id, or --list-windows to resolve which window to capture; run with --list-windows to discover candidates"
        case .ambiguousPositiveEvidence:
            return "pass only one of --meeting-title or --window-id, not both"
        case .listWindowsMutuallyExclusive:
            return "--list-windows cannot be combined with --meeting-title, --window-id, --frames, --interval, --out, or --include-images"
        case .includeImagesRequiresExplicitOut:
            return "--include-images requires an explicit --out <path outside the repo, or under a gitignored diagnostics directory> — there is no default output location for image output"
        case .outInsideRepoNotGitignored(let path):
            return "--out \(path) is inside the repository and not gitignored; use --out <path outside the repo> or a path under a dedicated gitignored diagnostics directory"
        case .invalidFramesCount(let value):
            return "--frames \(value) is not a positive integer"
        case .invalidInterval(let value):
            return "--interval \(value) is not a non-negative number"
        case .invalidWindowID(let value):
            return "--window-id \(value) is not a valid CGWindowID"
        case .missingValueForFlag(let flag):
            return "\(flag) requires a value"
        case .unknownFlag(let flag):
            return "unrecognized flag \"\(flag)\" — see the frame-dump usage comment atop FrameDumpProbe.swift for supported flags"
        case .multipleBundlePrefixes(let first, let second):
            return "multiple bundle-prefix arguments supplied (\"\(first)\" and \"\(second)\") — pass only one"
        case .defaultOutPathNotAllowlisted(let path):
            return "internal error: default output path \(path) did not resolve under a gitignored diagnostics directory; pass an explicit --out"
        }
    }

    /// Same trust/precondition guard as `ax-dump`, restricted to Screen
    /// Recording only, run only after `validate(...)` above already
    /// succeeded.
    private static func execute(plan: Plan) async {
        guard CapturePreflight.screenRecordingStatus() == .authorized else {
            print("""
            frame-dump: this process is not authorized for Screen Recording.
            Grant your terminal app access in System Settings → Privacy & Security → Screen Recording, then re-run.
            """)
            exit(1)
        }

        switch plan.resolution {
        case .listWindows:
            await runListWindows(bundlePrefix: plan.bundlePrefix)
        case .meetingTitle(let title):
            await runCapture(plan: plan, expectedMeetingTitle: title, explicitWindowID: nil)
        case .windowID(let id):
            await runCapture(plan: plan, expectedMeetingTitle: nil, explicitWindowID: id)
        }
    }

    private static func runListWindows(bundlePrefix: String) async {
        do {
            let windows = try DiagnosticVideoCapture.listWindows(bundlePrefix: bundlePrefix)
            guard !windows.isEmpty else {
                print("frame-dump --list-windows: no on-screen window matches bundle prefix \"\(bundlePrefix)\"")
                return
            }
            print("frame-dump --list-windows: \(windows.count) candidate(s) for \"\(bundlePrefix)\"")
            for window in windows {
                print("  windowID=\(window.windowID) owner=\"\(window.ownerName)\" title=\"\(window.title)\"")
            }
        } catch {
            print("frame-dump --list-windows: \(error)")
            exit(1)
        }
    }

    private static func runCapture(plan: Plan, expectedMeetingTitle: String?, explicitWindowID: UInt32?) async {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(atPath: plan.outPath, withIntermediateDirectories: true)
        } catch {
            print("frame-dump: could not create output directory \(plan.outPath): \(error)")
            exit(1)
        }

        print("""
        ⚠️  This tool may capture real meeting participant names, faces, and on-screen content.
            Do not commit or share files under \(plan.outPath) without reviewing/redacting them.
        """)

        // `captureFrames` owns `start()`/`stop()` internally — it is
        // guaranteed to tear down the underlying `SCStream` before
        // returning or throwing, whether this call succeeds, fails, times
        // out waiting for a first/next frame, or is cancelled (Phase 7
        // impl-review-1 MEDIUM-1). No manual teardown call on `capture` is
        // needed (or possible to forget) here.
        let capture = DiagnosticVideoCapture()
        let frames: [CapturedFrame]
        do {
            frames = try await capture.captureFrames(
                bundlePrefix: plan.bundlePrefix,
                expectedMeetingTitle: expectedMeetingTitle,
                explicitWindowID: explicitWindowID,
                intervalSeconds: plan.intervalSeconds,
                count: plan.frames
            )
        } catch {
            print("frame-dump: capture failed: \(error)")
            exit(1)
        }

        var writtenFiles: [(path: String, sensitive: Bool)] = []

        for (offset, frame) in frames.enumerated() {
            let frameIndex = offset + 1

            let report = await FrameReport.render(frame: frame, catalogEntry: SpeakerLabelCatalog.teamsDefaults)
            let textPath = plan.outPath + "/frame-\(frameIndex).txt"
            do {
                try report.write(toFile: textPath, atomically: true, encoding: .utf8)
                writtenFiles.append((path: textPath, sensitive: true))
            } catch {
                print("frame-dump: could not write \(textPath): \(error)")
            }

            if plan.includeImages {
                let imagePath = plan.outPath + "/frame-\(frameIndex).png"
                if writeBGRAPNG(frame: frame, to: imagePath) {
                    writtenFiles.append((path: imagePath, sensitive: true))
                } else {
                    print("frame-dump: could not write \(imagePath)")
                }
            }
        }

        do {
            try writeManifest(
                outPath: plan.outPath,
                bundlePrefix: plan.bundlePrefix,
                includeImages: plan.includeImages,
                files: writtenFiles
            )
        } catch {
            print("frame-dump: could not write sensitive-data manifest: \(error)")
            exit(1)
        }

        print("frame-dump: \(frames.count) frame(s) captured; written to \(plan.outPath)")
        if !writtenFiles.isEmpty {
            print("⚠️  Sensitive data warning: files under \(plan.outPath) may contain real meeting participant names/content — do not commit or share them.")
        }
    }

    private static func writeManifest(
        outPath: String,
        bundlePrefix: String,
        includeImages: Bool,
        files: [(path: String, sensitive: Bool)]
    ) throws {
        let manifest: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "bundlePrefix": bundlePrefix,
            "includeImages": includeImages,
            "files": files.map { ["path": $0.path, "sensitive": $0.sensitive] }
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: outPath + "/manifest.json"), options: .atomic)
    }

    /// Writes `frame`'s raw BGRA pixels as a PNG via CoreGraphics/ImageIO —
    /// diagnostic-only code, exactly like `AXDumpProbe` importing
    /// `ApplicationServices`/`AppKit`. Only ever called when
    /// `plan.includeImages == true`.
    private static func writeBGRAPNG(frame: CapturedFrame, to path: String) -> Bool {
        guard let provider = CGDataProvider(data: frame.pixelData as CFData) else { return false }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue)
        guard let cgImage = CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else { return false }

        guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination)
    }
}

// MARK: - Frame report rendering (OCR + catalogued regions + marker colors)

private enum FrameReport {
    static func render(frame: CapturedFrame, catalogEntry: SpeakerLabelCatalog.AppEntry) async -> String {
        var report = "frame-dump report — \(Date())\n"
        report += "frame: width=\(frame.width) height=\(frame.height) bytesPerRow=\(frame.bytesPerRow) sessionTime=\(frame.sessionTime)\n\n"

        report += "=== OCR (whole frame) ===\n"
        for observation in await ocrObservations(frame: frame) {
            report += "  text=\"\(observation.text)\" confidence=\(observation.confidence) box=\(observation.box)\n"
        }

        report += "\n=== Catalogued candidates (\(catalogEntry.displayName)) ===\n"
        for (index, candidate) in catalogEntry.candidates.enumerated() {
            guard let tilePixelRect = VisionSpeakerAttributor.pixelRect(
                for: candidate.tileRegion, frameWidth: frame.width, frameHeight: frame.height
            ) else { continue }
            guard let labelPixelRect = VisionSpeakerAttributor.pixelRect(
                for: candidate.labelRegion, frameWidth: frame.width, frameHeight: frame.height
            ) else { continue }
            report += "  candidate[\(index)] tileRegion(px)=\(tilePixelRect) labelRegion(px)=\(labelPixelRect)\n"
            for (markerIndex, marker) in candidate.activeTileMarkers.enumerated() {
                guard let markerPixelRect = VisionSpeakerAttributor.pixelRect(
                    forTileRelative: marker.region, tileRegion: candidate.tileRegion,
                    frameWidth: frame.width, frameHeight: frame.height
                ) else { continue }
                let sampled = VisionSpeakerAttributor.croppedBGRA(
                    from: frame.pixelData, frameWidth: frame.width, frameHeight: frame.height,
                    bytesPerRow: frame.bytesPerRow, rect: markerPixelRect
                ).flatMap {
                    VisionSpeakerAttributor.averageBGRAColor(data: $0.data, width: $0.width, height: $0.height, bytesPerRow: $0.bytesPerRow)
                }
                if let sampled {
                    let sampledHex = String(format: "#%02X%02X%02X", Int(sampled.r * 255), Int(sampled.g * 255), Int(sampled.b * 255))
                    report += "    marker[\(markerIndex)] region(px)=\(markerPixelRect) expected=\(marker.hexColor) sampled=\(sampledHex) tolerance=\(marker.colorTolerance)\n"
                } else {
                    report += "    marker[\(markerIndex)] region(px)=\(markerPixelRect) expected=\(marker.hexColor) sampled=<unavailable>\n"
                }
            }
        }
        return report
    }

    private struct Observation {
        let text: String
        let confidence: Double
        /// Top-left-origin unit-rect description, converted from Vision's
        /// bottom-left-origin convention (`RecognizedTextObservation.
        /// boundingBox`, a `NormalizedRect` whose `origin` is its bottom-left
        /// corner) — `1 - origin.y - height` flips the origin so this
        /// report's coordinates match `SpeakerLabelCatalog.UnitRect`'s
        /// convention used throughout the rest of this codebase. This
        /// conversion is the single most likely spot for an axis-flip bug in
        /// any future edit here — verify against a real capture before
        /// trusting new geometry derived from this report.
        let box: String
    }

    private static func ocrObservations(frame: CapturedFrame) async -> [Observation] {
        guard let provider = CGDataProvider(data: frame.pixelData as CFData) else { return [] }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGImageByteOrderInfo.order32Little.rawValue)
        guard let cgImage = CGImage(
            width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ) else { return [] }

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate

        guard let results = try? await request.perform(on: cgImage) else { return [] }
        return results.compactMap { observation -> Observation? in
            guard let top = observation.topCandidates(1).first else { return nil }
            let raw = observation.boundingBox
            // Vision's `NormalizedRect.origin` is the rect's bottom-left
            // corner in a bottom-left-origin, unit-normalized space;
            // `1 - origin.y - height` flips it to this codebase's
            // top-left-origin convention (`SpeakerLabelCatalog.UnitRect`).
            let topLeftY = 1 - raw.origin.y - raw.height
            let box = "x=\(raw.origin.x) y=\(topLeftY) w=\(raw.width) h=\(raw.height)"
            return Observation(text: top.string, confidence: Double(top.confidence), box: box)
        }.sorted { lhs, rhs in lhs.box < rhs.box } // stable-ish ordering; exact sort is cosmetic only
    }
}
