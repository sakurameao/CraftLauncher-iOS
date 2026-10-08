import Foundation

/// A Java runtime the launcher can use.
///
/// Runtimes live **inside the app bundle**, at
/// `<App.app>/java_runtimes/<tag>/`. They are not installed at runtime: shipping
/// them in the bundle means they are covered by the app's own code signature, so a
/// certificate-based re-signer handles them automatically and no on-device signing
/// is needed.
///
/// They are trimmed builds. Verified against the real upstream IPA:
///
/// * there is **no `bin/` directory at all** — no `bin/java` executable exists,
/// * Java 8 keeps `libjli` in `lib/jli/`, Java 9+ keeps it in `lib/`,
/// * each already has `lib/awt_xawt.dylib`, so no symlink juggling is required.
///
/// The JVM is started by `dlopen`-ing `libjli.dylib` and calling `JLI_Launch`,
/// which is why the missing `bin/java` does not matter.
struct JavaRuntime: Identifiable, Equatable {
    /// Directory name under `java_runtimes/`. Doubles as the identity.
    let tag: String
    /// Absolute path to the runtime root, e.g. `<App>/java_runtimes/java-17-openjdk`.
    let home: URL
    /// From the runtime's own `release` file, e.g. `17.0.8` or `1.8.0`.
    let version: String
    let majorVersion: Int
    let architecture: String
    let vendor: String

    /// Where `bootstrap-runtime.sh` writes them, and where the app looks.
    static let bundleDirectoryName = "java_runtimes"
    static let releaseFileName = "release"

    var id: String { tag }

    var displayName: String {
        "Java \(majorVersion) · \(version)"
    }

    /// `libjli.dylib`, whose location moved between Java 8 and Java 9+.
    ///
    /// `JLI_Launch` is resolved from this library by `RuntimeBridge.mm`; getting the
    /// path wrong is an immediate launch failure with a bare dlopen error.
    var libjli: URL {
        majorVersion <= 8
            ? home.appendingPathComponent("lib/jli/libjli.dylib")
            : home.appendingPathComponent("lib/libjli.dylib")
    }

    /// `lib/server/libjvm.dylib`, loaded by `libjli` itself once it is running.
    var libjvm: URL {
        home.appendingPathComponent("lib/server/libjvm.dylib")
    }

    /// The AWT shim, loaded by `libawt.dylib` during AWT initialisation.
    ///
    /// Filename verified against the extracted runtime: `lib/libawt_xawt.dylib`
    /// (58,832 bytes). Note the leading `lib` — it is *not* `awt_xawt.dylib`.
    /// Present in both bundled runtimes, so unlike the original design there is
    /// nothing to symlink into place.
    var libawtXawt: URL {
        home.appendingPathComponent("lib/libawt_xawt.dylib")
    }

    /// A runtime is usable when both `libjli` and `libjvm` are on disk. Checking
    /// only one would let a half-extracted runtime through, and the failure would
    /// then happen inside the JVM where it cannot be explained to the user.
    var isUsable: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: libjli.path) && fm.fileExists(atPath: libjvm.path)
    }

    /// A one-line reason the runtime cannot be used, for the diagnostics screen.
    var unusableReason: String? {
        guard !isUsable else { return nil }
        let fm = FileManager.default
        if !fm.fileExists(atPath: home.path) { return "运行时目录不存在" }
        if !fm.fileExists(atPath: libjli.path) { return "缺少 libjli.dylib" }
        if !fm.fileExists(atPath: libjvm.path) { return "缺少 libjvm.dylib" }
        return "运行时文件不完整"
    }

    // MARK: - Discovery

    /// Runtime root inside the app bundle.
    static var bundleRuntimesDirectory: URL {
        Bundle.main.bundleURL
            .appendingPathComponent(bundleDirectoryName, isDirectory: true)
    }

    /// Inspects one runtime directory.
    ///
    /// Returns nil when the directory does not exist. A directory that exists but
    /// has no readable `release` file is still returned, with the version inferred
    /// from the tag: a partially copied runtime is worth showing in the UI — so the
    /// user can see *why* a version refuses to launch — rather than hiding.
    static func inspect(tag: String, home: URL) -> JavaRuntime? {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: home.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }

        let releaseFile = home.appendingPathComponent(releaseFileName)
        if let text = try? String(contentsOf: releaseFile, encoding: .utf8),
           let parsed = JavaReleaseFile.parse(contents: text) {
            return JavaRuntime(
                tag: tag,
                home: home,
                version: parsed.version,
                majorVersion: parsed.majorVersion,
                architecture: parsed.architecture,
                vendor: parsed.vendor
            )
        }

        return JavaRuntime(
            tag: tag,
            home: home,
            version: "未知",
            majorVersion: RuntimeTag.major(for: tag),
            architecture: RuleEnvironment.hostArch,
            vendor: "未知"
        )
    }
}

/// Details parsed out of a runtime's `release` file, which every OpenJDK build
/// ships next to `lib/`.
///
/// Real examples from the bundled runtimes:
///
///     JAVA_VERSION="17.0.8"   OS_ARCH="aarch64"   IMPLEMENTOR="N/A"
///     JAVA_VERSION="1.8.0"    OS_ARCH="aarch64"
struct JavaReleaseFile {
    let version: String
    let majorVersion: Int
    let architecture: String
    let vendor: String

    /// Parses the `KEY="value"` lines of a JDK `release` file.
    static func parse(contents: String) -> JavaReleaseFile? {
        var fields: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            fields[key] = value
        }

        guard let javaVersion = fields["JAVA_VERSION"] ?? fields["JAVA_RUNTIME_VERSION"] else {
            return nil
        }

        return JavaReleaseFile(
            version: javaVersion,
            majorVersion: inferMajor(from: javaVersion),
            architecture: fields["OS_ARCH"] ?? RuleEnvironment.hostArch,
            // Both bundled runtimes report `IMPLEMENTOR="N/A"`, so fall back to a
            // meaningful label rather than showing "N/A" in the UI.
            vendor: normaliseVendor(fields["IMPLEMENTOR"] ?? fields["JAVA_VENDOR"])
        )
    }

    private static func normaliseVendor(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty, raw != "N/A", raw != "null" else {
            return "OpenJDK"
        }
        return raw
    }

    /// Java version strings come in three shapes and each needs a different rule:
    ///
    /// * `1.8.0` or `1.8.0_402` — legacy: the major is the **second** component (8)
    /// * `17.0.8` — modern: the major is the **first** component (17)
    /// * `21` — a bare major
    ///
    /// Reading `1.8.0` as major 1 would make the launcher demand Java 1 for every
    /// legacy version.
    private static func inferMajor(from version: String) -> Int {
        let cleaned = version.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        // `1.8.0_402` — the underscore part is a build number, not a version field.
        let parts = cleaned.split(separator: ".").map { String($0).split(separator: "_")[0] }

        guard let first = parts.first, let firstNumber = Int(first) else { return 8 }

        if firstNumber == 1, parts.count >= 2, let second = Int(parts[1]) {
            return second
        }
        return firstNumber
    }
}
