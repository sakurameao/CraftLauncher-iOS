import Foundation

/// Fetches and caches version metadata from Mojang.
///
/// An `actor` because several screens ask for the same document concurrently
/// (the version list, the selected version's detail, and the launch pipeline), and
/// they should share one in-flight request rather than race.
actor VersionService {
    static let shared = VersionService()

    static let manifestURL = URL(string: "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")!

    private var cachedManifest: VersionManifest?
    private var cachedVersions: [String: MinecraftVersion] = [:]
    private var inFlightManifest: Task<VersionManifest, Error>?

    private let fm = FileManager.default

    // MARK: - Manifest

    /// Returns the version manifest, preferring the network and falling back to
    /// the on-disk copy when offline.
    ///
    /// The fallback matters on a phone: without it, opening the app on a plane
    /// shows an empty version list and no way to launch an already-installed game.
    func manifest(forceRefresh: Bool = false) async throws -> VersionManifest {
        if !forceRefresh, let cached = cachedManifest { return cached }

        // Collapse concurrent callers onto one request.
        if !forceRefresh, let existing = inFlightManifest {
            return try await existing.value
        }

        let task = Task<VersionManifest, Error> { [manifestURL = VersionService.manifestURL] in
            try await HTTPClient.shared.getJSON(VersionManifest.self, from: manifestURL)
        }
        inFlightManifest = task

        do {
            let manifest = try await task.value
            inFlightManifest = nil
            cachedManifest = manifest
            persistManifest(manifest)
            return manifest
        } catch {
            inFlightManifest = nil

            if let disk = loadPersistedManifest() {
                LogConsole.shared.warning(
                    "无法连接版本服务器（\(error.localizedDescription)），已改用本地缓存的版本列表。"
                )
                cachedManifest = disk
                return disk
            }
            throw LauncherError.manifestUnreachable(underlying: error.localizedDescription)
        }
    }

    private func persistManifest(_ manifest: VersionManifest) {
        LauncherPath.ensureDirectory(LauncherPath.cache)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(manifest) else { return }
        try? data.write(to: LauncherPath.versionManifestCache, options: .atomic)
    }

    private func loadPersistedManifest() -> VersionManifest? {
        guard let data = try? Data(contentsOf: LauncherPath.versionManifestCache) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(VersionManifest.self, from: data)
    }

    // MARK: - Version detail

    /// Downloads (or reuses) a version's metadata document.
    func versionDetail(entry: VersionManifest.Entry, forceRefresh: Bool = false) async throws -> MinecraftVersion {
        if !forceRefresh, let cached = cachedVersions[entry.id] { return cached }

        let destination = LauncherPath.versionJSON(entry.id)
        guard let url = URL(string: entry.url) else {
            throw LauncherError.versionJSONMissing(entry.id)
        }

        // Metadata is small and changes rarely; a hash match means no network.
        try await HTTPClient.shared.download(
            url: url,
            to: destination,
            expectedSha1: entry.sha1.isEmpty ? nil : entry.sha1
        )

        let version = try decodeVersion(at: destination, id: entry.id)
        cachedVersions[entry.id] = version
        return version
    }

    func versionDetail(versionId: String, forceRefresh: Bool = false) async throws -> MinecraftVersion {
        if !forceRefresh, let cached = cachedVersions[versionId] { return cached }

        // Locally installed (possibly modded) version.
        let local = LauncherPath.versionJSON(versionId)
        if fm.fileExists(atPath: local.path), !forceRefresh {
            let version = try decodeVersion(at: local, id: versionId)
            cachedVersions[versionId] = version
            return version
        }

        let manifest = try await manifest(forceRefresh: forceRefresh)
        guard let entry = manifest.versions.first(where: { $0.id == versionId }) else {
            throw LauncherError.versionJSONMissing(versionId)
        }
        return try await versionDetail(entry: entry, forceRefresh: forceRefresh)
    }

    private func decodeVersion(at url: URL, id: String) throws -> MinecraftVersion {
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(MinecraftVersion.self, from: data)
        } catch let error as DecodingError {
            throw LauncherError.versionJSONMalformed(id, underlying: describe(error))
        } catch {
            throw LauncherError.versionJSONMissing(id)
        }
    }

    private func describe(_ error: DecodingError) -> String {
        switch error {
        case let .keyNotFound(key, context):
            return "缺少字段 \(key.stringValue)（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let .typeMismatch(type, context):
            return "字段类型不符，期望 \(type)（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let .valueNotFound(type, context):
            return "字段为空，期望 \(type)（\(context.codingPath.map(\.stringValue).joined(separator: "."))）"
        case let .dataCorrupted(context):
            return "数据损坏：\(context.debugDescription)"
        @unknown default:
            return String(describing: error)
        }
    }

    // MARK: - Inheritance

    /// Resolves an `inheritsFrom` chain into a standalone version.
    ///
    /// Depth-limited: a malformed profile with a reference cycle would otherwise
    /// recurse until the stack overflows, which crashes the app with no log.
    func resolvedVersion(versionId: String, maxDepth: Int = 8) async throws -> MinecraftVersion {
        try await resolve(versionId: versionId, depth: 0, limit: maxDepth)
    }

    private func resolve(versionId: String, depth: Int, limit: Int) async throws -> MinecraftVersion {
        guard depth <= limit else {
            LogConsole.shared.warning("版本「\(versionId)」的继承层数超过 \(limit)，可能存在循环引用，已停止递归。")
            return try await versionDetail(versionId: versionId)
        }

        let version = try await versionDetail(versionId: versionId)

        guard let parentId = version.inheritsFrom, !parentId.isEmpty else {
            return version
        }

        // The parent may be a locally installed modded version (a mod loader built
        // on top of another mod loader), so resolve it the same way.
        let parent = try await resolve(versionId: parentId, depth: depth + 1, limit: limit)
        return MinecraftVersion.merge(child: version, parent: parent)
    }

    // MARK: - Asset index

    func assetIndex(for version: MinecraftVersion) async throws -> AssetIndex {
        guard let index = version.assetIndex else {
            // Pre-1.7 versions have no index at all; an empty one is valid.
            return AssetIndex(objects: [:], virtual: false, mapToResources: false)
        }
        let destination = LauncherPath.assetIndex(index.id)

        if let cached = cachedAssetIndexes[index.id] { return cached }

        try await HTTPClient.shared.download(
            url: URL(string: index.url)!,
            to: destination,
            expectedSha1: index.sha1.isEmpty ? nil : index.sha1
        )

        let data = try Data(contentsOf: destination)
        let parsed = try JSONDecoder().decode(AssetIndex.self, from: data)
        cachedAssetIndexes[index.id] = parsed
        return parsed
    }

    private var cachedAssetIndexes: [String: AssetIndex] = [:]

    // MARK: - Installed versions

    /// Version ids that have a local metadata file, i.e. anything the user has
    /// downloaded or installed a mod loader into.
    nonisolated func installedVersionIds() -> Set<String> {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: LauncherPath.versions,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var ids: Set<String> = []
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let id = entry.lastPathComponent
            if fm.fileExists(atPath: LauncherPath.versionJSON(id).path) {
                ids.insert(id)
            }
        }
        return ids
    }

    /// Removes a version's metadata and client jar. Returns the bytes reclaimed.
    @discardableResult
    nonisolated func deleteVersion(_ versionId: String) -> Int64 {
        let dir = LauncherPath.versionDir(versionId)
        let size = FileUtil.directorySize(dir)
        try? FileManager.default.removeItem(at: dir)
        return size
    }

    /// Drops in-memory caches so a freshly edited file is re-read.
    func invalidate(versionId: String? = nil) {
        if let versionId {
            cachedVersions.removeValue(forKey: versionId)
        } else {
            cachedVersions.removeAll()
            cachedManifest = nil
        }
    }
}

// MARK: - Asset index

/// `assets/indexes/<id>.json`. Note that `virtual` and `map_to_resources` only
/// appear on legacy indexes; absence means false.
struct AssetIndex: Codable {
    struct Object: Codable, Hashable {
        let hash: String
        let size: Int
    }

    let objects: [String: Object]
    let virtual: Bool?
    let mapToResources: Bool?

    private enum CodingKeys: String, CodingKey {
        case objects
        case virtual
        case mapToResources = "map_to_resources"
    }

    /// Legacy indexes (pre-1.7.3) must be unpacked into `assets/virtual/legacy`
    /// because the game reads them by original path, not by hash.
    var requiresVirtualLayout: Bool { virtual == true || mapToResources == true }
}

// MARK: - File utilities

enum FileUtil {
    static func directorySize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            if values?.isRegularFile == true {
                total += Int64(values?.fileSize ?? 0)
            }
        }
        return total
    }

    /// Free space available for "important" writes. Used to refuse a download that
    /// cannot possibly fit rather than failing halfway with a corrupt install.
    static func availableBytes() -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(
            forPath: LauncherPath.launcherRoot.path
        ) else { return nil }
        return (attrs[.systemFreeSize] as? NSNumber)?.int64Value
    }

    /// Throws `.diskFull` when `required` bytes will not fit, leaving headroom so
    /// the launcher can still write its logs.
    static func requireFreeSpace(_ required: Int64, headroom: Int64 = 200 * 1024 * 1024) throws {
        guard let available = availableBytes() else { return }
        if available < required + headroom {
            throw LauncherError.diskFull
        }
    }

    static func humanSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
