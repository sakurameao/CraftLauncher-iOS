import SwiftUI
import UIKit

/// The version browser: filter, search, install and remove game versions.
struct VersionsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = VersionManager.shared

    @State private var pendingDeletion: VersionManifest.Entry?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                Divider().overlay(Theme.Palette.border)
                content
            }
            .background(Theme.Palette.background)
            .navigationTitle("版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        manager.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .searchable(
                text: $manager.searchText,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索版本号"
            )
            .onAppear { manager.loadIfNeeded() }
            .confirmationDialog(
                "删除版本 \(pendingDeletion?.id ?? "")？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let entry = pendingDeletion {
                        manager.uninstall(versionId: entry.id)
                        // Point the active instance somewhere valid if it was
                        // pointing at what we just deleted.
                        if appState.activeInstance.versionId == entry.id {
                            appState.updateActiveVersion("")
                        }
                    }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("只会删除这个版本的元数据与客户端。依赖库和资源文件是多个版本共用的，会保留。")
            }
        }
    }

    // MARK: - Filter

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(VersionManager.Filter.allCases) { filter in
                    Button {
                        manager.filter = filter
                    } label: {
                        Text(filter.label)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(
                                manager.filter == filter
                                    ? Theme.Palette.accent
                                    : Theme.Palette.surfaceRaised
                            )
                            .foregroundStyle(
                                manager.filter == filter
                                    ? Color.black.opacity(0.85)
                                    : Theme.Palette.textSecondary
                            )
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Metric.spacing)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if manager.manifest == nil {
            LoadingStateView(message: "正在获取版本列表…")
        } else if manager.visibleVersions.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up.slash",
                title: "没有匹配的版本",
                message: manager.searchText.isEmpty
                    ? "换个筛选条件试试。"
                    : "没有找到包含「\(manager.searchText)」的版本。"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: Theme.Metric.spacingTight) {
                    ForEach(manager.visibleVersions) { entry in
                        VersionRow(
                            entry: entry,
                            isActive: appState.activeInstance.versionId == entry.id,
                            isInstalled: manager.isInstalled(entry.id),
                            operation: manager.operation(for: entry.id),
                            onSelect: {
                                appState.updateActiveVersion(entry.id)
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            },
                            onInstall: { manager.install(versionId: entry.id) },
                            onDelete: { pendingDeletion = entry }
                        )
                    }
                }
                .padding(Theme.Metric.spacing)
            }
        }
    }
}

/// One version row. A single component handles all four states (idle, installing,
/// installed, failed) so the list does not reflow as a download progresses.
struct VersionRow: View {
    let entry: VersionManifest.Entry
    let isActive: Bool
    let isInstalled: Bool
    let operation: VersionManager.Operation
    let onSelect: () -> Void
    let onInstall: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onSelect) {
                    HStack(spacing: 12) {
                        selectionIndicator
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text(entry.id)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                if isActive {
                                    Tag(text: "当前", tint: Theme.Palette.accent)
                                }
                            }
                            HStack(spacing: 6) {
                                Tag(text: typeLabel, tint: typeTint)
                                Text(entry.releaseDateLabel)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                trailingControl
            }
        }
        .listRowStyle(isSelected: isActive)
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(
                    isActive ? Theme.Palette.accent : Theme.Palette.borderStrong,
                    lineWidth: isActive ? 5 : 1.5
                )
                .frame(width: 18, height: 18)
        }
    }

    private var typeLabel: String {
        switch entry.type {
        case "release": return "正式版"
        case "snapshot": return "快照"
        case "old_beta": return "Beta"
        case "old_alpha": return "Alpha"
        default: return entry.type
        }
    }

    private var typeTint: Color {
        switch entry.type {
        case "release": return Theme.Palette.accent
        case "snapshot": return Theme.Palette.warning
        default: return Theme.Palette.textTertiary
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        switch operation {
        case .idle:
            if isInstalled {
                Menu {
                    Button("重新下载", action: onInstall)
                    Button("删除", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            } else {
                Button(action: onInstall) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.Palette.accent)
                }
                .buttonStyle(.plain)
            }

        case let .installing(progress, label):
            VStack(alignment: .trailing, spacing: 3) {
                Text("\(Int(progress * 100))%")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Palette.accent)
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                ProgressLine(value: progress)
                    .frame(width: 64)
            }

        case let .failed(message):
            Button {
                onInstall()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .font(.body)
                        .foregroundStyle(Theme.Palette.danger)
                    Text("重试")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Palette.danger)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("安装失败，点按重试：\(message)")
        }
    }
}

/// A version chosen from Home: only installed versions are offered, with a shortcut
/// to the full browser for anything else.
struct VersionPickerSheet: View {
    let instance: GameInstance

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = VersionManager.shared

    @State private var showAllVersions = false

    var body: some View {
        NavigationStack {
            List {
                if manager.installed.isEmpty {
                    Section {
                        VStack(spacing: 10) {
                            Image(systemName: "arrow.down.circle")
                                .font(.title2)
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Text("还没有安装任何版本")
                                .font(.subheadline)
                                .foregroundStyle(Theme.Palette.textSecondary)
                            Button("去下载一个") {
                                dismiss()
                                showAllVersions = true
                            }
                            .buttonStyle(ProminentButtonStyle())
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                } else {
                    Section("已安装") {
                        ForEach(manager.installed.sorted(by: >), id: \.self) { id in
                            Button {
                                appState.updateActiveVersion(id)
                                dismiss()
                            } label: {
                                HStack {
                                    Text(id)
                                        .foregroundStyle(Theme.Palette.textPrimary)
                                    Spacer()
                                    if instance.versionId == id {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(Theme.Palette.accent)
                                    }
                                }
                            }
                        }
                    }
                }

                Section {
                    Button("浏览全部版本…") {
                        dismiss()
                        showAllVersions = true
                    }
                } footer: {
                    Text("「版本」标签页可以下载任意官方版本，包括快照和远古版。")
                }
            }
            .navigationTitle("选择版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .onAppear { manager.refreshInstalled() }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Shared spinner-with-caption used while a list is loading.
struct LoadingStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.Palette.accent)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
