import Foundation

/// Live sign-in. Uses the same public client id the official launchers use for
/// the device-code / auth-code flow, so no Azure application registration is
/// needed and no client secret exists to leak.
///
/// The full chain, and why each hop exists:
///
/// ```
/// login.live.com/oauth20_token.srf        → Microsoft access + refresh token
///   └─ user.auth.xboxlive.com/authenticate → Xbox Live token (XBL)
///        └─ xsts.auth.xboxlive.com/authorize
///             ├─ relying party rp://api.minecraftservices.com/ → Minecraft login
///             └─ relying party http://xboxlive.com            → gamertag, avatar
/// ```
///
/// Microsoft's OAuth grants an identity; Xbox Live converts it into a gaming
/// identity; XSTS is the security token service that authorises that identity for
/// a specific relying party. Minecraft then accepts the XSTS token and issues its
/// own access token, which is what actually goes on the command line.
struct MicrosoftAuth {

    /// Public client id for the "Minecraft Launcher" application. It is not a
    /// secret — it ships inside every launcher.
    static let clientId = "00000000402b5328"
    static let scope = "service::user.auth.xboxlive.com::MBI_SSL"
    static let redirectURI = "https://login.live.com/oauth20_desktop.srf"

    /// A live account starts life as an authorization code the user copies out of
    /// the browser after signing in.
    static var authorizationURL: URL {
        var components = URLComponents(string: "https://login.live.com/oauth20_authorize.srf")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            // Forces the account picker instead of silently reusing a session.
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        return components.url!
    }

    enum Stage: String {
        case microsoftToken = "获取微软令牌"
        case xboxLive = "Xbox Live 认证"
        case xsts = "获取 XSTS 令牌"
        case xboxProfile = "读取 Xbox 档案"
        case minecraftToken = "获取 Minecraft 令牌"
        case minecraftProfile = "读取游戏档案"
    }

    // MARK: - Entry points

    /// Full sign-in from a freshly obtained authorization code.
    static func signIn(
        authorizationCode: String,
        progress: @escaping (Stage) -> Void
    ) async throws -> MinecraftAccount {
        progress(.microsoftToken)
        let ms = try await exchangeCodeForToken(code: authorizationCode)

        return try await completeSignIn(
            microsoftAccessToken: ms.accessToken,
            refreshToken: ms.refreshToken,
            progress: progress
        )
    }

    /// Forces a new access token for an account whose token expired.
    ///
    /// The refresh token is long-lived (months) while the Minecraft token lasts a
    /// day, so this path runs far more often than the sign-in path.
    static func refresh(
        account: MinecraftAccount,
        progress: @escaping (Stage) -> Void
    ) async throws -> MinecraftAccount {
        guard account.kind == .microsoft else { return account }

        guard let refreshToken = KeychainStore.refreshToken(accountId: account.id) else {
            throw LauncherError.authFailed(
                stage: Stage.microsoftToken.rawValue,
                detail: "钥匙串中没有刷新令牌，请重新登录。"
            )
        }

        progress(.microsoftToken)
        let ms = try await exchangeRefreshToken(refreshToken)

        var updated = try await completeSignIn(
            microsoftAccessToken: ms.accessToken,
            refreshToken: ms.refreshToken,
            progress: progress
        )
        // Keep the user's chosen display identity stable across refreshes.
        updated.xboxGamertag = updated.xboxGamertag ?? account.xboxGamertag
        return updated
    }

    private static func completeSignIn(
        microsoftAccessToken: String,
        refreshToken: String,
        progress: @escaping (Stage) -> Void
    ) async throws -> MinecraftAccount {
        progress(.xboxLive)
        let xbl = try await authenticateWithXboxLive(microsoftAccessToken)

        progress(.xsts)
        let minecraftXSTS = try await authorizeXSTS(
            xblToken: xbl.token,
            relyingParty: "rp://api.minecraftservices.com/"
        )

        // A second XSTS token for a different relying party: the gamertag lives
        // behind the generic Xbox Live audience, not the Minecraft one.
        progress(.xboxProfile)
        let profile = try await fetchXboxProfile(
            userHash: minecraftXSTS.userHash,
            xstsToken: try await authorizeXSTS(
                xblToken: xbl.token,
                relyingParty: "http://xboxlive.com"
            ).token
        )

        progress(.minecraftToken)
        let minecraft = try await loginWithXbox(
            userHash: minecraftXSTS.userHash,
            xstsToken: minecraftXSTS.token
        )

        progress(.minecraftProfile)
        let identity = try await fetchMinecraftProfile(accessToken: minecraft.accessToken)

        // The profile endpoint returns only `id` and `name`, so the stable id is
        // the Xbox user hash from the XSTS response — the same value the profile
        // step documents as the source of `auth_xuid`.
        let accountId = minecraftXSTS.userHash

        // Persist secrets first. If the keychain write fails the account would be
        // unusable, so report that rather than silently creating a broken entry.
        guard KeychainStore.storeTokens(
            accountId: accountId,
            accessToken: minecraft.accessToken,
            refreshToken: refreshToken
        ) else {
            throw LauncherError.authFailed(
                stage: "保存凭据",
                detail: "无法写入钥匙串。请确认设备没有启用限制性的钥匙串策略。"
            )
        }

        let account = MinecraftAccount(
            id: accountId,
            kind: .microsoft,
            username: identity.name ?? profile.gamertag ?? "Player",
            uuid: identity.uuid,
            xboxGamertag: profile.gamertag,
            profilePictureURL: identity.uuid.isEmpty
                ? profile.pictureURL
                : "https://mc-heads.net/head/\(identity.uuid)/120",
            // Minecraft tokens are valid for 24 hours; renew a little early.
            expiresAt: Date().timeIntervalSince1970 + minecraft.expiresIn - 300,
            isDemo: identity.isDemo
        )

        if identity.isDemo {
            LogConsole.shared.warning(
                "账号「\(account.username)」没有 Minecraft: Java Edition 的拥有权，将以 Demo 模式启动。"
            )
        } else {
            LogConsole.shared.info("已登录：\(account.username)（\(account.uuid)）")
        }
        return account
    }

    // MARK: - Step 1 · Microsoft token

    private struct MSTokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Int?
    }

    private static func exchangeCodeForToken(code: String) async throws -> (accessToken: String, refreshToken: String) {
        let trimmed = extractCode(from: code)
        guard !trimmed.isEmpty else {
            throw LauncherError.authFailed(stage: Stage.microsoftToken.rawValue, detail: "授权码为空。")
        }

        let response: MSTokenResponse = try await postForm(
            url: "https://login.live.com/oauth20_token.srf",
            fields: [
                "client_id": clientId,
                "code": trimmed,
                "grant_type": "authorization_code",
                "redirect_uri": redirectURI,
                "scope": scope,
            ],
            stage: Stage.microsoftToken
        )
        return (response.access_token, response.refresh_token)
    }

    private static func exchangeRefreshToken(_ token: String) async throws -> (accessToken: String, refreshToken: String) {
        let response: MSTokenResponse = try await postForm(
            url: "https://login.live.com/oauth20_token.srf",
            fields: [
                "client_id": clientId,
                "refresh_token": token,
                "grant_type": "refresh_token",
                "redirect_uri": redirectURI,
                "scope": scope,
            ],
            stage: Stage.microsoftToken
        )
        return (response.access_token, response.refresh_token)
    }

    /// The user pastes the whole `...?code=XYZ&...` URL as often as they paste the
    /// bare code, so accept both.
    private static func extractCode(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("code="),
              let components = URLComponents(string: trimmed),
              let code = components.queryItems?.first(where: { $0.name == "code" })?.value
        else {
            return trimmed
        }
        return code
    }

    // MARK: - Step 2 · Xbox Live

    private struct XBLResponse: Decodable {
        let Token: String
        let DisplayClaims: DisplayClaims

        struct DisplayClaims: Decodable {
            let xui: [[String: String]]
        }
    }

    private static func authenticateWithXboxLive(_ microsoftAccessToken: String) async throws -> (token: String, userHash: String) {
        let body: [String: Any] = [
            "Properties": [
                "AuthMethod": "RPS",
                "SiteName": "user.auth.xboxlive.com",
                // Without the `d=` prefix newer accounts are rejected with a
                // generic 401 that gives no hint about the cause.
                "RpsTicket": "d=\(microsoftAccessToken)",
            ],
            "RelyingParty": "http://auth.xboxlive.com",
            "TokenType": "JWT",
        ]

        let response: XBLResponse = try await postJSON(
            url: "https://user.auth.xboxlive.com/user/authenticate",
            body: body,
            stage: Stage.xboxLive
        )
        guard let userHash = response.DisplayClaims.xui.first?["uhs"] else {
            throw LauncherError.authFailed(stage: Stage.xboxLive.rawValue, detail: "响应中没有用户标识。")
        }
        return (response.Token, userHash)
    }

    // MARK: - Step 3 · XSTS

    private static func authorizeXSTS(xblToken: String, relyingParty: String) async throws -> (token: String, userHash: String) {
        let body: [String: Any] = [
            "Properties": [
                "SandboxId": "RETAIL",
                "UserTokens": [xblToken],
            ],
            "RelyingParty": relyingParty,
            "TokenType": "JWT",
        ]

        let response: XBLResponse = try await postJSON(
            url: "https://xsts.auth.xboxlive.com/xsts/authorize",
            body: body,
            stage: Stage.xsts
        )
        guard let userHash = response.DisplayClaims.xui.first?["uhs"] else {
            throw LauncherError.authFailed(stage: Stage.xsts.rawValue, detail: "响应中没有用户标识。")
        }
        return (response.Token, userHash)
    }

    // MARK: - Step 4 · Xbox profile (gamertag + avatar)

    private struct XboxProfileResponse: Decodable {
        let profileUsers: [ProfileUser]

        struct ProfileUser: Decodable {
            let settings: [Setting]
        }
        struct Setting: Decodable {
            let id: String
            let value: String
        }
    }

    private static func fetchXboxProfile(
        userHash: String,
        xstsToken: String
    ) async throws -> (gamertag: String?, pictureURL: String?) {
        var request = URLRequest(url: URL(string:
            "https://profile.xboxlive.com/users/me/profile/settings?settings=PublicGamerpic,Gamertag")!)
        request.setValue("2", forHTTPHeaderField: "x-xbl-contract-version")
        request.setValue("XBL3.0 x=\(userHash);\(xstsToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                // Not fatal: the gamertag is cosmetic and the MC profile below
                // supplies the real display name.
                return (nil, nil)
            }
            let decoded = try JSONDecoder().decode(XboxProfileResponse.self, from: data)
            let settings = decoded.profileUsers.first?.settings ?? []
            let gamertag = settings.first { $0.id == "Gamertag" }?.value
            let picture = settings.first { $0.id == "PublicGamerpic" }?.value
            return (gamertag, picture.map { "\($0)&h=120&w=120" })
        } catch {
            return (nil, nil)
        }
    }

    // MARK: - Step 5 · Minecraft token

    private struct MinecraftTokenResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private static func loginWithXbox(
        userHash: String,
        xstsToken: String
    ) async throws -> (accessToken: String, expiresIn: TimeInterval) {
        let body: [String: Any] = [
            "identityToken": "XBL3.0 x=\(userHash);\(xstsToken)"
        ]

        let response: MinecraftTokenResponse = try await postJSON(
            url: "https://api.minecraftservices.com/authentication/login_with_xbox",
            body: body,
            stage: Stage.minecraftToken
        )
        return (response.access_token, TimeInterval(response.expires_in))
    }

    // MARK: - Step 6 · Minecraft profile

    struct MinecraftIdentity {
        let uuid: String
        let name: String?
        let isDemo: Bool
    }

    /// Reads the game profile. A `404 NOT_FOUND` here means the account is valid
    /// but owns no copy of the game, which is a demo launch rather than an error.
    ///
    /// Note this endpoint returns only `id` and `name`. The Xbox user hash used as
    /// `auth_xuid` on the command line comes from the XSTS response instead.
    private static func fetchMinecraftProfile(accessToken: String) async throws -> MinecraftIdentity {
        var request = URLRequest(url: URL(string: "https://api.minecraftservices.com/minecraft/profile")!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0

        if status == 404 {
            // Valid credentials, no entitlement.
            return MinecraftIdentity(uuid: "", name: nil, isDemo: true)
        }

        guard (200..<300).contains(status) else {
            let detail = String(decoding: data, as: UTF8.self).prefix(300)
            throw LauncherError.authFailed(
                stage: Stage.minecraftProfile.rawValue,
                detail: "HTTP \(status)：\(detail)"
            )
        }

        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LauncherError.authFailed(
                stage: Stage.minecraftProfile.rawValue,
                detail: "无法解析游戏档案。"
            )
        }

        let rawUUID = root["id"] as? String ?? ""
        return MinecraftIdentity(
            // The endpoint returns the UUID without dashes; the game wants them.
            uuid: UUIDUtil.hyphenated(rawUUID),
            name: root["name"] as? String,
            isDemo: false
        )
    }

    // MARK: - HTTP plumbing

    private static func postForm<T: Decodable>(
        url: String,
        fields: [String: String],
        stage: Stage
    ) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data, stage: stage)
        return try decode(data, stage: stage)
    }

    private static func postJSON<T: Decodable>(
        url: String,
        body: [String: Any],
        stage: Stage
    ) async throws -> T {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CraftLauncher/\(Bundle.main.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        try checkStatus(response, data: data, stage: stage)
        return try decode(data, stage: stage)
    }

    private static func decode<T: Decodable>(_ data: Data, stage: Stage) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LauncherError.authFailed(
                stage: stage.rawValue,
                detail: "响应格式无法识别：\(String(decoding: data, as: UTF8.self).prefix(200))"
            )
        }
    }

    /// Translates the XSTS error body, which carries a numeric `XErr` that is the
    /// only way to tell "no Xbox account" from "underage account".
    private static func checkStatus(_ response: URLResponse, data: Data, stage: Stage) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard !(200..<300).contains(http.statusCode) else { return }

        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let xerr = root["XErr"] as? Int {
            throw LauncherError.xboxError(code: xerr, message: XboxAuthError.message(forXErr: xerr))
        }

        // Microsoft returns an OAuth error object on the token endpoint.
        if let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = root["error"] as? String {
            let description = root["error_description"] as? String ?? error
            throw LauncherError.authFailed(stage: stage.rawValue, detail: description)
        }

        throw LauncherError.authFailed(
            stage: stage.rawValue,
            detail: "HTTP \(http.statusCode)：\(String(decoding: data, as: UTF8.self).prefix(200))"
        )
    }
}
