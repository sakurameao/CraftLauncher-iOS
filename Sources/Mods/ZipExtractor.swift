import Foundation
import Compression

/// Extracts zip archives to disk.
///
/// Separate from `ZipReader` because the workloads are different: `ZipReader`
/// pulls a few small entries into memory, while this streams a whole OpenJDK
/// (~140 MB, thousands of entries) onto the filesystem without buffering it.
///
/// iOS forces the two-step install dance this supports: the app bundle is
/// read-only and its contents cannot be executed, so a bundled runtime zip must be
/// unpacked into the Documents container before `bin/java` will run at all.
final class ZipExtractor {
    private let handle: FileHandle
    private let fileSize: UInt64

    /// Refuses to write an entry larger than this. Guards against a malformed
    /// archive claiming a multi-gigabyte entry and filling the device.
    private static let maxEntrySize = 512 * 1024 * 1024

    init?(url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        self.handle = handle
        self.fileSize = (try? handle.seekToEnd()) ?? 0
        guard fileSize > 22 else { try? handle.close(); return nil }
    }

    deinit { try? handle.close() }

    struct Entry {
        let name: String
        let compressedSize: Int
        let uncompressedSize: Int
        let method: UInt16
        let localHeaderOffset: UInt64
        /// Unix mode bits from the external attributes field; bits 0o111 mark an
        /// executable, which `bin/java` requires.
        let unixMode: UInt16
    }

    /// Extracts every entry into `destination`.
    ///
    /// - Parameter progress: called with (completed, total) entry counts.
    /// - Returns: the number of files written.
    @discardableResult
    func extractAll(
        to destination: URL,
        stripLeadingComponent: Bool = false,
        progress: ((Int, Int) -> Void)? = nil
    ) throws -> Int {
        let entries = try readCentralDirectory()
        let fm = FileManager.default
        LauncherPath.ensureDirectory(destination)

        var written = 0
        for (index, entry) in entries.enumerated() {
            try? Task.checkCancellation()
            defer { progress?(index + 1, entries.count) }

            let relative = stripLeadingComponent
                ? Self.strippingFirstComponent(entry.name)
                : entry.name
            guard !relative.isEmpty else { continue }

            let target = destination.appendingPathComponent(relative)

            // Reject path traversal. A `../../` entry in a malicious archive would
            // otherwise escape the destination entirely.
            let canonicalBase = destination.standardizedFileURL.path
            let canonicalTarget = target.standardizedFileURL.path
            guard canonicalTarget.hasPrefix(canonicalBase) else {
                LogConsole.shared.warning("跳过可疑的压缩包条目：\(entry.name)")
                continue
            }

            if entry.name.hasSuffix("/") {
                LauncherPath.ensureDirectory(target)
                continue
            }

            LauncherPath.ensureDirectory(target.deletingLastPathComponent())
            guard let data = try readEntry(entry) else { continue }

            try? fm.removeItem(at: target)
            try data.write(to: target, options: .atomic)

            // Preserve the executable bit. Without this `bin/java` is not runnable
            // and the launch fails with a bare "cannot execute" from posix_spawn.
            if entry.unixMode & 0o111 != 0 {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
            }
            written += 1
        }
        return written
    }

    /// Lists entry names without extracting.
    func listEntries() throws -> [String] {
        try readCentralDirectory()
            .filter { !$0.name.hasSuffix("/") }
            .map(\.name)
    }

    // MARK: - Central directory

    private func readCentralDirectory() throws -> [Entry] {
        let maxScan: UInt64 = 66_000
        let scanStart = fileSize > maxScan ? fileSize - maxScan : 0
        guard let tail = read(at: scanStart, length: Int(fileSize - scanStart)) else {
            throw LauncherError.unsupportedArchive("无法读取压缩包结尾")
        }

        var eocd: Int?
        var i = tail.count - 4
        while i >= 0 {
            if tail[i] == 0x50, tail[i + 1] == 0x4B, tail[i + 2] == 0x05, tail[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard let eocd, eocd + 22 <= tail.count else {
            throw LauncherError.unsupportedArchive("不是有效的 zip 文件")
        }

        let entryCount = Int(u16(tail, eocd + 10))
        let cdSize = Int(u32(tail, eocd + 12))
        let cdOffset = UInt64(u32(tail, eocd + 16))
        guard entryCount > 0, cdSize > 0, cdOffset < fileSize,
              let cd = read(at: cdOffset, length: cdSize)
        else {
            throw LauncherError.unsupportedArchive("压缩包目录为空或已损坏")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = 0

        while cursor + 46 <= cd.count {
            guard u32(cd, cursor) == 0x0201_4B50 else { break }

            let method = u16(cd, cursor + 10)
            let compressedSize = Int(u32(cd, cursor + 20))
            let uncompressedSize = Int(u32(cd, cursor + 24))
            let nameLength = Int(u16(cd, cursor + 28))
            let extraLength = Int(u16(cd, cursor + 30))
            let commentLength = Int(u16(cd, cursor + 32))
            let externalAttributes = u32(cd, cursor + 38)
            let localOffset = UInt64(u32(cd, cursor + 42))

            let nameStart = cursor + 46
            guard nameStart + nameLength <= cd.count else { break }
            let name = String(decoding: cd[nameStart..<(nameStart + nameLength)], as: UTF8.self)

            // Only the low 16 bits of the external attributes carry the Unix mode.
            let unixMode = UInt16(externalAttributes >> 16)

            if uncompressedSize <= Self.maxEntrySize {
                entries.append(Entry(
                    name: name,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    method: method,
                    localHeaderOffset: localOffset,
                    unixMode: unixMode
                ))
            }

            cursor = nameStart + nameLength + extraLength + commentLength
        }

        guard !entries.isEmpty else {
            throw LauncherError.unsupportedArchive("压缩包内没有可解压的文件")
        }
        return entries
    }

    // MARK: - Entry reading

    private func readEntry(_ entry: Entry) throws -> Data? {
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
            // Zip64, bzip2 and lzma entries do not appear in JDK or modpack
            // archives; skipping is safer than guessing.
            return nil
        }
    }

    private func inflate(_ data: Data, expectedSize: Int) -> Data? {
        // Some writers store an unknown size in the local header; the central
        // directory copy is authoritative, but fall back to a growth loop.
        if expectedSize <= 0 { return nil }

        var output = Data(count: expectedSize)
        let written: Int = output.withUnsafeMutableBytes { outRaw -> Int in
            guard let outPtr = outRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { inRaw -> Int in
                guard let inPtr = inRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    outPtr, expectedSize,
                    inPtr, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return written < expectedSize ? output.prefix(written) : output
    }

    // MARK: - Helpers

    /// `jdk-17/Contents/Home/bin/java` → `Contents/Home/bin/java`
    private static func strippingFirstComponent(_ name: String) -> String {
        guard let slash = name.firstIndex(of: "/") else { return "" }
        return String(name[name.index(after: slash)...])
    }

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
