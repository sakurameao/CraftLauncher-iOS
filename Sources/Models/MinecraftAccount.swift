import Foundation

/// A launcher account. The struct itself is persisted to `accounts.json`; the
/// secrets (`accessToken`, `refreshToken`) never live here — they are written to
/// the keychain under `id` and fetched on demand.
struct MinecraftAccount: Codable, Identifiable, Equatable {
    enum Kind: String, Codable {
        /// Full Microsoft/Xbox Live account. Supports online servers.
        case microsoft
        /// Name-only identity. Works for single player and offline-mode servers.
        case offline
    }

    /// Stable identity. For Microsoft accounts this is the Xbox user hash (`xuid`);
    /// for offline accounts it is the derived UUID.
    let id: String
    var kind: Kind
    var username: String
    var uuid: String
    /// Xbox gamertag, when it differs from the in-game name.
    var xboxGamertag: String?
    var profilePictureURL: String?
    /// Unix seconds. Used to decide whether a refresh is needed.
    var expiresAt: TimeInterval

    /// Set when the account authenticates but owns no copy of the game; the client
    /// is then started with `--demo`.
    var isDemo: Bool

    var isExpired: Bool {
        Date().timeIntervalSince1970 >= expiresAt
    }

    /// The `userType` string the game expects in its account payload.
    var userType: String {
        kind == .microsoft ? "msa" : "legacy"
    }

    // MARK: - Construction

    static func offline(name: String) -> MinecraftAccount {
        let uuid = UUIDUtil.offlineUUID(for: name)
        return MinecraftAccount(
            id: uuid,
            kind: .offline,
            username: name,
            uuid: uuid,
            xboxGamertag: nil,
            profilePictureURL: nil,
            // Offline accounts never expire.
            expiresAt: .greatestFiniteMagnitude,
            isDemo: false
        )
    }

    /// Minecraft enforces 3–16 characters and an ASCII-only alphabet for names.
    /// Validating up front gives a clear message instead of a server-side kick.
    static func validateOfflineName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 { return "名字至少要 3 个字符。" }
        if trimmed.count > 16 { return "名字最多 16 个字符。" }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_")
        if trimmed.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return "只能使用字母、数字和下划线。"
        }
        return nil
    }

    /// Avatar for the UI. Offline accounts get a deterministic identicon via
    /// mc-heads, which also works for any valid UUID.
    var avatarURL: URL? {
        if let s = profilePictureURL, let u = URL(string: s) { return u }
        return URL(string: "https://mc-heads.net/avatar/\(uuid)/128")
    }
}

/// On-disk account list.
struct AccountStore: Codable {
    var accounts: [MinecraftAccount] = []
    var selectedId: String?

    var selected: MinecraftAccount? {
        guard let id = selectedId else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }
}
