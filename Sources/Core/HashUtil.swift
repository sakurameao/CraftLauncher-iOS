import Foundation
import CryptoKit

/// Byte-level primitives shared by the launcher.
enum HashUtil {
    static func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Streaming SHA-1 so a 40 MB client jar is not held in memory.
    static func sha1Hex(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = Insecure.SHA1()
        while true {
            guard let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func md5(_ data: Data) -> Data {
        Data(Insecure.MD5.hash(data: data))
    }
}

/// UUID helpers.
enum UUIDUtil {
    /// Reproduces `java.util.UUID.nameUUIDFromBytes` **exactly**.
    ///
    /// Java computes `MD5(seed)`, then overwrites the version nibble with `3`
    /// (name-based) and the variant bits with `10`. Minecraft's offline-mode server
    /// uses this on `"OfflinePlayer:" + name`, so a single wrong bit means the
    /// player has a different identity on every server they join — and their
    /// inventory does not follow them.
    static func nameUUID(from seed: String) -> String {
        var bytes = [UInt8](HashUtil.md5(Data(seed.utf8)))  // always 16 bytes
        bytes[6] = (bytes[6] & 0x0F) | 0x30  // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // IETF variant
        return uuidString(from: bytes)
    }

    /// Renders 16 bytes as `8-4-4-4-12` lowercase hex.
    static func uuidString(from bytes: [UInt8]) -> String {
        guard bytes.count == 16 else { return "" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let positions = [8, 12, 16, 20]
        var out = ""
        var last = 0
        for p in positions {
            let idx = hex.index(hex.startIndex, offsetBy: p)
            out += hex[hex.index(hex.startIndex, offsetBy: last)..<idx] + "-"
            last = p
        }
        out += hex[hex.index(hex.startIndex, offsetBy: last)...]
        return out
    }

    /// Insert dashes into the 32-character UUID that Mojang's profile endpoint
    /// returns, which is missing them.
    static func hyphenated(_ raw: String) -> String {
        let clean = raw.replacingOccurrences(of: "-", with: "")
        guard clean.count == 32 else { return raw }
        let chars = Array(clean)
        func slice(_ from: Int, _ to: Int) -> String { String(chars[from..<to]) }
        return [
            slice(0, 8), slice(8, 12), slice(12, 16), slice(16, 20), slice(20, 32),
        ].joined(separator: "-")
    }

    /// The offline-mode identity for a player name.
    static func offlineUUID(for name: String) -> String {
        nameUUID(from: "OfflinePlayer:\(name)")
    }
}
