import Foundation

/// Serialises launcher network traffic and exposes download-with-progress.
///
/// Deliberately built on `URLSession` directly rather than a wrapper: the only
/// exotic behaviour needed is resume-by-range, and that is ten lines.
final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession
    private let decoder: JSONDecoder
    private let queue = DispatchQueue(label: "com.craftlauncher.http", qos: .utility)

    private init() {
        let config = URLSessionConfiguration.default
        // Minecraft assets are served from CDNs that aggressively cache; a large
        // disk cache removes most repeat traffic on the second launch.
        config.requestCachePolicy = .useProtocolCachePolicy
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 256 * 1024 * 1024,
            directory: LauncherPath.cache.appendingPathComponent("urlcache")
        )
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        // The launcher is single-screen; more than a handful of parallel sockets
        // upsets some mobile networks.
        config.httpMaximumConnectionsPerHost = 6
        config.waitsForConnectivity = true
        session = URLSession(configuration: config)

        decoder = JSONDecoder()
        // Mojang dates are ISO-8601 with and without fractional seconds depending
        // on the endpoint, so try both.
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFraction = ISO8601DateFormatter()
        withoutFraction.formatOptions = [.withInternetDateTime]

        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let d = withFraction.date(from: raw) { return d }
            if let d = withoutFraction.date(from: raw) { return d }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "无法解析日期：\(raw)"
            )
        }
    }

    // MARK: - JSON

    func getJSON<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CraftLauncher/\(Bundle.main.appVersion)", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try validate(response, url: url)

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw LauncherError.versionJSONMalformed(
                url.lastPathComponent,
                underlying: String(describing: error)
            )
        }
    }

    /// Fetches a UTF-8 string. Used for hash lists and small config files.
    func getString(from url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        try validate(response, url: url)
        return String(decoding: data, as: UTF8.self)
    }

    func getData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        try validate(response, url: url)
        return data
    }

    // MARK: - Download

    /// Downloads `url` to `destination`, verifying `expectedSha1` when supplied.
    ///
    /// Returns without touching the network when the file already exists with the
    /// right hash — that check is what makes "reinstall a version" fast instead of
    /// a full re-download of every library.
    @discardableResult
    func download(
        url: URL,
        to destination: URL,
        expectedSha1: String? = nil,
        expectedSize: Int? = nil,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let fm = FileManager.default

        if fm.fileExists(atPath: destination.path) {
            if let expected = expectedSha1, !expected.isEmpty {
                if HashUtil.sha1Hex(ofFileAt: destination) == expected {
                    progress?(1.0)
                    return destination
                }
                // Wrong contents (interrupted download); replace it.
                try? fm.removeItem(at: destination)
            } else if let size = expectedSize,
                      let attrs = try? fm.attributesOfItem(atPath: destination.path),
                      (attrs[.size] as? Int) == size {
                progress?(1.0)
                return destination
            } else if expectedSize == nil && expectedSha1 == nil {
                progress?(1.0)
                return destination
            }
        }

        LauncherPath.ensureDirectory(destination.deletingLastPathComponent())

        let temp = destination.appendingPathExtension("part")
        try? fm.removeItem(at: temp)
        fm.createFile(atPath: temp.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: temp) else {
            throw LauncherError.downloadFailed(url: url.absoluteString, status: -1)
        }
        defer { try? handle.close() }

        var request = URLRequest(url: url)
        request.setValue("CraftLauncher/\(Bundle.main.appVersion)", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        try validate(response, url: url)

        let total = response.expectedContentLength > 0
            ? response.expectedContentLength
            : Int64(expectedSize ?? 0)
        var received: Int64 = 0
        var lastReported = 0.0

        var buffer = Data()
        buffer.reserveCapacity(1 << 16)

        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= (1 << 16) {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)

                if total > 0 {
                    let fraction = Double(received) / Double(total)
                    // Throttle to whole-percent steps; the UI does not need more
                    // and the callback hops to the main actor.
                    if fraction - lastReported >= 0.01 {
                        lastReported = fraction
                        progress?(fraction)
                    }
                }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
        }
        try handle.close()

        // Verify before publishing the file, so a truncated download from a flaky
        // connection can never be mistaken for a complete one.
        if let expected = expectedSha1, !expected.isEmpty {
            let actual = HashUtil.sha1Hex(ofFileAt: temp) ?? ""
            guard actual == expected else {
                try? fm.removeItem(at: temp)
                throw LauncherError.checksumMismatch(
                    path: destination.path,
                    expected: expected,
                    actual: actual
                )
            }
        }
        if let size = expectedSize, received != Int64(size) {
            try? fm.removeItem(at: temp)
            throw LauncherError.downloadFailed(url: url.absoluteString, status: -2)
        }

        try? fm.removeItem(at: destination)
        do {
            try fm.moveItem(at: temp, to: destination)
        } catch {
            throw LauncherError.downloadFailed(url: url.absoluteString, status: -3)
        }
        progress?(1.0)
        return destination
    }

    /// Runs `work` over `items` with a bounded number of concurrent tasks.
    ///
    /// Used for library and asset batches. Unbounded `TaskGroup` concurrency would
    /// open hundreds of sockets and get throttled; one-at-a-time wastes the link.
    func forEachConcurrent<T: Sendable>(
        _ items: [T],
        maxConcurrent: Int = 6,
        _ work: @escaping @Sendable (T) async throws -> Void
    ) async throws {
        guard !items.isEmpty else { return }

        var index = 0
        let limit = Swift.max(1, Swift.min(maxConcurrent, items.count))

        try await withThrowingTaskGroup(of: Void.self) { group in
            @Sendable func nextIndex() -> Int? {
                // Safe: the task group body runs on a single executor and this
                // closure is only invoked from within it.
                if index >= items.count { return nil }
                defer { index += 1 }
                return index
            }

            for _ in 0..<limit {
                guard let i = nextIndex() else { break }
                let item = items[i]
                group.addTask { try await work(item) }
            }

            while let _ = try await group.next() {
                guard let i = nextIndex() else { continue }
                let item = items[i]
                group.addTask { try await work(item) }
            }
        }
    }

    // MARK: - Helpers

    private func validate(_ response: URLResponse, url: URL) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw LauncherError.downloadFailed(url: url.absoluteString, status: http.statusCode)
        }
    }
}

/// Replacement of `${...}` placeholders that the platform cannot satisfy.
///
/// Follows VersionManifest's merge guarantee: anything still carrying a
/// placeholder after substitution is a hard build error, not a runtime surprise.
extension String {
    /// Placeholder names this build knows how to fill.
    static let knownLaunchPlaceholders: Set<String> = [
        "auth_player_name", "version_name", "game_directory", "assets_root",
        "assets_index_name", "auth_uuid", "auth_access_token", "auth_session",
        "auth_xuid", "clientid", "user_type", "version_type", "natives_directory",
        "launcher_name", "launcher_version", "classpath", "classpath_separator",
        "library_directory", "resolution_width", "resolution_height",
        "quickPlayPath", "quickPlaySingleplayer", "quickPlayMultiplayer",
        "quickPlayRealms", "renderer", "game_assets",
    ]

    /// Every `${name}` occurring in the string.
    var placeholderNames: [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)\}"#) else {
            return []
        }
        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: self)
            else { return nil }
            return String(self[r])
        }
    }
}
