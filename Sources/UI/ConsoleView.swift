import SwiftUI
import UIKit

/// Live console output from the JVM plus the launcher's own diagnostics.
struct ConsoleView: View {
    @ObservedObject private var console = LogConsole.shared

    @State private var minimumLevel: LogConsole.Level = .info
    @State private var searchText = ""
    @State private var showShareSheet = false

    private var filtered: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return console.entries.filter { entry in
            guard entry.level >= minimumLevel else { return false }
            guard !query.isEmpty else { return true }
            return entry.text.lowercased().contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                levelBar
                Divider().overlay(Theme.Palette.border)
                logBody
            }
            .background(Theme.Palette.background)
            .navigationTitle("控制台")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "在日志中搜索")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        console.autoScroll.toggle()
                    } label: {
                        Image(systemName: console.autoScroll
                            ? "arrow.down.to.line.circle.fill"
                            : "arrow.down.to.line.circle")
                    }
                    .accessibilityLabel(console.autoScroll ? "停止自动滚动" : "恢复自动滚动")

                    Menu {
                        Button {
                            showShareSheet = true
                        } label: {
                            Label("导出日志", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            UIPasteboard.general.string = console.transcript()
                        } label: {
                            Label("复制全部", systemImage: "doc.on.doc")
                        }
                        Divider()
                        Button(role: .destructive) {
                            console.reset()
                        } label: {
                            Label("清空", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showShareSheet) {
                ShareSheet(items: [console.transcript()])
            }
        }
    }

    // MARK: - Filter bar

    private var levelBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(levels, id: \.self) { level in
                    Button {
                        minimumLevel = level
                    } label: {
                        HStack(spacing: 4) {
                            Text(level.glyph)
                                .font(.caption2.monospaced())
                            Text(levelLabel(level))
                                .font(.caption.weight(.medium))
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(
                            minimumLevel == level
                                ? color(for: level).opacity(0.22)
                                : Theme.Palette.surfaceRaised
                        )
                        .foregroundStyle(
                            minimumLevel == level
                                ? color(for: level)
                                : Theme.Palette.textSecondary
                        )
                        .clipShape(Capsule())
                        .overlay(
                            Capsule().strokeBorder(
                                minimumLevel == level
                                    ? color(for: level).opacity(0.5)
                                    : Theme.Palette.border,
                                lineWidth: 1
                            )
                        )
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

                Text("\(filtered.count) 行")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Metric.spacing)
            .padding(.vertical, 9)
        }
    }

    private var levels: [LogConsole.Level] {
        [.info, .game, .warning, .error]
    }

    private func levelLabel(_ level: LogConsole.Level) -> String {
        switch level {
        case .trace, .debug: return "全部"
        case .info: return "信息"
        case .game: return "游戏"
        case .warning: return "警告"
        case .error: return "错误"
        }
    }

    private func color(for level: LogConsole.Level) -> Color {
        switch level {
        case .trace, .debug: return Theme.Palette.textSecondary
        case .info: return Theme.Palette.info
        case .game: return Theme.Palette.textPrimary
        case .warning: return Theme.Palette.warning
        case .error: return Theme.Palette.danger
        }
    }

    // MARK: - Body

    @ViewBuilder
    private var logBody: some View {
        if filtered.isEmpty {
            EmptyStateView(
                systemImage: "terminal",
                title: console.entries.isEmpty ? "还没有日志" : "没有匹配的行",
                message: console.entries.isEmpty
                    ? "启动游戏后，Java 虚拟机和 Minecraft 的完整输出会实时显示在这里。"
                    : "试试降低筛选级别或换个关键词。"
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { entry in
                            LogRow(entry: entry, tint: color(for: entry.level))
                                .id(entry.id)
                        }
                        // Anchor for auto-scroll.
                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: filtered.count) { _ in
                    guard console.autoScroll else { return }
                    withAnimation(.linear(duration: 0.15)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}

/// A single log line, rendered as timestamped monospaced text.
private struct LogRow: View {
    let entry: LogEntry
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(entry.level.glyph)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(tint)
                .frame(width: 8, alignment: .center)
            Text(entry.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// `UIActivityViewController` wrapper for exporting the log.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
