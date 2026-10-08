import SwiftUI
import AuthenticationServices
import SafariServices
import UIKit

/// Account management, plus the Microsoft sign-in flow.
struct AccountsView: View {
    @EnvironmentObject private var accounts: AccountManager
    @Environment(\.dismiss) private var dismiss

    @State private var showOfflineCreator = false
    @State private var showMicrosoftLogin = false
    @State private var offlineName = ""
    @State private var offlineError: String?

    var body: some View {
        NavigationStack {
            List {
                if accounts.accounts.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.badge.questionmark")
                                .font(.largeTitle)
                                .foregroundStyle(Theme.Palette.textTertiary)
                            Text("还没有账号")
                                .font(.headline)
                            Text("登录微软账号可以进入正版服务器；离线账号只能玩单人游戏和离线模式服务器。")
                                .font(.caption)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .listRowBackground(Color.clear)
                    }
                } else {
                    Section("账号") {
                        ForEach(accounts.accounts) { account in
                            AccountRow(
                                account: account,
                                isSelected: accounts.selected?.id == account.id,
                                onSelect: { accounts.select(account) },
                                onDelete: { accounts.remove(account) }
                            )
                        }
                    }
                }

                Section {
                    Button {
                        showMicrosoftLogin = true
                    } label: {
                        Label("登录微软账号", systemImage: "person.badge.key.fill")
                    }
                    Button {
                        offlineName = ""
                        offlineError = nil
                        showOfflineCreator = true
                    } label: {
                        Label("创建离线账号", systemImage: "person.fill.questionmark")
                    }
                } header: {
                    Text("添加账号")
                } footer: {
                    Text("密码不会经过启动器。微软登录会跳转到官方页面，启动器只保存返回的访问令牌，并加密存放在系统钥匙串里。")
                }
            }
            .navigationTitle("账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showMicrosoftLogin) {
                MicrosoftLoginView()
            }
            .sheet(isPresented: $showOfflineCreator) {
                offlineCreatorSheet
            }
        }
    }

    private var offlineCreatorSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("玩家名", text: $offlineName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("离线账号")
                } footer: {
                    if let offlineError {
                        Text(offlineError).foregroundStyle(Theme.Palette.danger)
                    } else {
                        Text("3–16 个字符，只能使用字母、数字和下划线。UUID 会按离线模式的规则从名字推导出来，所以同一个名字在任何设备上都是同一个身份。")
                    }
                }
            }
            .navigationTitle("创建离线账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showOfflineCreator = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        do {
                            try accounts.addOffline(name: offlineName)
                            showOfflineCreator = false
                        } catch {
                            offlineError = (error as? LocalizedError)?.errorDescription
                                ?? error.localizedDescription
                        }
                    }
                    .disabled(offlineName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

/// One account row with a selection indicator and a delete action.
private struct AccountRow: View {
    let account: MinecraftAccount
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                AccountAvatar(account: account, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.username)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.Palette.textPrimary)
                        if account.isDemo {
                            Tag(text: "Demo", tint: Theme.Palette.warning)
                        }
                    }
                    HStack(spacing: 6) {
                        Tag(
                            text: account.kind == .microsoft ? "微软" : "离线",
                            tint: account.kind == .microsoft ? Theme.Palette.accent : Theme.Palette.textTertiary
                        )
                        Text(account.uuid)
                            .font(.system(size: 9).monospaced())
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.Palette.accent)
                }
            }
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            Button("删除", role: .destructive, action: onDelete)
        }
    }
}

// MARK: - Microsoft sign-in

/// Drives the browser-based Microsoft sign-in.
///
/// Microsoft's consumer identity platform requires an interactive browser session,
/// and their OAuth app for Minecraft redirects to `login.live.com`, which cannot be
/// completed inside an ephemeral `ASWebAuthenticationSession` (it needs the user's
/// existing Live session cookies). So the flow uses a real in-app browser and the
/// user copies the resulting code back — the same approach every non-store iOS Java
/// launcher uses.
@MainActor
private final class MicrosoftLoginModel: ObservableObject {
    enum Phase: Equatable {
        case ready
        case waitingForCode
        case working(String)
        case failed(String)
    }

    @Published var phase: Phase = .ready
    @Published var code = ""

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    func signIn(completion: @escaping (MinecraftAccount) -> Void) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            phase = .failed("请先粘贴授权码。")
            return
        }

        phase = .working("正在登录…")

        Task {
            do {
                let account = try await MicrosoftAuth.signIn(authorizationCode: trimmed) { stage in
                    Task { @MainActor in
                        self.phase = .working(stage.rawValue)
                    }
                }
                completion(account)
            } catch {
                self.phase = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }
}

struct MicrosoftLoginView: View {
    @EnvironmentObject private var accounts: AccountManager
    @Environment(\.dismiss) private var dismiss

    @StateObject private var model = MicrosoftLoginModel()
    @State private var showBrowser = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Metric.spacing) {
                    stepsCard
                    codeCard
                    if case let .failed(message) = model.phase {
                        errorCard(message)
                    }
                }
                .padding(Theme.Metric.spacing)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.Palette.background)
            .navigationTitle("登录微软账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .sheet(isPresented: $showBrowser) {
                SafariView(url: MicrosoftAuth.authorizationURL)
                    .ignoresSafeArea()
            }
        }
    }

    private var stepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: "三步完成登录",
                subtitle: "登录在微软官方页面进行，启动器看不到你的密码。",
                systemImage: "lock.shield.fill"
            )

            stepRow(number: 1, text: "点下面的按钮，在打开的页面里登录微软账号。")
            stepRow(number: 2, text: "登录成功后页面会变成一片空白，地址栏以 login.live.com/oauth20_desktop.srf?code= 开头。")
            stepRow(number: 3, text: "复制整条地址（或只复制 code= 后面那串），回到这里粘贴，然后点「登录」。")

            Button {
                showBrowser = true
                model.phase = .waitingForCode
            } label: {
                Label("打开微软登录页面", systemImage: "safari.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProminentButtonStyle())
        }
        .cardStyle()
    }

    private func stepRow(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption2.weight(.bold))
                .frame(width: 18, height: 18)
                .background(Theme.Palette.accent.opacity(0.2))
                .foregroundStyle(Theme.Palette.accent)
                .clipShape(Circle())
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "粘贴授权码", systemImage: "doc.on.clipboard.fill")

            TextField("整条地址或 code= 后面的内容", text: $model.code, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.caption.monospaced())
                .lineLimit(2...4)
                .padding(10)
                .background(Theme.Palette.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Metric.cornerSmall, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if model.isWorking {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if case let .working(stage) = model.phase {
                        Text(stage)
                            .font(.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
            }

            Button {
                model.signIn { account in
                    accounts.addMicrosoft(account)
                    dismiss()
                }
            } label: {
                Text("登录")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(ProminentButtonStyle())
            .disabled(model.isWorking || model.code.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .cardStyle()
    }

    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Palette.danger)
                Text("登录失败")
                    .font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }
}

/// Thin `SFSafariViewController` wrapper.
///
/// Used instead of `ASWebAuthenticationSession` because the Microsoft redirect
/// target is not a custom scheme the session can intercept, and the user needs to
/// be able to read the URL bar to copy the code out.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = false

        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.preferredControlTintColor = UIColor(Theme.Palette.accent)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
