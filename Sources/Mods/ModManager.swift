import Foundation

/// Imports modpacks and individual mods, and manages the enabled/disabled state of
/// an instance's `mods/` directory.
@MainActor
final class ModManager: ObservableObject {
    static let shared = ModManager()

    /// Bumped after any mutation so views re-scan without polling.
    @Published private(set) var revision = 0

    /// Import progress, nil when idle.
    @Published private(set) var importProgress: Double?
    @Published private(set) var importLabel: String?

    private let fm = FileManager.default

    /// Cache of the last scan, keyed by instance.
    ///
    /// Reading mod metadata means opening every jar and inflating its manifest,
    /// which is far too slow to do from a SwiftUI `body`. The cache is invalidated
    /// whenever `revision` changes, so a view can call `mods(in:)` freely.
    private var cache: [String: [ModEntry]] = [:]
    private var cachedRevision = -1

    var isImporting: Bool { importProgress != nil }

    // MARK: - Listing

    /// Every mod in an instance, enabled ones first then alphabetical.
    func mods(in instance: String) -> [ModEntry] {
        if cachedRevision == revision, let hit = cache[instance] {
            return hit
        }

        var results: [ModEntry] = []
        results.append(contentsOf: scan(
            directory: LauncherPath.modsDir(instance: instance),
            enabled: true
        ))
        results.append(contentsOf: scan(
            directory: LauncherPath.modsDisabledDir(instance: instance),
            enabled: false
        ))

        let sorted = results.sorted { a, b in
            if a.enabled != b.enabled { return a.enabled }
            return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }

        if cachedRevision != revision {
            // A mutation happened since the last scan; everything cached is stale.
            cache.removeAll()
            cachedRevision = revision
        }
        cache[instance] = sorted
        return sorted
    }

    private func scan(directory: URL, enabled: Bool) -> [ModEntry] {
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension.lowercased() == "jar" }
            .map { url in
                let values = try? url.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey]
                )
                return ModEntry(
                    id: "\(enabled ? "on" : "off")/\(url.lastPathComponent)",
                    fileName: url.lastPathComponent,
                    url: url,
                    sizeBytes: Int64(values?.fileSize ?? 0),
                    modifiedAt: values?.contentModificationDate,
                    enabled: enabled,
                    metadata: ModInspector.inspect(jarAt: url)
                )
            }
    }

    /// Count of enabled jars only. Cheap enough for the Home screen, because it
    /// lists names instead of opening any archives.
    func modCount(in instance: String) -> Int {
        let on = (try? fm.contentsOfDirectory(
            atPath: LauncherPath.modsDir(instance: instance).path
        )) ?? []
        return on.filter { $0.hasSuffix(".jar") }.count
    }

    /// Forces the next `mods(in:)` call to re-read every jar.
    func invalidate() {
        cache.removeAll()
        revision += 1
    }

    /// Invalidates the cache and notifies observers. Every mutation goes through
    /// here so a stale list can never be shown.
    private func markChanged() {
        cache.removeAll()
        revision += 1
    }

    // MARK: - Enable / disable

    /// Toggles a mod by moving it between `mods/` and `mods.disabled/`.
    ///
    /// Moving to a separate directory rather than renaming in place: the loaders
    /// scan `mods/` for `.jar` files, and a `.jar.disabled` file is ignored by most
    /// of them — but Forge 1.12 in particular still tries to parse anything whose
    /// name starts with `.jar`, which produces a confusing crash. A separate
    /// directory is unambiguous for every loader.
    func toggle(_ mod: ModEntry, in instance: String) {
        let destinationDir = mod.enabled
            ? LauncherPath.modsDisabledDir(instance: instance)
            : LauncherPath.modsDir(instance: instance)
        LauncherPath.ensureDirectory(destinationDir)
        let destination = destinationDir.appendingPathComponent(mod.fileName)

        do {
            // Both directories always share the instance root, so a plain move
            // never crosses a volume boundary.
            try fm.moveItem(at: mod.url, to: destination)
            LogConsole.shared.info("\(mod.enabled ? "已禁用" : "已启用") \(mod.fileName)")
            markChanged()
        } catch {
            LogConsole.shared.error("切换 \(mod.fileName) 失败：\(error.localizedDescription)")
        }
    }

    func delete(_ mod: ModEntry) {
        do {
            try fm.removeItem(at: mod.url)
            LogConsole.shared.info("已删除 \(mod.fileName)")
            markChanged()
        } catch {
            LogConsole.shared.error("删除 \(mod.fileName) 失败：\(error.localizedDescription)")
        }
    }

    /// Copies external jars into the instance's `mods/` directory.
    ///
    /// Used by the Files-app "Open in CraftLauncher" route, where the URL lives
    /// outside the sandbox and needs a security-scoped access grant.
    func importMods(from urls: [URL], into instance: String) {
        let destinationDir = LauncherPath.modsDir(instance: instance)
        LauncherPath.ensureDirectory(destinationDir)

        var imported = 0
        var failures: [String] = []

        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            let destination = destinationDir.appendingPathComponent(url.lastPathComponent)
            do {
                try? fm.removeItem(at: destination)
                try fm.copyItem(at: url, to: destination)
                imported += 1
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        if imported > 0 {
            LogConsole.shared.info("已导入 \(imported) 个 Mod 到实例「\(instance)」。")
            markChanged()
        }
        if !failures.isEmpty {
            LogConsole.shared.error("导入失败：\(failures.joined(separator: "、"))")
        }
    }

    // MARK: - Modpack import

    /// Imports a `.mrpack` (Modrinth) or a CurseForge `.zip` into an instance.
    func importModpack(from url: URL, into instance: String) {
        guard !isImporting else {
            LogConsole.shared.warning("已有整合包正在导入。")
            return
        }

        importProgress = 0
        importLabel = "正在读取整合包"

        Task { [weak self] in
            guard let self else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            do {
                try await self.performImport(archiveURL: url, instance: instance)
                LogConsole.shared.info("整合包导入完成。")
                self.markChanged()
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                LogConsole.shared.error("整合包导入失败：\(message)")
            }

            self.importProgress = nil
            self.importLabel = nil
        }
    }

    private func performImport(archiveURL: URL, instance: String) async throws {
        guard let archive = ZipReader(url: archiveURL) else {
            throw LauncherError.unsupportedArchive(archiveURL.lastPathComponent)
        }
        defer { archive.close() }

        let manifest = try parseManifest(from: archive, name: archiveURL.lastPathComponent)

        LauncherPath.ensureDirectory(LauncherPath.modsDir(instance: instance))

        setImport(0.05, manifest.files.isEmpty
            ? "正在展开随包文件"
            : "需要下载 \(manifest.files.count) 个文件")

        // Download the pack's remote files in parallel, keeping the pack's own
        // folder layout — some packs ship configs and resource packs this way too.
        let downloaded = Counter()
        let total = max(manifest.files.count, 1)

        try await HTTPClient.shared.forEachConcurrent(manifest.files, maxConcurrent: 4) { file in
            let destination = Self.join(instance: instance, relativePath: file.relativePath)
            guard let remote = URL(string: file.url) else { return }

            // `download` verifies the pack's own hash when it supplies one, which is
            // what makes a partially-downloaded pack safe to retry.
            try await HTTPClient.shared.download(
                url: remote,
                to: destination,
                expectedSha1: file.sha1
            )

            let done = downloaded.increment()
            Task { @MainActor in
                self.setImport(
                    0.05 + 0.80 * (Double(done) / Double(total)),
                    "\(done)/\(total) \(file.fileName)"
                )
            }
        }

        setImport(0.90, "正在展开随包文件")
        let extracted = try extractOverrides(
            from: archive,
            into: instance,
            prefixes: manifest.overridePrefixes
        )

        setImport(1.0, "完成")
        LogConsole.shared.info(
            "整合包「\(manifest.name)」已导入：下载 \(manifest.files.count) 个文件，展开 \(extracted) 个随包文件。"
        )
    }

    // MARK: - Manifest parsing

    private struct PackManifest {
        let name: String
        let files: [PackFile]
        let overridePrefixes: [String]
    }

    private struct PackFile {
        let url: String
        let relativePath: String
        let fileName: String
        let sha1: String?
    }

    private func parseManifest(from archive: ZipReader, name: String) throws -> PackManifest {
        // Modrinth
        if let data = archive.data(forEntry: "modrinth.index.json"),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseModrinthIndex(root)
        }

        // CurseForge
        if let data = archive.data(forEntry: "manifest.json"),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseCurseForgeManifest(root, archive: archive)
        }

        throw LauncherError.unsupportedArchive(name)
    }

    private func parseModrinthIndex(_ root: [String: Any]) throws -> PackManifest {
        let packName = root["name"] as? String ?? "未命名整合包"
        var files: [PackFile] = []

        for entry in (root["files"] as? [[String: Any]]) ?? [] {
            guard let path = entry["path"] as? String,
                  let downloads = entry["downloads"] as? [String],
                  let url = downloads.first
            else { continue }

            // Modrinth marks server-only files; installing them client-side makes
            // some loaders refuse to start.
            if let env = entry["env"] as? [String: String], env["client"] == "unsupported" {
                continue
            }

            var sha1: String?
            if let hashes = entry["hashes"] as? [String: String] {
                sha1 = hashes["sha1"]
            }

            files.append(PackFile(
                url: url,
                relativePath: path,
                fileName: (path as NSString).lastPathComponent,
                sha1: sha1
            ))
        }

        return PackManifest(
            name: packName,
            files: files,
            overridePrefixes: ["overrides/", "client-overrides/"]
        )
    }

    /// CurseForge's `manifest.json` carries only project ids and file ids; the
    /// download URLs come from an API that requires a key we cannot ship.
    ///
    /// What *is* usable is the embedded payload: packs redistributed as `.zip`
    /// normally bundle every jar under `overrides/mods/`, and `extractOverrides`
    /// pulls them straight out of the archive. A pack that ships only ids yields
    /// zero files, which is reported clearly instead of failing mid-download.
    private func parseCurseForgeManifest(
        _ root: [String: Any],
        archive: ZipReader
    ) throws -> PackManifest {
        let packName = root["name"] as? String ?? "未命名整合包"

        let embeddedJars = archive.entryNames.filter {
            $0.hasPrefix("overrides/") && $0.hasSuffix(".jar")
        }.count

        if embeddedJars == 0 {
            let declared = (root["files"] as? [[String: Any]])?.count ?? 0
            if declared > 0 {
                throw LauncherError.unsupportedArchive(
                    "CurseForge 整合包（只含 \(declared) 个项目编号，未内嵌文件）"
                )
            }
        }

        return PackManifest(
            name: packName,
            // Nothing to download from the manifest itself; the archive is the source.
            files: [],
            overridePrefixes: ["overrides/"]
        )
    }

    // MARK: - Overrides

    /// Extracts `overrides/` into the instance root, preserving relative paths.
    /// Returns the number of files written.
    @discardableResult
    private func extractOverrides(
        from archive: ZipReader,
        into instance: String,
        prefixes: [String]
    ) throws -> Int {
        let root = LauncherPath.instance(instance)
        let canonicalRoot = root.standardizedFileURL.path
        var written = 0

        for entryName in archive.entryNames {
            guard let prefix = prefixes.first(where: { entryName.hasPrefix($0) }) else { continue }
            let relative = String(entryName.dropFirst(prefix.count))
            guard !relative.isEmpty, !relative.hasSuffix("/") else { continue }

            let destination = root.appendingPathComponent(relative)

            // Zip-slip guard: a crafted `overrides/../../..` entry must not be able
            // to write outside the instance directory.
            guard destination.standardizedFileURL.path.hasPrefix(canonicalRoot) else {
                LogConsole.shared.warning("跳过可疑的整合包条目：\(entryName)")
                continue
            }

            guard let data = archive.data(forEntry: entryName) else { continue }
            LauncherPath.ensureDirectory(destination.deletingLastPathComponent())
            try? fm.removeItem(at: destination)
            try? data.write(to: destination, options: .atomic)
            written += 1
        }

        if written > 0 {
            LogConsole.shared.info("已展开 \(written) 个随包文件。")
        }
        return written
    }

    /// Joins a pack-relative path onto the instance directory, refusing traversal.
    private static func join(instance: String, relativePath: String) -> URL {
        let root = LauncherPath.instance(instance)
        let candidate = root.appendingPathComponent(relativePath)
        let canonicalRoot = root.standardizedFileURL.path
        guard candidate.standardizedFileURL.path.hasPrefix(canonicalRoot) else {
            // Fall back to the flat file name rather than escaping the sandbox.
            return root.appendingPathComponent((relativePath as NSString).lastPathComponent)
        }
        return candidate
    }

    private func setImport(_ value: Double, _ label: String) {
        importProgress = value
        importLabel = label
    }
}
