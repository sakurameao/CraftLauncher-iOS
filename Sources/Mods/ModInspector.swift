import Foundation

/// A mod jar sitting in an instance's `mods/` (or `mods.disabled/`) directory.
struct ModEntry: Identifiable, Hashable {
    let id: String
    /// File name including extension, as shown in the Files app.
    let fileName: String
    let url: URL
    let sizeBytes: Int64
    let modifiedAt: Date?
    let enabled: Bool

    /// Metadata lifted out of the jar, when it could be read.
    var metadata: ModMetadata

    var displayName: String {
        metadata.name ?? fileName.replacingOccurrences(of: ".jar", with: "")
    }

    var sizeLabel: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// The union of what the three loader ecosystems write into a jar.
///
/// All fields optional because a jar may carry none of these files (a plain
/// library dropped into `mods/` by mistake), and a half-filled mod list is more
/// useful than an error.
struct ModMetadata: Hashable {
    var name: String?
    var modId: String?
    var version: String?
    var description: String?
    var authors: [String] = []
    var loader: ModLoaderKind?
    /// Declared dependencies that the loader resolves by mod id.
    var depends: [String] = []

    static let unknown = ModMetadata()

    var authorLabel: String? {
        authors.isEmpty ? nil : authors.joined(separator: "、")
    }
}

/// Reads mod metadata out of jar archives.
///
/// A jar is a zip, and the relevant entries are near the start of the central
/// directory, so only the manifest-ish files are decompressed — never the classes.
enum ModInspector {

    /// Inspects a jar and returns whatever metadata could be recovered.
    ///
    /// Never throws: a corrupt or unreadable jar yields `.unknown` so it still
    /// appears in the list and the user can delete it.
    static func inspect(jarAt url: URL) -> ModMetadata {
        guard let archive = ZipReader(url: url) else { return .unknown }
        defer { archive.close() }

        // Fabric and Quilt
        if let data = archive.data(forEntry: "fabric.mod.json") {
            return parseFabricModJSON(data, loader: .fabric)
        }
        if let data = archive.data(forEntry: "quilt.mod.json") {
            return parseQuiltModJSON(data)
        }

        // Forge / NeoForge
        for path in ["META-INF/mods.toml", "META-INF/neoforge.mods.toml"] {
            if let data = archive.data(forEntry: path) {
                let loader: ModLoaderKind = path.contains("neoforge") ? .neoForge : .forge
                return parseModsTOML(data, loader: loader)
            }
        }

        // Legacy Forge (1.12 and earlier)
        for path in ["mcmod.info", "META-INF/mcmod.info"] {
            if let data = archive.data(forEntry: path) {
                return parseMcModInfo(data)
            }
        }

        // Liteloader, and a fallback for jars with only a manifest.
        if let data = archive.data(forEntry: "litemod.json") {
            return parseLitemodJSON(data)
        }

        return .unknown
    }

    // MARK: - fabric.mod.json

    private static func parseFabricModJSON(_ data: Data, loader: ModLoaderKind) -> ModMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        var meta = ModMetadata()
        meta.loader = loader
        meta.modId = root["id"] as? String
        meta.version = root["version"] as? String
        meta.name = (root["name"] as? String) ?? meta.modId
        meta.description = root["description"] as? String

        // `authors` is either strings or objects with a `name` key.
        if let authors = root["authors"] as? [Any] {
            meta.authors = authors.compactMap { entry in
                if let s = entry as? String { return s }
                if let d = entry as? [String: Any] { return d["name"] as? String }
                return nil
            }
        }

        if let depends = root["depends"] as? [String: Any] {
            meta.depends = depends.keys.sorted()
        }
        return meta
    }

    // MARK: - quilt.mod.json

    private static func parseQuiltModJSON(_ data: Data) -> ModMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        var meta = ModMetadata()
        meta.loader = .quilt

        if let ql = root["quilt_loader"] as? [String: Any] {
            meta.modId = ql["id"] as? String
            meta.version = ql["version"] as? String
            if let m = ql["metadata"] as? [String: Any] {
                meta.name = m["name"] as? String
                meta.description = m["description"] as? String
                if let contributors = m["contributors"] as? [String: Any] {
                    meta.authors = contributors.keys.sorted()
                }
            }
            if let depends = ql["depends"] as? [Any] {
                meta.depends = depends.compactMap { ($0 as? [String: Any])?["id"] as? String }
            }
        }
        if meta.name == nil { meta.name = meta.modId }
        return meta
    }

    // MARK: - META-INF/mods.toml

    /// A deliberately small TOML reader covering only the shapes Forge uses for
    /// mod metadata. A full TOML parser would be a large dependency for four
    /// fields; a malformed file simply yields `.unknown`.
    private static func parseModsTOML(_ data: Data, loader: ModLoaderKind) -> ModMetadata {
        guard let text = String(data: data, encoding: .utf8) else { return .unknown }
        var meta = ModMetadata()
        meta.loader = loader

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)

        // `[[mods]]` starts a mod block; the first one is the actual mod even when
        // Forge declares several (its own dependencies appear as additional blocks).
        var inModsBlock = false
        var seenModsBlock = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if line.hasPrefix("[[") {
                if line.contains("mods") {
                    if seenModsBlock {
                        // Second block: stop, we already have the primary mod.
                        break
                    }
                    seenModsBlock = true
                    inModsBlock = true
                } else {
                    inModsBlock = false
                }
                continue
            }
            if line.hasPrefix("[") {
                inModsBlock = false
                continue
            }
            guard inModsBlock else { continue }

            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)

            // Strip a trailing comment that is not inside a quoted string.
            if !value.hasPrefix("\"") {
                if let hash = value.firstIndex(of: "#") {
                    value = String(value[value.startIndex..<hash]).trimmingCharacters(in: .whitespaces)
                }
            }

            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))

            switch key {
            case "modId": meta.modId = unquoted
            case "version": meta.version = unquoted
            case "displayName": meta.name = unquoted
            case "description": meta.description = unquoted
            case "authors":
                meta.authors = unquoted
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            default:
                break
            }

            if meta.name != nil, meta.modId != nil, meta.version != nil,
               meta.description != nil, !meta.authors.isEmpty {
                break
            }
        }

        if meta.name == nil { meta.name = meta.modId }
        // Forge writes `"${file.jarVersion}"` when the version comes from the
        // manifest; showing that literal string is noise.
        if meta.version?.contains("${") == true {
            meta.version = extractImplementationVersion(from: data) ?? nil
        }
        return meta
    }

    private static func extractImplementationVersion(from data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains("Implementation-Version") {
            let parts = line.split(separator: "=", maxSplits: 1)
            if parts.count == 2 {
                return parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    // MARK: - mcmod.info (legacy Forge)

    private static func parseMcModInfo(_ data: Data) -> ModMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return .unknown }

        // The file is either an object with a `modList` array or a bare array.
        let entries: [[String: Any]]
        if let dict = root as? [String: Any], let list = dict["modList"] as? [[String: Any]] {
            entries = list
        } else if let list = root as? [[String: Any]] {
            entries = list
        } else {
            return .unknown
        }

        guard let first = entries.first else { return .unknown }
        var meta = ModMetadata()
        meta.loader = .forge
        meta.modId = first["modid"] as? String
        meta.name = first["name"] as? String
        meta.version = first["version"] as? String
        meta.description = first["description"] as? String
        if let authors = first["authorList"] as? [String] {
            meta.authors = authors
        } else if let author = first["author"] as? String, !author.isEmpty {
            meta.authors = [author]
        }
        if meta.name == nil { meta.name = meta.modId }
        return meta
    }

    // MARK: - litemod.json

    private static func parseLitemodJSON(_ data: Data) -> ModMetadata {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .unknown
        }
        var meta = ModMetadata()
        meta.loader = .vanilla  // LiteLoader is not modelled separately
        meta.name = root["name"] as? String
        meta.modId = root["name"] as? String
        meta.version = root["version"] as? String
        meta.description = root["description"] as? String
        if let author = root["author"] as? String {
            meta.authors = [author]
        }
        return meta
    }
}
