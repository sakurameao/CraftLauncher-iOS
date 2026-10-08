import Foundation

/// A single file the launcher needs on disk.
struct DownloadItem: Sendable {
    let remoteURL: URL
    let destination: URL
    let sha1: String?
    let size: Int?
    /// Shown in the progress UI, e.g. `lwjgl-3.4.3.jar`.
    let label: String
}

/// Everything a launch or install needs, resolved up front.
struct DownloadPlan: Sendable {
    var libraries: [DownloadItem] = []
    var assets: [DownloadItem] = []
    var clientJar: DownloadItem?
    /// The Log4j configuration Mojang serves for this version, when it is not one
    /// of the two the launcher patches itself. Small, but without it the game falls
    /// back to its built-in logging and the console shows a different format.
    var log4jConfig: DownloadItem?
    /// Legacy asset indexes need their objects mirrored into a virtual tree.
    var legacyAssetMapping: [(hash: String, relativePath: String)] = []

    var totalFiles: Int {
        libraries.count + assets.count
            + (clientJar == nil ? 0 : 1)
            + (log4jConfig == nil ? 0 : 1)
    }

    var totalBytes: Int64 {
        Int64((libraries + assets).reduce(0) { $0 + ($1.size ?? 0) }
            + (clientJar?.size ?? 0)
            + (log4jConfig?.size ?? 0))
    }
}

/// Progress for a batch download.
struct DownloadProgress: Sendable {
    let completed: Int
    let total: Int
    let currentLabel: String

    var fraction: Double {
        total == 0 ? 1 : Double(completed) / Double(total)
    }
}

/// Turns a resolved version into a concrete download plan and executes it.
final class ResourceDownloader {
    static let shared = ResourceDownloader()

    private let fm = FileManager.default

    // MARK: - Plan

    /// Works out exactly which files are missing.
    ///
    /// Files already present with the correct SHA-1 are excluded, which is what
    /// makes a second launch of the same version take seconds instead of minutes.
    func plan(
        version: MinecraftVersion,
        assetIndex: AssetIndex,
        instanceName: String,
        environment: RuleEnvironment = .current,
        verifyAssets: Bool = true
    ) -> DownloadPlan {
        var plan = DownloadPlan()

        for library in applicableLibraries(from: version, environment: environment) {
            guard let artifact = library.downloads?.artifact else { continue }
            let destination = LauncherPath.library(artifact.path)
            if isUpToDate(destination, sha1: artifact.sha1, size: artifact.size, verify: true) {
                continue
            }
            guard let url = URL(string: artifact.url) else { continue }
            plan.libraries.append(DownloadItem(
                remoteURL: url,
                destination: destination,
                sha1: artifact.sha1,
                size: artifact.size,
                label: artifact.path.split(separator: "/").last.map(String.init) ?? artifact.path
            ))
        }

        // The per-version Log4j config, unless it is one of the two the launcher
        // ships a hardened replacement for. Skipping those is not an optimisation:
        // overwriting the patch with Mojang's original would reintroduce the
        // Log4Shell vector the patch exists to close.
        if let logging = version.logging, shouldDownloadLog4jConfig(id: logging.client.file.id) {
            let file = logging.client.file
            // The game resolves `${path}` relative to the game directory, so the
            // file has to land there under its own id.
            let destination = LauncherPath.instance(instanceName)
                .appendingPathComponent(file.id)
            if !isUpToDate(destination, sha1: file.sha1, size: file.size, verify: true),
               let url = URL(string: file.url) {
                plan.log4jConfig = DownloadItem(
                    remoteURL: url,
                    destination: destination,
                    sha1: file.sha1,
                    size: file.size,
                    label: file.id
                )
            }
        }

        for (_, object) in assetIndex.objects {
            let destination = LauncherPath.assetObject(hash: object.hash)
            if isUpToDate(destination, sha1: object.hash, size: object.size, verify: verifyAssets) {
                continue
            }
            guard let url = assetURL(for: object.hash) else { continue }
            plan.assets.append(DownloadItem(
                remoteURL: url,
                destination: destination,
                sha1: object.hash,
                size: object.size,
                label: object.hash
            ))
        }

        if let client = version.downloads?.client {
            let destination = LauncherPath.versionJar(version.id)
            if !isUpToDate(destination, sha1: client.sha1, size: client.size, verify: true),
               let url = URL(string: client.url) {
                plan.clientJar = DownloadItem(
                    remoteURL: url,
                    destination: destination,
                    sha1: client.sha1,
                    size: client.size,
                    label: "\(version.id).jar"
                )
            }
        }

        if assetIndex.requiresVirtualLayout {
            plan.legacyAssetMapping = assetIndex.objects.map { ($0.value.hash, $0.key) }
        }

        return plan
    }

    /// Libraries that survive the rule engine, in metadata order.
    func applicableLibraries(
        from version: MinecraftVersion,
        environment: RuleEnvironment = .current
    ) -> [Library] {
        version.libraries.filter { library in
            let rules = library.rules ?? []
            guard environment.allows(rules) else { return false }
            // A rule-less library with no artifact is a natives-only entry from the
            // pre-1.19 metadata shape; it has nothing to download on iOS.
            return library.downloads?.artifact != nil
        }
    }

    /// Whether this Log4j config should be fetched from Mojang.
    ///
    /// The two IDs below are the ones the launcher replaces with hardened copies
    /// from the app bundle (`JVMArguments.log4jConfiguration`). Downloading those
    /// would overwrite the patch with the vulnerable original — the exact opposite
    /// of the intent.
    func shouldDownloadLog4jConfig(id: String) -> Bool {
        id != "client-1.12.xml" && id != "client-1.7.xml"
    }

    private func isUpToDate(_ url: URL, sha1: String?, size: Int?, verify: Bool) -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }

        // Cheap check first: size. Hashing 40 MB of jars on every launch start is
        // noticeable on a phone, so full hashing is opt-in for assets and always
        // on for library/client jars.
        if let size, let attrs = try? fm.attributesOfItem(atPath: url.path),
           let onDisk = attrs[.size] as? Int, onDisk != size {
            return false
        }

        guard verify, let sha1, !sha1.isEmpty else { return true }
        return HashUtil.sha1Hex(ofFileAt: url) == sha1
    }

    /// The asset CDN shards by the first two characters of the hash.
    private func assetURL(for hash: String) -> URL? {
        URL(string: "https://resources.download.minecraft.net/\(hash.prefix(2))/\(hash)")
    }

    // MARK: - Execute

    /// Downloads a plan, reporting progress as it goes.
    func execute(
        plan: DownloadPlan,
        maxConcurrent: Int = 6,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let all = plan.libraries + plan.assets
            + (plan.clientJar.map { [$0] } ?? [])
            + (plan.log4jConfig.map { [$0] } ?? [])
        guard !all.isEmpty else {
            progress(DownloadProgress(completed: 0, total: 0, currentLabel: "已是最新"))
            return
        }

        try FileUtil.requireFreeSpace(plan.totalBytes)

        let total = all.count
        let counter = Counter()
        let reporter = ProgressReporter(total: total, progress: progress)

        try await HTTPClient.shared.forEachConcurrent(all, maxConcurrent: maxConcurrent) { item in
            try await HTTPClient.shared.download(
                url: item.remoteURL,
                to: item.destination,
                expectedSha1: item.sha1,
                expectedSize: item.size
            )
            let done = counter.increment()
            reporter.report(done: done, label: item.label)
        }

        if !plan.legacyAssetMapping.isEmpty {
            materializeVirtualAssets(plan.legacyAssetMapping)
        }
    }

    // MARK: - Legacy virtual assets

    /// Legacy versions (pre-1.7.3) look assets up by their original path rather
    /// than by hash. The official launcher materialises a `virtual/legacy` tree of
    /// hard links; iOS has no hard links across the sandbox, so copies are made and
    /// the result is cached by a stamp file.
    private func materializeVirtualAssets(_ mapping: [(hash: String, relativePath: String)]) {
        let root = LauncherPath.assets.appendingPathComponent("virtual/legacy", isDirectory: true)
        let stamp = root.appendingPathComponent(".craftlauncher-complete")

        if fm.fileExists(atPath: stamp.path) { return }
        LauncherPath.ensureDirectory(root)

        var copied = 0
        for entry in mapping {
            let source = LauncherPath.assetObject(hash: entry.hash)
            let destination = root.appendingPathComponent(entry.relativePath)
            guard fm.fileExists(atPath: source.path) else { continue }
            LauncherPath.ensureDirectory(destination.deletingLastPathComponent())
            try? fm.removeItem(at: destination)
            if (try? fm.copyItem(at: source, to: destination)) != nil {
                copied += 1
            }
        }

        fm.createFile(atPath: stamp.path, contents: Data())
        LogConsole.shared.info("已展开 \(copied) 个旧版资源文件到 virtual/legacy。")
    }

    // MARK: - Helpers

    /// `assets/objects` is shared between every version, so it grows without bound
    /// on a phone. This reports how much of it is unused by installed versions.
    func assetsSize() -> Int64 {
        FileUtil.directorySize(LauncherPath.assetObjects)
    }

    func deleteUnusedAssets(keeping hashes: Set<String>) -> Int64 {
        var reclaimed: Int64 = 0
        let fm = FileManager.default
        guard let prefixes = try? fm.contentsOfDirectory(
            at: LauncherPath.assetObjects,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return 0 }

        for prefix in prefixes {
            guard let files = try? fm.contentsOfDirectory(
                at: prefix,
                includingPropertiesForKeys: [.fileSizeKey]
            ) else { continue }
            for file in files where !hashes.contains(file.lastPathComponent) {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if (try? fm.removeItem(at: file)) != nil {
                    reclaimed += Int64(size)
                }
            }
        }
        return reclaimed
    }
}

// MARK: - Concurrency helpers

/// Atomic counter for progress reporting across download tasks.
final class Counter: @unchecked Sendable {
    private var value = 0
    private let lock = NSLock()

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

/// Coalesces progress callbacks so the main thread is not flooded.
private final class ProgressReporter: @unchecked Sendable {
    private let total: Int
    private let progress: @Sendable (DownloadProgress) -> Void
    private let lock = NSLock()
    private var lastReportedFraction = -1.0

    init(total: Int, progress: @escaping @Sendable (DownloadProgress) -> Void) {
        self.total = total
        self.progress = progress
    }

    func report(done: Int, label: String) {
        lock.lock()
        let fraction = total == 0 ? 1 : Double(done) / Double(total)
        // Emit at most ~100 updates, and always the final one.
        let shouldReport = done == total || fraction - lastReportedFraction >= 0.01
        if shouldReport { lastReportedFraction = fraction }
        lock.unlock()

        guard shouldReport else { return }
        progress(DownloadProgress(completed: done, total: total, currentLabel: label))
    }
}
