import Foundation
import Combine

/// Global, cross-screen state: which instance is active and which version it runs.
///
/// Kept separate from the individual screen view models so that changing the
/// selected version on the Versions tab is immediately reflected on Home, without
/// either screen knowing about the other.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var activeInstance: GameInstance
    @Published var isReady = false

    /// Set when a launch fails in a way the user must act on.
    @Published var alert: LauncherAlert?

    struct LauncherAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let isDestructive: Bool
    }

    private let fm = FileManager.default

    private init() {
        // Placeholder; `start()` replaces it once the directory tree exists.
        activeInstance = GameInstance.new(name: "default", versionId: "")
    }

    /// Called once from the app entry point.
    func start() {
        guard !isReady else { return }

        LauncherPath.bootstrapDirectoryTree()
        migrateLegacyLayoutIfNeeded()

        activeInstance = loadOrCreateInstance()
        activeInstance.ensureDirectories()

        UserDefaults.standard.set(activeInstance.name, forKey: PrefKey.activeInstance)

        isReady = true
        LogConsole.shared.info("启动器就绪，工作目录：\(LauncherPath.launcherRoot.path)")

        Task {
            // Runtimes live inside the app bundle, so there is nothing to install —
            // only a scan to perform.
            JavaRuntimeManager.shared.refresh()
            VersionManager.shared.loadIfNeeded()
        }
    }

    func select(_ instance: GameInstance) {
        activeInstance = instance
        instance.ensureDirectories()
        UserDefaults.standard.set(instance.name, forKey: PrefKey.activeInstance)
    }

    func updateActiveVersion(_ versionId: String) {
        activeInstance.versionId = versionId
        saveInstances()
    }

    // MARK: - Instances

    @Published private(set) var instances: [GameInstance] = []

    func loadInstances() {
        let url = instancesFile
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([GameInstance].self, from: data)
        else {
            instances = [activeInstance]
            return
        }
        instances = decoded
    }

    func createInstance(name: String, versionId: String) {
        let cleaned = LauncherPath.sanitize(name)
        guard !instances.contains(where: { $0.name == cleaned }) else {
            alert = LauncherAlert(
                title: "实例已存在",
                message: "已经有名为「\(cleaned)」的实例了，请换一个名字。",
                isDestructive: false
            )
            return
        }

        let instance = GameInstance.new(name: cleaned, versionId: versionId)
        instance.ensureDirectories()
        instances.append(instance)
        saveInstances()
        LogConsole.shared.info("已创建实例「\(cleaned)」。")
    }

    func deleteInstance(_ instance: GameInstance) {
        guard instances.count > 1 else {
            alert = LauncherAlert(
                title: "无法删除",
                message: "至少要保留一个实例。",
                isDestructive: false
            )
            return
        }
        instances.removeAll { $0.name == instance.name }
        try? fm.removeItem(at: LauncherPath.instance(instance.name))

        if activeInstance.name == instance.name, let first = instances.first {
            select(first)
        }
        saveInstances()
        LogConsole.shared.info("已删除实例「\(instance.name)」及其存档与 Mod。")
    }

    func saveInstances() {
        var list = instances
        if let index = list.firstIndex(where: { $0.name == activeInstance.name }) {
            list[index] = activeInstance
        } else {
            list.append(activeInstance)
        }
        instances = list

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(list) else { return }
        try? data.write(to: instancesFile, options: .atomic)
    }

    private var instancesFile: URL {
        LauncherPath.launcherRoot.appendingPathComponent("instances.json")
    }

    // MARK: - Bootstrap

    private func loadOrCreateInstance() -> GameInstance {
        loadInstances()

        let preferredName = UserDefaults.standard.string(forKey: PrefKey.activeInstance)
        if let preferredName, let match = instances.first(where: { $0.name == preferredName }) {
            return match
        }
        if let first = instances.first { return first }

        // First run: seed a `default` instance, and pick the newest release as its
        // version so the Home screen has something actionable immediately.
        let latest = UserDefaults.standard.string(forKey: "launcher.lastKnownRelease") ?? ""
        let instance = GameInstance.new(name: "default", versionId: latest)
        instance.ensureDirectories()
        instances = [instance]
        saveInstances()
        return instance
    }

    /// Moves a pre-1.0 layout under `Documents/instances` if one is found.
    ///
    /// Cheap insurance for anyone who tried an early build: the game directory used
    /// to sit directly in Documents, and silently losing saves would be a serious
    /// regression.
    private func migrateLegacyLayoutIfNeeded() {
        let legacySaves = fm.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent(".minecraft/saves")
        guard let legacySaves, fm.fileExists(atPath: legacySaves.path) else { return }

        let destination = LauncherPath.savesDir(instance: "default")
        guard !fm.fileExists(atPath: destination.path) else { return }

        LauncherPath.ensureDirectory(destination)
        try? fm.moveItem(at: legacySaves, to: destination)
        LogConsole.shared.info("已将旧版存档迁移到 instances/default/saves。")
    }
}
