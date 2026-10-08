import Foundation
import Combine

/// Owns the account list and is the single authority on "which credentials do we
/// hand to the game right now".
///
/// Token refresh is centralised here rather than at the call site because a refresh
/// can happen from three places (app foregrounded, launch pressed, account list
/// opened) and they must not race — two concurrent refreshes would invalidate each
/// other's refresh token and sign the user out.
@MainActor
final class AccountManager: ObservableObject {
    static let shared = AccountManager()

    @Published private(set) var accounts: [MinecraftAccount] = []
    @Published private(set) var selectedId: String?

    private var refreshTask: Task<MinecraftAccount, Error>?
    private let fm = FileManager.default

    private init() {
        load()
    }

    var selected: MinecraftAccount? {
        guard let id = selectedId else { return accounts.first }
        return accounts.first { $0.id == id } ?? accounts.first
    }

    var hasAccounts: Bool { !accounts.isEmpty }

    // MARK: - Selection

    func select(_ account: MinecraftAccount) {
        selectedId = account.id
        UserDefaults.standard.set(account.id, forKey: PrefKey.selectedAccount)
        save()
    }

    // MARK: - Mutations

    func addMicrosoft(_ account: MinecraftAccount) {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        if selectedId == nil { select(account) }
        save()
    }

    func addOffline(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let problem = MinecraftAccount.validateOfflineName(trimmed) {
            throw LauncherError.authFailed(stage: "创建离线账号", detail: problem)
        }

        let account = MinecraftAccount.offline(name: trimmed)
        if accounts.contains(where: { $0.username.lowercased() == trimmed.lowercased() }) {
            throw LauncherError.authFailed(
                stage: "创建离线账号",
                detail: "已经有同名账号了。"
            )
        }
        accounts.append(account)
        if selectedId == nil { select(account) }
        save()
        LogConsole.shared.info("已创建离线账号：\(trimmed)（UUID \(account.uuid)）")
    }

    func remove(_ account: MinecraftAccount) {
        accounts.removeAll { $0.id == account.id }
        KeychainStore.clearTokens(accountId: account.id)
        if selectedId == account.id {
            selectedId = accounts.first?.id
            UserDefaults.standard.set(selectedId, forKey: PrefKey.selectedAccount)
        }
        save()
    }

    func update(_ account: MinecraftAccount) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        accounts[index] = account
        save()
    }

    // MARK: - Credentials

    /// Returns an account whose access token is valid, refreshing when needed.
    ///
    /// Call this immediately before assembling a launch configuration — never cache
    /// the result across a launch, because the token may have expired since.
    func credentials(for account: MinecraftAccount) async throws -> MinecraftAccount {
        switch account.kind {
        case .offline:
            // Nothing to refresh; the UUID is derived, not issued.
            return account

        case .microsoft:
            if !account.isExpired, KeychainStore.accessToken(accountId: account.id) != nil {
                return account
            }
            return try await refresh(account)
        }
    }

    private func refresh(_ account: MinecraftAccount) async throws -> MinecraftAccount {
        // Join an in-flight refresh for the same account instead of starting a
        // second one, which would burn the single-use refresh token.
        if let existing = refreshTask {
            return try await existing.value
        }

        let task = Task<MinecraftAccount, Error> { [account] in
            LogConsole.shared.info("正在刷新「\(account.username)」的登录令牌…")
            return try await MicrosoftAuth.refresh(account: account) { stage in
                // Stage updates are informational; the console shows them so a slow
                // network does not look like a hang.
                Task { @MainActor in
                    LogConsole.shared.append(.debug, "登录流程：\(stage.rawValue)")
                }
            }
        }
        refreshTask = task

        do {
            let updated = try await task.value
            refreshTask = nil
            update(updated)
            LogConsole.shared.info("令牌刷新成功。")
            return updated
        } catch {
            refreshTask = nil
            LogConsole.shared.error("令牌刷新失败：\(error.localizedDescription)")
            throw error
        }
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var accounts: [MinecraftAccount]
        var selectedId: String?
    }

    private func save() {
        let store = Store(accounts: accounts, selectedId: selectedId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(store)
            try data.write(to: LauncherPath.accountsFile, options: .atomic)
        } catch {
            LogConsole.shared.error("保存账号列表失败：\(error.localizedDescription)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: LauncherPath.accountsFile) else {
            selectedId = UserDefaults.standard.string(forKey: PrefKey.selectedAccount)
            return
        }
        guard let store = try? JSONDecoder().decode(Store.self, from: data) else {
            LogConsole.shared.warning("账号文件无法解析，已忽略。文件位置：accounts.json")
            return
        }
        accounts = store.accounts
        selectedId = store.selectedId
            ?? UserDefaults.standard.string(forKey: PrefKey.selectedAccount)
            ?? accounts.first?.id

        // Verify the keychain still holds tokens for live accounts. A device
        // restore can leave accounts.json behind without the keychain entries.
        for account in accounts where account.kind == .microsoft {
            if KeychainStore.refreshToken(accountId: account.id) == nil {
                LogConsole.shared.warning(
                    "账号「\(account.username)」的凭据已丢失（可能来自其他设备的备份），需要重新登录。"
                )
            }
        }
    }
}
