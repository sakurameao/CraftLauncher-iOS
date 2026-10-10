import Foundation
import Compression

/// Minimal, dependency-free zip reader.
///
/// Mod jars and modpack archives are zips, and the launcher only ever needs a
/// handful of small text entries out of each one. Foundation has no public zip
/// API, and pulling in a package for this would add more surface than it removes,
/// so this walks the central directory and inflates individual entries.
///
/// It is intentionally read-only and does not support multi-disk archives,
/// encryption, or zip64 — none of which occur in Minecraft modding.
final class ZipReader {
    private let handle: FileHandle
    private let fileSize: UInt64
    private var entries: [String: Entry] = [:]

    struct Entry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        /// 0 = stored, 8 = deflate.
        let method: UInt16
        let localHeaderOffset: UInt64
    }

    /// Refuses entries larger than this. Mod metadata is kilobytes; a 64 MB entry
    /// inside a "mod" is either a corrupted index or an attempt to exhaust memory.
    private static let maxEntrySize = 64 * 1024 * 1024

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle

        let size = (try? handle.seekToEnd()) ?? 0
        self.fileSize = size
        guard size > 22 else { try? handle.close(); return nil }

        guard readCentralDirectory() else {
            try? handle.close()
            return nil
        }
    }

    func close() {
        try? handle.close()
    }

    var entryNames: [String] { Array(entries.keys) }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    // MARK: - Central directory

    private func readCentralDirectory() -> Bool {
        // End Of Central Directory: signature 0x06054b50, comment up to 64 KB, so
        // scan back that far from EOF.
        let maxScan: UInt64 = 66_000
        let scanStart = fileSize > maxScan ? fileSize - maxScan : 0
        let scanLength = Int(fileSize - scanStart)
        guard scanLength > 0, let tail = read(at: scanStart, length: scanLength) else { return false }

        // Find the *last* EOCD signature; a zip inside a zip can produce a decoy.
        var eocdOffset: Int?
        var i = tail.count - 4
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocdOffset = i
                break
            }
            i -= 1
        }
        guard let eocd = eocdOffset, eocd + 22 <= tail.count else { return false }

        let entryCount = Int(u16(tail, eocd + 10))
        let cdSize = Int(u32(tail, eocd + 12))
        let cdOffset = UInt64(u32(tail, eocd + 16))

        guard entryCount > 0, cdSize > 0, cdOffset < fileSize else { return false }
        guard let cd = read(at: cdOffset, length: cdSize) else { return false }

        var cursor = 0
        var parsed = 0
        while cursor + 46 <= cd.count && parsed < entryCount {
            guard u32(cd, cursor) == 0x0201_4B50 else { break }

            let method = u16(cd, cursor + 10)
            let compressedSize = Int(u32(cd, cursor + 20))
            let uncompressedSize = Int(u32(cd, cursor + 24))
            let nameLength = Int(u16(cd, cursor + 28))
            let extraLength = Int(u16(cd, cursor + 30))
            let commentLength = Int(u16(cd, cursor + 32))
            let localOffset = UInt64(u32(cd, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= cd.count else { break }
            let name = String(
                decoding: cd[nameStart..<(nameStart + nameLength)],
                as: UTF8.self
            )

            // Skip directory markers and anything absurdly large.
            if !name.hasSuffix("/"), uncompressedSize <= Self.maxEntrySize {
                entries[name] = Entry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    localHeaderOffset: localOffset
                )
            }

            cursor = nameStart + nameLength + extraLength + commentLength
            parsed += 1
        }
        return !entries.isEmpty
    }

    // MARK: - Entry data

    /// Reads and inflates one entry.
    func data(forEntry name: String) -> Data? {
        guard let entry = entries[name] else { return nil }

        // Local header: 30 fixed bytes, then name and extra with *their own*
        // lengths, which routinely differ from the central directory copies.
        guard let header = read(at: entry.localHeaderOffset, length: 30),
              u32(header, 0) == 0x0403_4B50
        else { return nil }

        let nameLength = Int(u16(header, 26))
        let extraLength = Int(u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)

        guard entry.compressedSize > 0 else { return Data() }
        guard let raw = read(at: dataOffset, length: entry.compressedSize) else { return nil }

        switch entry.method {
        case 0:
            return raw
        case 8:
            return inflate(raw, expectedSize: entry.uncompressedSize)
        default:
            // bzip2/lzma/zstd entries appear in some modpack overrides; not worth
            // supporting for metadata reads.
            return nil
        }
    }

    func string(forEntry name: String) -> String? {
        data(forEntry: name).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Raw (still compressed) bytes, used when copying an entry between archives.
    func compressedData(forEntry name: String) -> (method: UInt16, data: Data)? {
        guard let entry = entries[name] else { return nil }
        guard let header = read(at: entry.localHeaderOffset, length: 30) else { return nil }
        let nameLength = Int(u16(header, 26))
        let extraLength = Int(u16(header, 28))
        let dataOffset = entry.localHeaderOffset + 30 + UInt64(nameLength) + UInt64(extraLength)
        guard let raw = read(at: dataOffset, length: entry.compressedSize) else { return nil }
        return (entry.method, raw)
    }

    func uncompressedSize(forEntry name: String) -> Int? {
        entries[name]?.uncompressedSize
    }

    // MARK: - Inflate

    private func inflate(_ data: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0 else { return Data() }
        var output = Data(count: expectedSize)

        let written: Int = output.withUnsafeMutableBytes { outRaw -> Int in
            guard let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { inRaw -> Int in
                guard let inPtr = inRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                // Raw DEFLATE stream, which is what zip stores — no zlib wrapper,
                // hence COMPRESSION_ZLIB rather than a gzip variant.
                return compression_decode_buffer(
                    outPtr, expectedSize,
                    inPtr, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        if written < expectedSize {
            output = output.prefix(written)
        }
        return output
    }

    // MARK: - Primitive reads

    private func read(at offset: UInt64, length: Int) -> Data? {
        guard length > 0, offset + UInt64(length) <= fileSize else { return nil }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: length)
        } catch {
            return nil
        }
    }

    private func u16(_ data: Data, _ offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private func u32(_ data: Data, _ offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
