import SwiftUI

@main
struct CraftLauncherApp: App {
    @StateObject private var appState = AppState.shared
    @StateObject private var accounts = AccountManager.shared
    @StateObject private var pipeline = LaunchPipeline.shared

    /// Placed on the window so the console background is consistent everywhere and
    /// the light/dark flash at launch is avoided.
    private var background: some View {
        Theme.Palette.background.ignoresSafeArea()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .environmentObject(accounts)
                .environmentObject(pipeline)
                .preferredColorScheme(.dark)
                .tint(Theme.Palette.accent)
                .background(background)
                .task { appState.start() }
                .onOpenURL { url in
                    handleIncomingFile(url)
                }
        }
    }

    /// Handles "Open in CraftLauncher" from Files.app and the share sheet.
    ///
    /// Three kinds of payload are accepted: `.jar` mods, modpack archives, and a
    /// stray `.zip` runtime the user wants to import as a JDK.
    private func handleIncomingFile(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        let instance = appState.activeInstance.name

        switch ext {
        case "jar":
            LogConsole.shared.info("收到 Mod 文件：\(url.lastPathComponent)")
            ModManager.shared.importMods(from: [url], into: instance)

        case "mrpack", "zip":
            LogConsole.shared.info("收到整合包：\(url.lastPathComponent)")
            ModManager.shared.importModpack(from: url, into: instance)

        case "disabled":
            LogConsole.shared.warning("忽略已禁用的 Mod：\(url.lastPathComponent)")

        default:
            LogConsole.shared.warning("无法识别的文件类型：\(url.lastPathComponent)")
        }
    }
}

/// Top-level layout: five tabs, each a self-contained screen.
struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var pipeline: LaunchPipeline

    @State private var selection: Tab = .home

    enum Tab: String, CaseIterable, Identifiable {
        case home, versions, mods, console, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: return "主页"
            case .versions: return "版本"
            case .mods: return "Mod"
            case .console: return "控制台"
            case .settings: return "设置"
            }
        }

        var systemImage: String {
            switch self {
            case .home: return "house.fill"
            case .versions: return "square.stack.3d.up.fill"
            case .mods: return "puzzlepiece.extension.fill"
            case .console: return "terminal.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Tab.allCases) { tab in
                screen(for: tab)
                    .tabItem {
                        Label(tab.title, systemImage: tab.systemImage)
                    }
                    .tag(tab)
            }
        }
        // A launch cannot be paused, so the interface must explain why it is busy
        // rather than appearing frozen.
        .overlay(alignment: .top) {
            if pipeline.isRunning {
                RunningBanner()
                    .padding(.horizontal, Theme.Metric.spacing)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: pipeline.isRunning)
        .alert(item: $appState.alert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("好"))
            )
        }
    }

    @ViewBuilder
    private func screen(for tab: Tab) -> some View {
        switch tab {
        case .home: HomeView()
        case .versions: VersionsView()
        case .mods: ModsView()
        case .console: ConsoleView()
        case .settings: SettingsView()
        }
    }
}

/// Slim banner shown while the JVM runs, so the user can always see that a launch
/// is in progress even after navigating away from Home.
private struct RunningBanner: View {
    @EnvironmentObject private var pipeline: LaunchPipeline

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(Theme.Palette.accent)
            Text(pipeline.stage.label)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer()
            if pipeline.stage.isBusy {
                Text("\(Int(pipeline.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.Palette.textSecondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
        .background(Theme.Palette.accent.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Theme.Palette.accent.opacity(0.3), lineWidth: 1))
        .padding(.top, 6)
    }
}
