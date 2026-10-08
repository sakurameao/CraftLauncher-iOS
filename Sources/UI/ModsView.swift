import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Mod management for the active instance: enable/disable, delete, and import
/// both individual mods and whole modpacks.
struct ModsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = ModManager.shared

    @State private var showImporter = false
    @State private var showPackImporter = false
    @State private var searchText = ""
    @State private var pendingDeletion: ModEntry?

    private var instance: String { appState.activeInstance.name }

    private var mods: [ModEntry] {
        let all = manager.mods(in: instance)
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return all }
        return all.filter {
            $0.displayName.lowercased().contains(query)
                || $0.fileName.lowercased().contains(query)
                || ($0.metadata.modId ?? "").lowercased().contains(query)
        }
    }

    private var enabledCount: Int { mods.filter(\.enabled).count }

    var body: some View {
        NavigationStack {
            Group {
                if mods.isEmpty && searchText.isEmpty {
                    emptyState
                } else {
                    modList
                }
            }
            .background(Theme.Palette.background)
            .navigationTitle("Mod")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索 Mod")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("导入 Mod (.jar)", systemImage: "doc.badge.plus")
                        }
                        Button {
                            showPackImporter = true
                        } label: {
                            Label("导入整合包 (.mrpack / .zip)", systemImage: "shippingbox.fill")
                        }
                        Divider()
                        Button {
                            manager.objectWillChange.send()
                        } label: {
                            Label("重新扫描", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "jar") ?? .data],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    manager.importMods(from: urls, into: instance)
                case let .failure(error):
                    LogConsole.shared.error("选择文件失败：\(error.localizedDescription)")
                }
            }
            .fileImporter(
                isPresented: $showPackImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "mrpack") ?? .archive,
                    .archive,
                    .zip,
                ],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    manager.importModpack(from: url, into: instance)
                case let .failure(error):
                    LogConsole.shared.error("选择整合包失败：\(error.localizedDescription)")
                }
            }
            .confirmationDialog(
                "删除 \(pendingDeletion?.fileName ?? "")？",
                isPresented: Binding(
                    get: { pendingDeletion != nil },
                    set: { if !$0 { pendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("删除", role: .destructive) {
                    if let mod = pendingDeletion { manager.delete(mod) }
                    pendingDeletion = nil
                }
                Button("取消", role: .cancel) { pendingDeletion = nil }
            } message: {
                Text("文件会从实例目录中移除，无法撤销。")
            }
            .safeAreaInset(edge: .bottom) {
                if manager.isImporting {
                    importBanner
                }
            }
        }
    }

    // MARK: - List

    private var modList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Metric.spacingTight) {
                summaryRow

                ForEach(mods) { mod in
                    ModRow(
                        mod: mod,
                        onToggle: {
                            manager.toggle(mod, in: instance)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        },
                        onDelete: { pendingDeletion = mod }
                    )
                }
            }
            .padding(Theme.Metric.spacing)
        }
    }

    private var summaryRow: some View {
        HStack {
            Text("实例「\(instance)」")
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
            Spacer()
            Text("已启用 \(enabledCount) / 共 \(mods.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .padding(.bottom, 2)
    }

    private var emptyState: some View {
        EmptyStateView(
            systemImage: "puzzlepiece.extension",
            title: "还没有 Mod",
            message: """
            点右上角的加号导入 .jar 文件，或者直接导入一个整合包。\
            也可以从「文件」App 里长按 jar 文件，选择「用 CraftLauncher 打开」。
            """,
            actionTitle: "导入 Mod",
            action: { showImporter = true }
        )
    }

    private var importBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(manager.importLabel ?? "正在导入")
                    .font(.caption)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Spacer()
                Text("\(Int((manager.importProgress ?? 0) * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
            ProgressLine(value: manager.importProgress)
        }
        .padding(Theme.Metric.spacing)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.border)
                .frame(height: 1)
        }
    }
}

/// One mod row: name, metadata, enable toggle and delete.
private struct ModRow: View {
    let mod: ModEntry
    let onToggle: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: mod.enabled ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(mod.enabled ? Theme.Palette.accent : Theme.Palette.textTertiary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(mod.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(mod.enabled ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                        .lineLimit(1)
                    if let version = mod.metadata.version, !version.isEmpty {
                        Tag(text: version, tint: Theme.Palette.textTertiary)
                    }
                }

                HStack(spacing: 6) {
                    if let loader = mod.metadata.loader, loader != .vanilla {
                        Tag(text: loader.rawValue, tint: Theme.Palette.info)
                    }
                    if let author = mod.metadata.authorLabel {
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                    }
                    Text(mod.sizeLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                if let description = mod.metadata.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(mod.fileName)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)
        }
        .listRowStyle()
        .contextMenu {
            Button(mod.enabled ? "禁用" : "启用", action: onToggle)
            Button("删除", role: .destructive, action: onDelete)
        }
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}
