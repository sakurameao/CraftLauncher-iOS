import Foundation
import Combine

/// Discovers and selects Java runtimes.
///
/// The runtimes are **read directly from the app bundle** at
/// `<App.app>/java_runtimes/<tag>/`. Nothing is extracted or installed at runtime.
///
/// That is a deliberate reversal of the original design, which unpacked them into
/// the Documents container on first launch. Two reasons:
///
/// 1. **Code signing.** Files inside the bundle are covered by the app's own
///    signature, so a certificate-based re-signer (全能签 and similar) handles them
///    automatically. Files extracted to Documents at runtime are *not* signed, and
///    iOS refuses to `dlopen` an unsigned dylib — the launcher would have had to
///    implement ad-hoc Mach-O signing on-device, which cannot be tested without a
///    real device and fails catastrophically when it fails.
/// 2. **The runtimes have no `bin/` directory.** They are trimmed builds meant to
///    be started by `dlopen`-ing `libjli.dylib`, so there was never a binary to
///    make executable in the first place.
///
/// The cost is bundle size: roughly 300–400 MB, because two complete OpenJDKs ship
/// inside the app.
@MainActor
final class JavaRuntimeManager: ObservableObject {
    static let shared = JavaRuntimeManager()

    /// Runtimes found in the bundle, oldest first.
    @Published private(set) var runtimes: [JavaRuntime] = []

    private let fm = FileManager.default

    private init() {}

    // MARK: - Discovery

    /// Scans the bundle for runtimes. Cheap enough to call on every screen appear.
    func refresh() {
        var found: [JavaRuntime] = []
        var seen = Set<String>()

        // 1. Runtimes the launcher knows about, in Java-version order, so the list
        //    is deterministic. Checked in the bundle first, then in the writable
        //    container where imported runtimes live.
        for tag in RuntimeTag.all {
            for root in [JavaRuntime.bundleRuntimesDirectory, Self.importedRuntimesDirectory] {
                let home = root.appendingPathComponent(tag, isDirectory: true)
                if let runtime = JavaRuntime.inspect(tag: tag, home: home) {
                    found.append(runtime)
                    seen.insert(tag)
                    break
                }
            }
        }

        // 2. Anything else in either directory. Without this a re-tagged upstream
        //    build, or an imported runtime with an unfamiliar name, would be
        //    silently invisible.
        for root in [JavaRuntime.bundleRuntimesDirectory, Self.importedRuntimesDirectory] {
            let entries = (try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for entry in entries where !seen.contains(entry.lastPathComponent) {
                if let runtime = JavaRuntime.inspect(tag: entry.lastPathComponent, home: entry) {
                    found.append(runtime)
                    seen.insert(entry.lastPathComponent)
                }
            }
        }

        runtimes = found.sorted { $0.majorVersion < $1.majorVersion }
        reportStatus()
    }

    private func reportStatus() {
        guard !runtimes.isEmpty else {
            LogConsole.shared.error(
                "App 包内没有找到任何 Java 运行时。请运行 Scripts/bootstrap-runtime.sh 后重新构建。"
            )
            return
        }

        let summary = runtimes.map { "\($0.tag)(Java \($0.majorVersion), \($0.version))" }
            .joined(separator: "、")
        LogConsole.shared.info("已发现 \(runtimes.count) 个 Java 运行时：\(summary)")

        for runtime in runtimes where !runtime.isUsable {
            LogConsole.shared.warning(
                "运行时 \(runtime.tag) 不可用：\(runtime.unusableReason ?? "未知原因")。App 包可能不完整。"
            )
        }
    }

    // MARK: - Selection

    /// Picks the runtime to use for a version requiring `requiredMajor`.
    ///
    /// Priority: an explicit lock from Settings, then the user's preferred runtime
    /// when it satisfies the requirement, then the **smallest** sufficient runtime.
    ///
    /// Never returns the newest by default. Minecraft 1.17 through 1.20.4 break on
    /// Java 21+, so "use the newest" would turn a working setup into a crash the
    /// moment a newer runtime is added to the bundle.
    ///
    /// Returns nil when nothing is new enough — a real outcome, not an error case
    /// to paper over: Minecraft 1.20.5+ needs Java 21, which has no publicly
    /// obtainable iOS build. See `docs/JAVA-RUNTIMES.md`.
    func runtime(
        requiredMajor: Int,
        preferredMajor: Int? = nil,
        overrideTag: String? = nil
    ) -> JavaRuntime? {
        // 1. Explicit lock from Settings. Honoured even if it looks wrong, because
        //    the user may be deliberately testing a specific runtime.
        if let overrideTag, let exact = runtimes.first(where: { $0.tag == overrideTag }) {
            return exact
        }

        // 2. User preference, when it satisfies the requirement.
        if let preferredMajor, preferredMajor >= requiredMajor {
            if let preferred = runtimes.first(where: { $0.majorVersion == preferredMajor }) {
                return preferred
            }
        }

        // 3. Smallest sufficient runtime.
        return runtimes
            .filter { $0.majorVersion >= requiredMajor && $0.isUsable }
            .min { $0.majorVersion < $1.majorVersion }
    }

    func runtime(tag: String) -> JavaRuntime? {
        runtimes.first { $0.tag == tag }
    }

    /// Highest Java version available in the bundle.
    var newestMajor: Int? {
        runtimes.map(\.majorVersion).max()
    }

    /// Whether the bundle can satisfy a requirement at all.
    func canSatisfy(requiredMajor: Int) -> Bool {
        runtime(requiredMajor: requiredMajor) != nil
    }

    // MARK: - Imported runtimes
    //
    // An imported JDK is the only reason anything is still written to disk at
    // runtime. It is a niche path — for a differently-built OpenJDK — and the
    // extracted copy is unsigned, so it only works when library validation is
    // disabled. That is stated plainly in the UI rather than left as a surprise.

    /// Imports a JDK zip into the writable container and registers it.
    func importRuntime(from zipURL: URL) async throws -> JavaRuntime {
        let tag = sanitizeTag(zipURL.deletingPathExtension().lastPathComponent)
        guard !tag.isEmpty else {
            throw LauncherError.unsupportedArchive(zipURL.lastPathComponent)
        }
        guard !RuntimeTag.all.contains(tag) else {
            throw LauncherError.runtimeCorrupt(
                tag: tag,
                detail: "这个标签已经被内置的运行占用了，请改个文件名"
            )
        }

        let destination = Self.importedRuntimesDirectory.appendingPathComponent(tag, isDirectory: true)

        // A security-scoped resource is required for anything outside the sandbox.
        let scoped = zipURL.startAccessingSecurityScopedResource()
        defer { if scoped { zipURL.stopAccessingSecurityScopedResource() } }

        guard let extractor = ZipExtractor(url: zipURL) else {
            throw LauncherError.unsupportedArchive(zipURL.lastPathComponent)
        }

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }

        // JDK archives wrap everything in a single top-level directory; strip it.
        _ = try extractor.extractAll(to: destination, stripLeadingComponent: true)
        LauncherPath.ensureDirectory(destination)

        refresh()
        guard let runtime = runtimes.first(where: { $0.tag == tag }) else {
            throw LauncherError.runtimeCorrupt(tag: tag, detail: "解压后找不到运行时库")
        }
        LogConsole.shared.info("已导入运行时 \(runtime.displayName)（\(tag)）。")
        return runtime
    }

    @discardableResult
    func removeImportedRuntime(tag: String) -> Int64 {
        guard !RuntimeTag.all.contains(tag) else { return 0 }
        let dir = Self.importedRuntimesDirectory.appendingPathComponent(tag, isDirectory: true)
        let size = FileUtil.directorySize(dir)
        try? fm.removeItem(at: dir)
        refresh()
        return size
    }

    /// Where imported runtimes are written. Kept outside the bundle, which is
    /// read-only.
    static var importedRuntimesDirectory: URL {
        LauncherPath.launcherRoot.appendingPathComponent("runtimes", isDirectory: true)
    }

    /// True when the path points at an imported runtime rather than a bundled one.
    func isImported(_ runtime: JavaRuntime) -> Bool {
        runtime.home.path.hasPrefix(Self.importedRuntimesDirectory.path)
    }

    /// Rejects path separators so an imported archive name cannot escape its
    /// directory.
    private func sanitizeTag(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Storage accounting

    /// Bytes the bundled runtimes occupy. Mostly informational: they are part of
    /// the app and cannot be reclaimed without rebuilding.
    func bundledSize() -> Int64 {
        FileUtil.directorySize(JavaRuntime.bundleRuntimesDirectory)
    }

    func importedSize() -> Int64 {
        FileUtil.directorySize(Self.importedRuntimesDirectory)
    }
}
