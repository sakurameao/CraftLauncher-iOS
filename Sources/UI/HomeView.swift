import SwiftUI

/// The launch screen: pick what to play, then play it.
struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var accounts: AccountManager
    @EnvironmentObject private var pipeline: LaunchPipeline

    @ObservedObject private var runtimes = JavaRuntimeManager.shared
    @ObservedObject private var versions = VersionManager.shared
    @ObservedObject private var mods = ModManager.shared

    @State private var showAccountSheet = false
    @State private var showVersionSheet = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: Theme.Metric.spacing) {
                    header
                    statusCard
                    launchButton
                    secondaryActions
                    storageCard
                    if let error = pipeline.lastError {
                        errorCard(error)
                    }
                }
                .padding(Theme.Metric.spacing)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.background)
            .navigationTitle("CraftLauncher")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAccountSheet = true
                    } label: {
                        accountChip
                    }
                }
            }
            .sheet(isPresented: $showAccountSheet) {
                AccountsView()
            }
            .sheet(isPresented: $showVersionSheet) {
                VersionPickerSheet(instance: appState.activeInstance)
            }
            .onAppear {
                runtimes.refresh()
                versions.refreshInstalled()
            }
        }
    }

    // MARK: - Header

    /// Brand mark plus the active instance name.
    ///
    /// This property was referenced by `body` but never defined — a casualty of an
    /// earlier rewrite — which surfaced as `cannot find 'header' in scope`. The
    /// `// MARK: - Header` above `accountChip` is what remained of it.
    private var header: some View {
        HStack(spacing: 12) {
            LauncherMark(size: 40)

            VStack(alignment: .leading, spacing: 2) {
                Text("CraftLauncher")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Text(appState.activeInstance.name)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accountChip: some View {
        HStack(spacing: 6) {
            if let account = accounts.selected {
                AccountAvatar(account: account, size: 22)
                Text(account.username)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            } else {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.caption)
                Text("登录")
                    .font(.caption.weight(.medium))
            }
        }
        .foregroundStyle(Theme.Palette.textPrimary)
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                LauncherMark(size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(appState.activeInstance.name)
                        .font(.headline)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(pipeline.stage.label)
                        .font(.caption)
                        .foregroundStyle(
                            pipeline.stage.isBusy
                                ? Theme.Palette.accent
                                : Theme.Palette.textSecondary
                        )
                }
                Spacer()
            }

            if pipeline.stage.isBusy || pipeline.isRunning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressLine(
                        value: pipeline.stage.isBusy ? pipeline.progress : nil,
                        tint: Theme.Palette.accent
                    )
                    if !pipeline.currentItem.isEmpty {
                        Text(pipeline.currentItem)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Divider().overlay(Theme.Palette.border)

            Button {
                showVersionSheet = true
            } label: {
                HStack {
                    Image(systemName: "cube.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.Palette.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏版本")
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Text(selectedVersionLabel)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                    }
                    Spacer()
                    if versions.isInstalled(appState.activeInstance.versionId) {
                        Tag(text: "已安装", tint: Theme.Palette.accent)
                    } else {
                        Tag(text: "需要下载", tint: Theme.Palette.warning)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .buttonStyle(.plain)

            runtimeRow
        }
        .cardStyle()
    }

    private var selectedVersionLabel: String {
        let id = appState.activeInstance.versionId
        return id.isEmpty ? "尚未选择" : id
    }

    private var runtimeRow: some View {
        HStack {
            Image(systemName: "cup.and.saucer.fill")
                .font(.caption)
                .foregroundStyle(Theme.Palette.info)
            VStack(alignment: .leading, spacing: 2) {
                Text("Java 运行时")
                    .font(.caption2)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(runtimeSummary)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        runtimes.runtimes.isEmpty ? Theme.Palette.warning : Theme.Palette.textPrimary
                    )
            }
            Spacer()
            if runtimes.runtimes.isEmpty {
                Tag(text: "缺失", tint: Theme.Palette.danger)
            } else {
                Text("\(runtimes.runtimes.count) 个")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private var runtimeSummary: String {
        guard !runtimes.runtimes.isEmpty else { return "App 包内没有运行时" }
        return runtimes.runtimes.map { "Java \($0.majorVersion)" }.joined(separator: " · ")
    }

    // MARK: - Launch

    private var launchButton: some View {
        VStack(spacing: 10) {
            Button {
                startLaunch()
            } label: {
                HStack(spacing: 10) {
                    if pipeline.isRunning {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.black)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.headline)
                    }
                    Text(pipeline.isRunning ? "运行中…" : "启动游戏")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    pipeline.canLaunch
                        ? Theme.Palette.accent
                        : Theme.Palette.surfaceHighlight
                )
                .foregroundStyle(pipeline.canLaunch ? Color.black.opacity(0.88) : Theme.Palette.textTertiary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous))
            }
            .disabled(!pipeline.canLaunch)

            if !canLaunchReason.isEmpty {
                Text(canLaunchReason)
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.warning)
                    .multilineTextAlignment(.center)
            }
        }
    }

    /// Explains, up front, why the launch button is disabled. Better than letting
    /// the user press it and get an error.
    private var canLaunchReason: String {
        if pipeline.isRunning || pipeline.stage.isBusy { return "" }
        if !accounts.hasAccounts { return "请先在右上角登录账号或创建一个离线账号。" }
        if appState.activeInstance.versionId.isEmpty { return "请先选择要启动的游戏版本。" }
        if runtimes.runtimes.isEmpty {
            return "App 包内没有 Java 运行时，请运行 Scripts/bootstrap-runtime.sh 后重新构建。"
        }
        return ""
    }

    private func startLaunch() {
        guard let account = accounts.selected else {
            appState.alert = .init(
                title: "还没有账号",
                message: "请先登录微软账号，或创建一个离线账号。",
                isDestructive: false
            )
            return
        }
        guard !appState.activeInstance.versionId.isEmpty else { return }

        pipeline.launch(instance: appState.activeInstance, account: account)
    }

    // MARK: - Secondary actions

    private var secondaryActions: some View {
        HStack(spacing: Theme.Metric.spacingTight) {
            NavigationLink {
                ModsView()
            } label: {
                statTile(
                    icon: "puzzlepiece.extension.fill",
                    tint: Theme.Palette.info,
                    value: "\(mods.modCount(in: appState.activeInstance.name))",
                    label: "已启用 Mod"
                )
            }
            .buttonStyle(.plain)

            NavigationLink {
                ConsoleView()
            } label: {
                statTile(
                    icon: "terminal.fill",
                    tint: Theme.Palette.textSecondary,
                    value: "\(LogConsole.shared.entries.count)",
                    label: "控制台日志"
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func statTile(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(tint)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - Storage

    private var storageCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(
                title: "存储占用",
                subtitle: "一个现代版本连资源约需 1.5 GB",
                systemImage: "internaldrive.fill"
            )
            LabeledValue(
                label: "已用总计",
                value: FileUtil.humanSize(versions.totalStorageBytes()),
                monospaced: true
            )
            // Libraries and assets are shared by every version, which is why
            // deleting a version reclaims far less than its download size.
            LabeledValue(
                label: "依赖库 + 资源（多版本共用）",
                value: FileUtil.humanSize(
                    versions.sharedStorageBytes().libraries + versions.sharedStorageBytes().assets
                ),
                monospaced: true
            )
            if let free = FileUtil.availableBytes() {
                LabeledValue(
                    label: "剩余空间",
                    value: FileUtil.humanSize(free),
                    monospaced: true,
                    tint: free < 2 * 1024 * 1024 * 1024 ? Theme.Palette.warning : Theme.Palette.textPrimary
                )
            }
        }
        .cardStyle()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
                Text("启动失败")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.Palette.textPrimary)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                NavigationLink {
                    ConsoleView()
                } label: {
                    Text("查看日志")
                }
                .buttonStyle(SubtleButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Metric.corner, style: .continuous)
                .strokeBorder(Theme.Palette.danger.opacity(0.4), lineWidth: 1)
        )
    }
}

/// Account avatar with a graceful fallback while (or if) the network image loads.
struct AccountAvatar: View {
    let account: MinecraftAccount
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let url = account.avatarURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image.resizable().interpolation(.none)
                    default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private var placeholder: some View {
        ZStack {
            // Offline accounts get a deterministic colour from their UUID, so the
            // same name always looks the same.
            Theme.Palette.surfaceHighlight
            Text(String(account.username.prefix(1)).uppercased())
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
    }
}
