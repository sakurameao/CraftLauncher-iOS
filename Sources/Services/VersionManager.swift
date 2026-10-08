import Foundation
import Combine

/// Drives the version browser: fetching the manifest, filtering, and installing or
/// removing a version.
@MainActor
final class VersionManager: ObservableObject {
    static let shared = VersionManager()

    enum Filter: String, CaseIterable, Identifiable {
        case release, snapshot, ancient, installed, all

        var id: String { rawValue }

        var label: String {
            switch self {
            case .release: return "正式版"
            case .snapshot: return "快照"
            case .ancient: return "远古版"
            case .installed: return "已安装"
            case .all: return "全部"
            }
        }
    }

    @Published private(set) var manifest: VersionManifest?
    @Published private(set) var installed: Set<String> = []
    @Published var filter: Filter = .release
    @Published var searchText: String = ""

    /// Per-version operation state, keyed by version id.
    enum Operation: Equatable {
        case idle
        case installing(progress: Double, label: String)
        case failed(String)
    }

    @Published private(set) var operations: [String: Operation] = [:]

    private var loadTask: Task<Void, Never>?
    private let fm = FileManager.default

    private init() {}

    // MARK: - Derived data

    /// Versions matching the current filter and search text.
    var visibleVersions: [VersionManifest.Entry] {
        guard let manifest else { return [] }

        let filtered = manifest.versions.filter { entry in
            switch filter {
            case .release: return entry.isRelease
            case .snapshot: return entry.isSnapshot
            case .ancient: return entry.isAncient
            case .installed: return installed.contains(entry.id)
            case .all: return true
            }
        }

        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return filtered }
        return filtered.filter { $0.id.lowercased().contains(query) }
    }

    var latestRelease: String? { manifest?.latest.release }
    var latestSnapshot: String? { manifest?.latest.snapshot }

    func isInstalled(_ versionId: String) -> Bool { installed.contains(versionId) }

    func operation(for versionId: String) -> Operation {
        operations[versionId] ?? .idle
    }

    // MARK: - Loading

    func loadIfNeeded(forceRefresh: Bool = false) {
        guard loadTask == nil else { return }
        refreshInstalled()

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let manifest = try await VersionService.shared.manifest(forceRefresh: forceRefresh)
                self.manifest = manifest

                // A locally installed version may no longer be in the manifest (an
                // old snapshot, or a deleted one). Surface it anyway so the user can
                // see and manage what is on disk.
                let manifestIds = Set(manifest.versions.map(\.id))
                let orphans = self.installed.subtracting(manifestIds)
                if !orphans.isEmpty {
                    LogConsole.shared.info("发现 \(orphans.count) 个不在官方列表中的本地版本：\(orphans.sorted().joined(separator: "、"))")
                }
            } catch {
                LogConsole.shared.error(error.localizedDescription)
            }
            self.loadTask = nil
        }
    }

    func refreshInstalled() {
        installed = VersionService.shared.installedVersionIds()
    }

    func reload() {
        loadTask?.cancel()
        loadTask = nil
        loadIfNeeded(forceRefresh: true)
    }

    // MARK: - Install

    /// Downloads everything a version needs to launch.
    func install(versionId: String) {
        guard operations[versionId] == nil || operation(for: versionId) == .idle else {
            LogConsole.shared.warning("\(versionId) 已在处理中。")
            return
        }

        setOperation(versionId, .installing(progress: 0, label: "准备中"))

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performInstall(versionId: versionId)
                self.refreshInstalled()
                self.setOperation(versionId, .idle)
                LogConsole.shared.info("版本 \(versionId) 安装完成。")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.setOperation(versionId, .failed(message))
                LogConsole.shared.error("安装 \(versionId) 失败：\(message)")
            }
        }
    }

    private func performInstall(versionId: String) async throws {
        setOperation(versionId, .installing(progress: 0.02, label: "读取版本信息"))

        let version = try await VersionService.shared.resolvedVersion(versionId: versionId)
        let assetIndex = try await VersionService.shared.assetIndex(for: version)

        setOperation(versionId, .installing(progress: 0.05, label: "计算需要的文件"))

        let plan = ResourceDownloader.shared.plan(
            version: version,
            assetIndex: assetIndex,
            // Version installs are instance-agnostic. The Log4j config is a ~1 KB
            // file that `LaunchPipeline` re-fetches into whichever instance is
            // actually launching, so planning it against `default` here is harmless
            // and keeps the shared install path simple.
            instanceName: "default",
            environment: .current,
            verifyAssets: UserDefaults.standard.object(forKey: PrefKey.generalCheckAssets) as? Bool ?? true
        )

        guard plan.totalFiles > 0 else {
            setOperation(versionId, .installing(progress: 1, label: "已是最新"))
            return
        }

        try FileUtil.requireFreeSpace(plan.totalBytes)

        let totalBytes = max(plan.totalBytes, 1)
        let downloaded = ByteCounter()

        let all = plan.libraries + plan.assets + (plan.clientJar.map { [$0] } ?? [])
        try await HTTPClient.shared.forEachConcurrent(
            all,
            maxConcurrent: UserDefaults.standard.object(
                forKey: PrefKey.generalMaxConcurrentDownloads
            ) as? Int ?? 6
        ) { item in
            try await HTTPClient.shared.download(
                url: item.remoteURL,
                to: item.destination,
                expectedSha1: item.sha1,
                expectedSize: item.size
            )
            let done = downloaded.add(Int64(item.size ?? 0))
            let fraction = min(Double(done) / Double(totalBytes), 0.99)
            Task { @MainActor in
                self.setOperation(versionId, .installing(
                    progress: fraction,
                    label: FileUtil.humanSize(done) + " / " + FileUtil.humanSize(totalBytes)
                ))
            }
        }

        if !plan.legacyAssetMapping.isEmpty {
            Task { @MainActor in
                self.setOperation(versionId, .installing(progress: 0.99, label: "展开旧版资源"))
            }
            try await ResourceDownloader.shared.execute(plan: plan) { _ in }
        }
    }

    // MARK: - Remove

    func uninstall(versionId: String) {
        let reclaimed = VersionService.shared.deleteVersion(versionId)
        // The in-memory metadata cache must forget it too, or a reinstall would
        // reuse the deleted document.
        Task { await VersionService.shared.invalidate(versionId: versionId) }

        refreshInstalled()
        operations.removeValue(forKey: versionId)
        LogConsole.shared.info("已删除版本 \(versionId)，释放 \(FileUtil.humanSize(reclaimed))。")
    }

    private func setOperation(_ versionId: String, _ operation: Operation) {
        if operation == .idle {
            operations.removeValue(forKey: versionId)
        } else {
            operations[versionId] = operation
        }
    }

    // MARK: - Storage accounting

    /// Bytes used by libraries and assets, which are shared across versions and are
    /// usually the bulk of the footprint.
    func sharedStorageBytes() -> (libraries: Int64, assets: Int64) {
        (
            FileUtil.directorySize(LauncherPath.libraries),
            FileUtil.directorySize(LauncherPath.assetObjects)
        )
    }

    func totalStorageBytes() -> Int64 {
        FileUtil.directorySize(LauncherPath.launcherRoot)
    }
}

/// Accumulates byte totals across concurrent download tasks.
private final class ByteCounter: @unchecked Sendable {
    private var total: Int64 = 0
    private let lock = NSLock()

    func add(_ bytes: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        total += bytes
        return total
    }
}
