import SwiftUI
import UIKit

/// Everything configurable, grouped the way the questions come up in practice.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var runtimes = JavaRuntimeManager.shared
    @ObservedObject private var versions = VersionManager.shared

    var body: some View {
        NavigationStack {
            Form {
                DiagnosticsSection()
                RuntimeSection()
                MemorySection()
                RendererSection()
                DownloadSection()
                InstanceSection()
                MaintenanceSection()
                AboutSection()
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { runtimes.refresh() }
        }
    }
}

// MARK: - Diagnostics

/// JIT, entitlements and runtime-library status.
///
/// Placed first on purpose: if JIT is unavailable, nothing else in this screen
/// matters, and the user needs to know before they spend time downloading a version
/// that cannot run.
///
/// The entitlement rows exist because a certificate-based signer (全能签 and
/// friends) will silently drop anything it cannot issue, and the resulting failure
/// — "JIT activation failed" from SideJITServer — gives no hint about the cause.
/// Reading the effective entitlements turns that into a one-line diagnosis.
private struct DiagnosticsSection: View {
    @State private var jitStatus: RuntimeLauncher.JITStatus = .unknown
    @State private var entitlements: RuntimeLauncher.EntitlementReport?
    @State private var missingLibraries: [String] = []

    var body: some View {
        Section {
            HStack {
                Label("JIT 权限", systemImage: "bolt.fill")
                Spacer()
                switch jitStatus {
                case .enabled:
                    Tag(text: "已启用", tint: Theme.Palette.accent)
                case .disabled:
                    Tag(text: "未启用", tint: Theme.Palette.danger)
                case .unknown:
                    Tag(text: "未知", tint: Theme.Palette.warning)
                }
            }

            if jitStatus == .disabled {
                Text(diagnosisForMissingJIT)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.danger)
            }

            if let entitlements {
                entitlementRow(
                    title: "调试器附加许可",
                    detail: "get-task-allow",
                    granted: entitlements.getTaskAllow,
                    purpose: "SideJITServer / SideStore 靠它附加调试器来授予 JIT"
                )
                entitlementRow(
                    title: "加载外部动态库",
                    detail: "disable-library-validation",
                    granted: entitlements.libraryValidationDisabled,
                    purpose: "不满足就 dlopen 不了 Java 运行时"
                )
                entitlementRow(
                    title: "扩展内存上限",
                    detail: "com.apple.private.memorystatus",
                    granted: entitlements.extendedMemory,
                    purpose: "没有它时内存按物理内存 25% 分配（而非 40%），功能正常"
                )

                if !entitlements.libraryValidationDisabled {
                    Text("""
                    缺少加载外部动态库的权限。Java 运行时的 dylib 无法载入，游戏一定启动不了。
                    这通常意味着签名时权限被剥离了 —— 换一个「个人开发者证书」重新签名，
                    或者用 Xcode 直接运行 Debug 构建。
                    """)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.danger)
                }
            }

            HStack {
                Label("运行时库", systemImage: "shippingbox.fill")
                Spacer()
                if missingLibraries.isEmpty {
                    Tag(text: "完整", tint: Theme.Palette.accent)
                } else {
                    Tag(text: "缺少 \(missingLibraries.count) 个", tint: Theme.Palette.danger)
                }
            }

            if !missingLibraries.isEmpty {
                ForEach(missingLibraries, id: \.self) { path in
                    Text((path as NSString).lastPathComponent)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
                Text("重新运行 Scripts/bootstrap-runtime.sh 生成运行时依赖，然后重新构建。")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } header: {
            Text("运行环境")
        } footer: {
            Text("这几项读取的是签名实际生效的权限，不是源码里声明的 —— 签名工具剥离掉的权限在这里会显示为未授予。")
        }
        .onAppear {
            jitStatus = RuntimeLauncher.jitStatus
            entitlements = RuntimeLauncher.entitlements
            missingLibraries = RuntimeLauncher.missingDependencies()
        }
    }

    private func entitlementRow(
        title: String,
        detail: String,
        granted: Bool,
        purpose: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Tag(
                    text: granted ? "已授予" : "未授予",
                    tint: granted ? Theme.Palette.accent : Theme.Palette.warning
                )
            }
            Text(detail)
                .font(.system(size: 10).monospaced())
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(purpose)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }

    /// Says which of the two very different causes applies, based on whether the
    /// debugger attach is even possible for this install.
    private var diagnosisForMissingJIT: String {
        guard let entitlements else {
            return "当前进程没有 JIT 权限，Java 只能以解释模式运行。详见 docs/JIT.md。"
        }

        if !entitlements.getTaskAllow {
            return """
            当前进程没有 JIT 权限，而且缺少「调试器附加许可」，所以没有任何工具能给它开 JIT。

            原因通常是签名用的证书类型不对：企业证书 / 分发证书的描述文件里不含 \
            get-task-allow，签名工具（全能签这类无法注入权限的）只能把它丢掉。

            换「个人开发者证书」重新签名，或者用 Xcode 直接运行 Debug 构建，都能解决。
            """
        }

        return """
        当前进程还没有 JIT。你的签名是允许调试器附加的，所以可以开：

        在电脑或局域网上另一台设备上运行 SideJITServer，连同一个 Wi-Fi，\
        在手机上选中 CraftLauncher 点激活，然后从后台彻底划掉 App 再打开。

        也可以用本工程的脚本（需数据线）：Scripts/attach-jit.sh
        完整步骤见 docs/SIGNING.md。
        """
    }
}

// MARK: - Java runtime

private struct RuntimeSection: View {
    @ObservedObject private var runtimes = JavaRuntimeManager.shared

    @AppStorage(PrefKey.javaPreferredVersion) private var preferred: Int = 0
    @AppStorage(PrefKey.javaSelectedRuntime) private var selectedTag: String = ""

    @State private var showImporter = false

    var body: some View {
        Section {
            if runtimes.runtimes.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Palette.danger)
                    Text("App 包内没有 Java 运行时")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.danger)
                }
                Text("请运行 Scripts/bootstrap-runtime.sh 生成 Runtime/java_runtimes/ 后重新构建。")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else {
                ForEach(runtimes.runtimes) { runtime in
                    Button {
                        selectedTag = selectedTag == runtime.tag ? "" : runtime.tag
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(runtime.displayName)
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    if !runtime.isUsable {
                                        Tag(text: "不可用", tint: Theme.Palette.danger)
                                    }
                                }
                                Text("\(runtime.vendor) · \(runtime.architecture) · \(runtime.tag)")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                if let reason = runtime.unusableReason {
                                    Text(reason)
                                        .font(.caption2)
                                        .foregroundStyle(Theme.Palette.danger)
                                }
                            }
                            Spacer()
                            if selectedTag == runtime.tag {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Theme.Palette.accent)
                            } else if selectedTag.isEmpty {
                                Tag(
                                    text: runtimes.isImported(runtime) ? "导入" : "内置",
                                    tint: Theme.Palette.textTertiary
                                )
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        // Bundled runtimes cannot be deleted: they are part of the
                        // app bundle, which is read-only. Offering the swipe would
                        // just produce a failure.
                        if runtimes.isImported(runtime) {
                            Button("删除", role: .destructive) {
                                runtimes.removeImportedRuntime(tag: runtime.tag)
                            }
                        }
                    }
                }
            }

            Picker("优先使用", selection: $preferred) {
                Text("自动（按游戏版本）").tag(0)
                ForEach(runtimes.runtimes) { runtime in
                    Text("Java \(runtime.majorVersion)").tag(runtime.majorVersion)
                }
            }

            Button {
                showImporter = true
            } label: {
                Label("导入 JDK 压缩包", systemImage: "square.and.arrow.down")
            }
        } header: {
            Text("Java 运行时")
        } footer: {
            Text("""
            运行时直接放在 App 包里，不在安装后释放，所以它们随 App 一起被签名 —— \
            这也意味着它们是只读的，不能删除。

            支持范围：1.16.5 及更早用 Java 8，1.17 – 1.20.4 用 Java 17。
            1.20.5 及更新的版本需要 Java 21，而 iOS 上没有可公开获取的 Java 21 构建，\
            所以暂时无法启动。

            启动器取「满足要求的最小版本」而不是最新版本 —— 老版本在新 JDK 上反而会崩。
            点一行可以把它锁定为默认运行时，再点一次取消。
            """)
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.archive, .zip],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                Task {
                    do {
                        _ = try await runtimes.importRuntime(from: url)
                    } catch {
                        LogConsole.shared.error(
                            (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Memory

private struct MemorySection: View {
    @AppStorage(PrefKey.javaAutoMemory) private var autoMemory = true
    @AppStorage(PrefKey.javaAllocatedMemory) private var allocated = 2048

    private var physicalGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    var body: some View {
        Section {
            Toggle("自动分配内存", isOn: $autoMemory)

            if autoMemory {
                LabeledValue(
                    label: "本机物理内存",
                    value: String(format: "%.1f GB", physicalGB)
                )
                LabeledValue(
                    label: "预计分配",
                    value: "\(Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576 * 0.25).rounded())) MB",
                    monospaced: true
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("分配上限")
                            .font(.subheadline)
                        Spacer()
                        Text("\(allocated) MB")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(Theme.Palette.accent)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(allocated) },
                            set: { allocated = Int($0 / 128) * 128 }
                        ),
                        in: 512...4096,
                        step: 128
                    )
                    .tint(Theme.Palette.accent)
                }
            }
        } header: {
            Text("内存")
        } footer: {
            Text("""
            分得太少会卡在地形生成，分得太多会被 iOS 直接杀掉进程（看起来像闪退）。\
            手机建议 2 GB 以内；4 GB 内存的设备用自动值最稳。
            """)
        }
    }
}

// MARK: - Renderer

private struct RendererSection: View {
    @AppStorage(PrefKey.rendererBackend) private var backend = RendererBackend.auto.rawValue

    var body: some View {
        Section {
            Picker("图形后端", selection: $backend) {
                ForEach(RendererBackend.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }

            if let selected = RendererBackend(rawValue: backend) {
                Text(selected.detail)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } header: {
            Text("图形")
        } footer: {
            Text("""
            1.20.2 及以后必须用 ANGLE，因为游戏要求 OpenGL 核心模式，GL4ES 提供不了。\
            1.20.1 及更早用 GL4ES 更稳。改完需要重新启动游戏。
            """)
        }
    }
}

// MARK: - Downloads

private struct DownloadSection: View {
    @AppStorage(PrefKey.generalCheckAssets) private var verifyAssets = true
    @AppStorage(PrefKey.generalMaxConcurrentDownloads) private var concurrency = 6
    @AppStorage(PrefKey.generalCloseConsoleOnLaunch) private var closeConsole = false

    var body: some View {
        Section {
            Toggle("校验资源文件完整性", isOn: $verifyAssets)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("并发下载数")
                        .font(.subheadline)
                    Spacer()
                    Text("\(concurrency)")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.Palette.accent)
                }
                Slider(
                    value: Binding(
                        get: { Double(concurrency) },
                        set: { concurrency = Int($0) }
                    ),
                    in: 1...12,
                    step: 1
                )
                .tint(Theme.Palette.accent)
            }
        } header: {
            Text("下载")
        } footer: {
            Text("""
            校验会对每个文件做 SHA-1 比对，能发现下载损坏，但第一次安装会明显变慢。\
            并发数太高在移动网络下反而更容易失败，6 是比较稳的值。
            """)
        }
    }
}

// MARK: - Instances

private struct InstanceSection: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var versions = VersionManager.shared

    @State private var showCreator = false
    @State private var newName = ""
    @State private var newVersion = ""
    @State private var pendingDeletion: GameInstance?

    var body: some View {
        Section {
            ForEach(appState.instances) { instance in
                Button {
                    appState.select(instance)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(instance.name)
                                .font(.subheadline)
                                .foregroundStyle(Theme.Palette.textPrimary)
                            Text(instance.versionId.isEmpty ? "未选择版本" : instance.versionId)
                                .font(.caption2)
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        Spacer()
                        if appState.activeInstance.name == instance.name {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Theme.Palette.accent)
                        }
                    }
                }
                .buttonStyle(.plain)
                .swipeActions(edge: .trailing) {
                    if appState.instances.count > 1 {
                        Button("删除", role: .destructive) {
                            pendingDeletion = instance
                        }
                    }
                }
            }

            Button {
                newName = ""
                newVersion = appState.activeInstance.versionId
                showCreator = true
            } label: {
                Label("新建实例", systemImage: "plus.rectangle.on.folder")
            }
        } header: {
            Text("游戏实例")
        } footer: {
            Text("每个实例有独立的 Mod、存档、资源包和设置。想同时玩原版和整合包，就建两个实例。")
        }
        .sheet(isPresented: $showCreator) {
            creatorSheet
        }
        .confirmationDialog(
            "删除实例「\(pendingDeletion?.name ?? "")」？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("连同存档一起删除", role: .destructive) {
                if let instance = pendingDeletion { appState.deleteInstance(instance) }
                pendingDeletion = nil
            }
            Button("取消", role: .cancel) { pendingDeletion = nil }
        } message: {
            Text("这个实例里的存档、Mod 和配置都会一起被删除，无法恢复。")
        }
    }

    private var creatorSheet: some View {
        NavigationStack {
            Form {
                Section("实例名") {
                    TextField("例如 modpack", text: $newName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                }
                Section("初始版本") {
                    if versions.installed.isEmpty {
                        Text("还没有已安装的版本，可以先创建实例，稍后再选版本。")
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    } else {
                        Picker("版本", selection: $newVersion) {
                            Text("暂不选择").tag("")
                            ForEach(versions.installed.sorted(by: >), id: \.self) { id in
                                Text(id).tag(id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("新建实例")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showCreator = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        appState.createInstance(name: newName, versionId: newVersion)
                        showCreator = false
                    }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Maintenance

private struct MaintenanceSection: View {
    @EnvironmentObject private var appState: AppState

    @State private var message: String?
    @State private var isWorking = false

    var body: some View {
        Section {
            Button {
                cleanUnusedAssets()
            } label: {
                Label("清理未使用的资源文件", systemImage: "sparkles")
            }
            .disabled(isWorking)

            Button {
                cleanCache()
            } label: {
                Label("清空下载缓存", systemImage: "trash")
            }
            .disabled(isWorking)

            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        } header: {
            Text("维护")
        } footer: {
            Text("""
            资源文件是所有版本共用的，版本删掉之后它们不会自动清理。\
            清理会扫描已安装版本实际用到的资源，其余删除。不会动到存档和 Mod。
            """)
        }
    }

    private func cleanUnusedAssets() {
        isWorking = true
        message = "正在扫描…"

        Task {
            var needed: Set<String> = []
            for versionId in VersionManager.shared.installed {
                guard let version = try? await VersionService.shared.resolvedVersion(versionId: versionId),
                      let index = try? await VersionService.shared.assetIndex(for: version)
                else { continue }
                for object in index.objects.values {
                    needed.insert(object.hash)
                }
            }

            let reclaimed = ResourceDownloader.shared.deleteUnusedAssets(keeping: needed)
            message = "已释放 \(FileUtil.humanSize(reclaimed))，保留 \(needed.count) 个资源文件。"
            isWorking = false
        }
    }

    private func cleanCache() {
        isWorking = true
        let size = FileUtil.directorySize(LauncherPath.cache)
        try? FileManager.default.removeItem(at: LauncherPath.cache)
        LauncherPath.bootstrapDirectoryTree()
        message = "已清空缓存，释放 \(FileUtil.humanSize(size))。"
        isWorking = false
    }
}

// MARK: - About

private struct AboutSection: View {
    @State private var showAcknowledgements = false

    var body: some View {
        Section {
            LabeledValue(label: "版本", value: Bundle.main.appVersion)
            LabeledValue(
                label: "工作目录",
                value: LauncherPath.launcherRoot.path,
                monospaced: true
            )
            LabeledValue(
                label: "存储占用",
                value: FileUtil.humanSize(FileUtil.directorySize(LauncherPath.launcherRoot)),
                monospaced: true
            )

            Button {
                showAcknowledgements = true
            } label: {
                Label("开源许可与致谢", systemImage: "doc.text")
            }
        } header: {
            Text("关于")
        } footer: {
            Text("""
            在「文件」App 里可以找到这个目录，直接把 jar 拖进去也能装 Mod。

            本启动器不包含任何 Minecraft 游戏文件。Java 运行时与图形转译层来自 \
            PojavLauncher 及其依赖项目，均为 GPL-3.0。Minecraft 是 Mojang Studios 的商标。
            """)
        }
        .sheet(isPresented: $showAcknowledgements) {
            AcknowledgementsView()
        }
    }
}

private struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    private let entries: [(String, String, String)] = [
        ("PojavLauncher", "https://github.com/PojavLauncherTeam/PojavLauncher_iOS",
         "iOS 版 Java 运行时、打补丁的 LWJGL 与启动桥接。GPL-3.0。"),
        ("Boardwalk", "https://github.com/PojavLauncherTeam/Boardwalk",
         "LWJGL 的 iOS 移植。GPL-3.0。"),
        ("Caciocavallo", "https://github.com/caciocavallo-silano",
         "不依赖 X11 的 AWT 实现，让 Swing 界面能跑起来。GPL-2.0。"),
        ("GL4ES", "https://github.com/ptitSeb/gl4es",
         "OpenGL 1.x/2.x 到 OpenGL ES 的转译层。MIT。"),
        ("ANGLE", "https://github.com/google/angle",
         "OpenGL ES 到 Metal 的转译层。BSD-3-Clause。"),
        ("MoltenVK", "https://github.com/KhronosGroup/MoltenVK",
         "Vulkan 到 Metal 的转译层。Apache-2.0。"),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(entries, id: \.0) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.0)
                                .font(.subheadline.weight(.medium))
                            Text(entry.2)
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            if let url = URL(string: entry.1) {
                                Link(entry.1, destination: url)
                                    .font(.caption2)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                } footer: {
                    Text("""
                    本工程以 GPL-3.0 发布，因为它链接了 GPL-3.0 的运行时桥接层。

                    Minecraft 是 Mojang Studios 的商标。本项目与 Mojang、Microsoft \
                    没有隶属关系，也未获得其授权或认可。
                    """)
                }
            }
            .navigationTitle("许可与致谢")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
