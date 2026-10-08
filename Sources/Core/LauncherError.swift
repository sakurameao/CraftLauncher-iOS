import Foundation

/// Errors that can surface to the user. `errorDescription` is written for a player,
/// not a developer, because these strings are shown verbatim in the UI.
enum LauncherError: LocalizedError {
    case jitUnavailable
    case runtimeMissing(tag: String, requiredMajor: Int, availableVersions: String)
    case runtimeCorrupt(tag: String, detail: String)
    case versionJSONMissing(String)
    case versionJSONMalformed(String, underlying: String)
    case manifestUnreachable(underlying: String)
    case downloadFailed(url: String, status: Int)
    case checksumMismatch(path: String, expected: String, actual: String)
    case diskFull
    case notAuthenticated
    case accountOwnsNoGame(String)
    case authFailed(stage: String, detail: String)
    case xboxError(code: Int, message: String)
    case jvmLaunchRefused(String)
    case instanceInUse(String)
    case unsupportedArchive(String)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .jitUnavailable:
            return """
            这台设备没有开启 JIT，Java 虚拟机无法启动。

            iOS 默认禁止应用在运行时生成可执行代码，而 Minecraft 必须依赖 JIT 才能运行。\
            请用 TrollStore、越狱设备，或用 SideStore / SideJITServer 附加调试器后再启动。\
            详见 docs/JIT.md。
            """
        case let .runtimeMissing(tag, major, available):
            // Two very different causes, and conflating them sends the user off to
            // "install a runtime" when none exists to install.
            if available.isEmpty {
                return """
                找不到任何 Java 运行时，App 包可能不完整。

                请在工程根目录运行 Scripts/bootstrap-runtime.sh 后重新构建。
                """
            }
            return """
            这个版本需要 Java \(major)，但本启动器只内置了：\(available)。

            Java 21 及以上没有可公开获取的 iOS 构建，所以 1.20.5 及更新的版本暂时无法启动。\
            目前能玩的版本范围是 1.16.5 及更早（Java 8）和 1.17 – 1.20.4（Java 17）。

            详见 docs/JAVA-RUNTIMES.md。
            """
        case let .runtimeCorrupt(tag, detail):
            return "Java 运行时「\(tag)」已损坏：\(detail)。建议删除后重新安装。"
        case let .versionJSONMissing(id):
            return "缺少版本「\(id)」的元数据文件，请到「版本」页重新下载。"
        case let .versionJSONMalformed(id, underlying):
            return "版本「\(id)」的元数据无法解析：\(underlying)"
        case let .manifestUnreachable(underlying):
            return "无法连接 Mojang 版本服务器：\(underlying)。请检查网络或代理设置。"
        case let .downloadFailed(url, status):
            return "下载失败（HTTP \(status)）：\(url)"
        case let .checksumMismatch(path, expected, actual):
            let short = { (s: String) in String(s.prefix(12)) }
            return "文件校验失败：\((path as NSString).lastPathComponent)\n期望 \(short(expected))… 实际 \(short(actual))…\n文件可能下载不完整，请重试。"
        case .diskFull:
            return "存储空间不足。一个现代版本的 Minecraft 及其资源需要约 1.5 GB，请清理后重试。"
        case .notAuthenticated:
            return "请先登录一个账号。"
        case let .accountOwnsNoGame(name):
            return "账号「\(name)」没有 Minecraft: Java Edition 的拥有权，将以 Demo 模式启动。"
        case let .authFailed(stage, detail):
            return "登录失败（\(stage)）：\(detail)"
        case let .xboxError(code, message):
            return "Xbox Live 拒绝了本次登录：\(message)（错误码 \(code)）"
        case let .jvmLaunchRefused(detail):
            return "JVM 拒绝启动：\(detail)"
        case let .instanceInUse(name):
            return "实例「\(name)」正在被另一个版本使用，请先关闭游戏。"
        case let .unsupportedArchive(name):
            return "无法识别整合包格式：\(name)。支持 .mrpack（Modrinth）与含 manifest.json 的 .zip（CurseForge）。"
        case .cancelled:
            return "操作已取消。"
        }
    }
}

/// Xbox Live 的 `XErr` 值映射。这些数字来自 XSTS 端点，含义不直观，
/// 直接翻译成可操作的提示比把错误码丢给用户有用得多。
enum XboxAuthError {
    static func message(forXErr code: Int) -> String {
        switch code {
        case 2148916227:
            return "这个微软账号没有绑定 Xbox 账号，请先到 xbox.com 创建。"
        case 2148916233:
            return "这个账号没有 Xbox 档案，请先登录 xbox.com 完成注册。"
        case 2148916235:
            return "你所在的地区不支持 Xbox Live。"
        case 2148916236, 2148916237:
            return "需要先完成年龄验证。"
        case 2148916238:
            return "这是未成年账号，需要由家庭组中的成年人先完成授权。"
        default:
            return "未知的 Xbox 错误。"
        }
    }
}
