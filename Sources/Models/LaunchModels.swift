import Foundation

/// Graphics backend passed to the runtime as `POJAV_RENDERER` plus the
/// matching `-Dorg.lwjgl.opengl.libname`.
///
/// These names are the runtime's own identifiers — they select which libGL
/// implementation the Java side loads, so they cannot be renamed freely.
enum RendererBackend: String, CaseIterable, Identifiable, Codable {
    /// Metal via ANGLE. The only correct choice for Minecraft 1.20.2+.
    case angleMetal = "libOSMesa.dylib"
    /// GL4ES over the system GL stack. Best compatibility for 1.12–1.20.1.
    case gl4es = "libgl4es_114.dylib"
    /// Vulkan through MoltenVK. Experimental; needed by some shader packs.
    case moltenVK = "libOSMesa.dylib"
    /// Let the runtime pick.
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .angleMetal: return "ANGLE → Metal（推荐）"
        case .gl4es: return "GL4ES → OpenGL ES"
        case .moltenVK: return "MoltenVK → Vulkan"
        case .auto: return "自动选择"
        }
    }

    var detail: String {
        switch self {
        case .angleMetal: return "把 OpenGL 翻译成 Metal，兼容 1.20.2 及以上版本，性能最好。"
        case .gl4es: return "老牌转译层，对 1.20.1 及更早版本更稳。"
        case .moltenVK: return "实验性。部分光影需要它。"
        case .auto: return "由运行时按游戏版本决定。"
        }
    }
}

/// Everything the launch pipeline needs. Built by the UI, consumed by
/// `LaunchPipeline`, and the only place `JVMArguments` reads from.
struct LaunchConfiguration {
    var instanceName: String
    var versionId: String

    // Account
    var username: String
    var uuid: String
    var accessToken: String
    var userType: String
    var xuid: String
    var clientId: String
    var isDemo: Bool

    // Runtime
    var javaHome: URL
    var javaMajorVersion: Int
    var allocatedMemoryMB: Int
    var customJVMArgs: [String]
    var customEnvVars: [String: String]

    // Display
    var renderer: RendererBackend
    var width: Int
    var height: Int
    var resolutionScale: Double

    // Session
    var launcherName: String = "CraftLauncher"
    var launcherVersion: String = Bundle.main.appVersion
    var quickPlaySingleplayer: String?

    /// Feature flags for the rule engine, derived from the config rather than
    /// hard-coded so `--demo` and `--width/--height` are emitted only when true.
    var featureFlags: RuleEnvironment.FeatureFlags {
        var flags = RuleEnvironment.FeatureFlags()
        flags.isDemoUser = isDemo
        flags.hasCustomResolution = true
        return flags
    }
}

/// Which stage a launch is in. Drives the progress UI and the log prefix.
enum LaunchStage: Equatable {
    case idle
    case checkingRuntime
    case readingVersion
    /// One case for all downloads rather than one per category.
    ///
    /// The launcher used to report libraries / assets / client separately, which
    /// meant hand-keeping three batches in the pipeline. Adding a fourth category
    /// (the Log4j config) silently skipped it. `ResourceDownloader.execute` now
    /// walks the whole plan, so the UI only needs to know "downloading".
    case downloading(done: Int, total: Int)
    case preparingNatives
    case startingJVM
    case running
    case exited(code: Int32)

    var label: String {
        switch self {
        case .idle: return "就绪"
        case .checkingRuntime: return "检查 Java 运行时"
        case .readingVersion: return "读取版本信息"
        case let .downloading(done, total): return "下载文件 \(done)/\(total)"
        case .preparingNatives: return "准备本地库"
        case .startingJVM: return "启动 Java 虚拟机"
        case .running: return "游戏运行中"
        case let .exited(code): return code == 0 ? "已退出" : "异常退出（代码 \(code)）"
        }
    }

    var isBusy: Bool {
        switch self {
        case .idle, .running, .exited: return false
        default: return true
        }
    }
}

/// A named game profile. Each instance has its own `mods/`, `saves/`, and options,
/// which is what makes "one instance for vanilla, one for the modpack" possible.
struct GameInstance: Codable, Identifiable, Equatable {
    var id: String { name }
    var name: String
    var versionId: String
    var javaMajorOverride: Int?
    var memoryMBOverride: Int?
    var createdAt: Date
    var notes: String

    static func new(name: String, versionId: String) -> GameInstance {
        GameInstance(
            name: name,
            versionId: versionId,
            javaMajorOverride: nil,
            memoryMBOverride: nil,
            createdAt: Date(),
            notes: ""
        )
    }

    /// Directories an instance owns. Created eagerly so the Files app shows a
    /// sensible tree before the first launch.
    func ensureDirectories() {
        for dir in [
            LauncherPath.instance(name),
            LauncherPath.modsDir(instance: name),
            LauncherPath.resourcePacksDir(instance: name),
            LauncherPath.shaderPacksDir(instance: name),
            LauncherPath.savesDir(instance: name),
            LauncherPath.configDir(instance: name),
            LauncherPath.nativesDir(instance: name),
        ] {
            LauncherPath.ensureDirectory(dir)
        }
    }
}

/// Mod loader a version was produced by. Detected from the version id and the
/// library list rather than asked of the user.
enum ModLoaderKind: String, Codable, CaseIterable {
    case vanilla = "原版"
    case fabric = "Fabric"
    case forge = "Forge"
    case quilt = "Quilt"
    case optifine = "OptiFine"
    case neoForge = "NeoForge"

    /// Which subdirectory the loader reads mods from. Fabric and Quilt both use
    /// `mods/`, but NeoForge 1.20.2+ moved to `mods/` as well — only Forge 1.12
    /// and the legacy `coremods` case differ, and those are handled in the loader
    /// itself.
    var modDirectory: String { "mods" }

    static func detect(versionId: String, libraries: [Library]) -> ModLoaderKind {
        let id = versionId.lowercased()
        if libraries.contains(where: { $0.groupId == "net.neoforged" }) { return .neoForge }
        if libraries.contains(where: { $0.groupId == "net.minecraftforge" }) { return .forge }
        if libraries.contains(where: { $0.groupId == "org.quiltmc" }) { return .quilt }
        if libraries.contains(where: { $0.groupId == "net.fabricmc" }) { return .fabric }
        if id.contains("optifine") { return .optifine }
        if id.contains("neoforge") { return .neoForge }
        if id.contains("forge") { return .forge }
        if id.contains("quilt") { return .quilt }
        if id.contains("fabric") { return .fabric }
        return .vanilla
    }
}

extension Bundle {
    var appVersion: String {
        let short = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short)+\(build)"
    }
}
