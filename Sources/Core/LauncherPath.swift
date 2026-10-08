import Foundation

/// Every filesystem location the launcher touches, in one place.
///
/// The layout deliberately mirrors what the JVM-side runtime expects, because
/// `-Duser.home` is pointed at `launcherRoot` and the game derives
/// `<user.home>/.minecraft` style paths from it internally:
///
///     launcherRoot/
///     ├── instances/<name>/          one game directory per profile
///     │   ├── mods/  saves/  resourcepacks/  shaderpacks/  config/
///     │   └── options.txt  servers.dat
///     ├── versions/<id>/             version json + client jar
///     ├── libraries/                 maven-layout jars
///     ├── assets/
///     │   ├── indexes/<id>.json
///     │   └── objects/<ab>/<hash>    content-addressed, like the official launcher
///     └── runtimes/<tag>/            extracted OpenJDK, contains bin/java
///
/// `launcherRoot` is the value handed to the JVM as `POJAV_HOME`.
enum LauncherPath {
    private static let fm = FileManager.default

    /// Substituted when the user's chosen home is no longer writable (for example
    /// after they delete the folder from Files.app while the app is backgrounded).
    private static let defaultHomeName = "CraftLauncher"

    // MARK: - Root

    /// The launcher home directory. Always exists and is always writable when read.
    static var launcherRoot: URL {
        if let custom = UserDefaults.standard.string(forKey: PrefKey.launcherHome),
           !custom.isEmpty {
            let url = URL(fileURLWithPath: custom, isDirectory: true)
            if ensureDirectory(url) { return url }
            // Stored path went away; fall back rather than crashing every code path.
            LogConsole.shared.append(
                .warning,
                "Configured launcher home \(custom) is not writable, falling back to Documents."
            )
            UserDefaults.standard.removeObject(forKey: PrefKey.launcherHome)
        }
        let url = documents.appendingPathComponent(defaultHomeName, isDirectory: true)
        _ = ensureDirectory(url)
        return url
    }

    private static var documents: URL {
        // On iOS this always resolves; the fallback keeps the code compiling and
        // sane under unit tests.
        fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
    }

    // MARK: - Top level

    static var instances: URL { launcherRoot.appendingPathComponent("instances", isDirectory: true) }
    static var versions: URL { launcherRoot.appendingPathComponent("versions", isDirectory: true) }
    static var libraries: URL { launcherRoot.appendingPathComponent("libraries", isDirectory: true) }
    static var assets: URL { launcherRoot.appendingPathComponent("assets", isDirectory: true) }
    static var assetIndexes: URL { assets.appendingPathComponent("indexes", isDirectory: true) }
    static var assetObjects: URL { assets.appendingPathComponent("objects", isDirectory: true) }
    static var runtimes: URL { launcherRoot.appendingPathComponent("runtimes", isDirectory: true) }
    static var nativesRoot: URL { launcherRoot.appendingPathComponent("natives", isDirectory: true) }
    static var cache: URL { launcherRoot.appendingPathComponent("cache", isDirectory: true) }
    static var logs: URL { launcherRoot.appendingPathComponent("logs", isDirectory: true) }

    /// `launcher_profiles.json` lives here, matching the official launcher layout.
    static var launcherProfiles: URL { launcherRoot.appendingPathComponent("launcher_profiles.json") }
    static var versionManifestCache: URL { cache.appendingPathComponent("version_manifest_v2.json") }
    static var accountsFile: URL { launcherRoot.appendingPathComponent("accounts.json") }
    static var settingsFile: URL { launcherRoot.appendingPathComponent("settings.json") }
    static var consoleLog: URL { logs.appendingPathComponent("console.log") }
    static var crashReports: URL { launcherRoot.appendingPathComponent("crash-reports", isDirectory: true) }

    // MARK: - Instance scoped

    static func instance(_ name: String) -> URL {
        instances.appendingPathComponent(sanitize(name), isDirectory: true)
    }

    static func modsDir(instance name: String) -> URL { under(name, "mods") }
    static func modsDisabledDir(instance name: String) -> URL { under(name, "mods.disabled") }
    static func resourcePacksDir(instance name: String) -> URL { under(name, "resourcepacks") }
    static func shaderPacksDir(instance name: String) -> URL { under(name, "shaderpacks") }
    static func savesDir(instance name: String) -> URL { under(name, "saves") }
    static func configDir(instance name: String) -> URL { under(name, "config") }

    /// Extracted LWJGL/native `.dylib`s for a single launch. Passed to the JVM as
    /// `-Djava.library.path`.
    static func nativesDir(instance: String) -> URL {
        nativesRoot.appendingPathComponent(sanitize(instance), isDirectory: true)
    }

    /// Version metadata + client jar.
    static func versionDir(_ versionId: String) -> URL {
        versions.appendingPathComponent(sanitize(versionId), isDirectory: true)
    }

    static func versionJSON(_ versionId: String) -> URL {
        versionDir(versionId).appendingPathComponent("\(sanitize(versionId)).json")
    }

    static func versionJar(_ versionId: String) -> URL {
        versionDir(versionId).appendingPathComponent("\(sanitize(versionId)).jar")
    }

    static func assetIndex(_ id: String) -> URL {
        assetIndexes.appendingPathComponent("\(sanitize(id)).json")
    }

    static func runtime(_ tag: String) -> URL {
        runtimes.appendingPathComponent(sanitize(tag), isDirectory: true)
    }

    /// Maven-layout destination for a library artifact, e.g.
    /// `libraries/org/lwjgl/lwjgl/3.4.3/lwjgl-3.4.3.jar`.
    static func library(_ mavenPath: String) -> URL {
        libraries.appendingPathComponent(mavenPath)
    }

    /// Content-addressed asset object: `objects/ab/abcdef....`.
    static func assetObject(hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return assetObjects
            .appendingPathComponent(prefix, isDirectory: true)
            .appendingPathComponent(hash)
    }

    // MARK: - Helpers

    @discardableResult
    static func ensureDirectory(_ url: URL) -> Bool {
        if fm.fileExists(atPath: url.path) { return fm.isWritableFile(atPath: url.path) }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// Creates every directory the launcher expects. Cheap and idempotent, so it is
    /// safe to call on each launch and after the user relocates the home directory.
    static func bootstrapDirectoryTree() {
        let dirs: [URL] = [
            launcherRoot, instances, versions, libraries, assets,
            assetIndexes, assetObjects, runtimes, nativesRoot, cache, logs, crashReports,
        ]
        var failed: [String] = []
        for dir in dirs where !ensureDirectory(dir) {
            failed.append(dir.lastPathComponent)
        }
        if !failed.isEmpty {
            LogConsole.shared.append(
                .error,
                "Could not create directories: \(failed.joined(separator: ", "))"
            )
        }
    }

    /// Strips path separators and traversal so a profile name can never escape the
    /// instances directory.
    static func sanitize(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "default" : cleaned
    }

    private static func under(_ instanceName: String, _ child: String) -> URL {
        instance(instanceName).appendingPathComponent(child, isDirectory: true)
    }
}

/// UserDefaults keys, centralised so a typo is a compile error rather than a
/// silently-ignored setting.
enum PrefKey {
    static let launcherHome = "launcher.home"
    static let activeInstance = "launcher.activeInstance"
    static let selectedVersion = "launcher.selectedVersion"
    static let selectedAccount = "launcher.selectedAccount"
    static let javaAllocatedMemory = "java.allocatedMemoryMB"
    static let javaAutoMemory = "java.autoMemory"
    static let javaPreferredVersion = "java.preferredVersion"
    static let javaCustomArgs = "java.customArgs"
    static let javaEnvVars = "java.envVars"
    static let javaSelectedRuntime = "java.selectedRuntime"
    static let rendererBackend = "renderer.backend"
    static let rendererResolutionScale = "renderer.resolutionScale"
    static let generalCheckAssets = "general.verifyAssets"
    static let generalMaxConcurrentDownloads = "general.maxConcurrentDownloads"
    static let generalCloseConsoleOnLaunch = "general.closeConsoleOnLaunch"
}
