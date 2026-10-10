import Foundation
import Combine
import UIKit

/// Orchestrates a complete launch, from "user pressed the button" to "the game
/// process exited".
///
/// Deliberately a `@MainActor` state machine: every stage transition is a UI
/// update. The genuinely blocking work — HTTP, zip extraction, and the JVM call
/// itself — is awaited across actor boundaries rather than performed here, so the
/// interface stays responsive while a 40 MB client jar downloads.
@MainActor
final class LaunchPipeline: ObservableObject {
    static let shared = LaunchPipeline()

    @Published private(set) var stage: LaunchStage = .idle
    @Published private(set) var progress: Double = 0
    @Published private(set) var currentItem: String = ""
    @Published var lastError: String?
    @Published private(set) var isRunning = false

    private var launchTask: Task<Void, Never>?

    private init() {}

    var canLaunch: Bool { !isRunning && !stage.isBusy }

    // MARK: - Entry point

    /// Runs a full launch. Returns immediately; progress is published.
    func launch(instance: GameInstance, account: MinecraftAccount) {
        guard canLaunch else {
            LogConsole.shared.warning("已有一次启动正在进行，已忽略重复请求。")
            return
        }

        lastError = nil
        isRunning = true
        LogConsole.shared.reset()

        launchTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.run(instance: instance, account: account)
            } catch is CancellationError {
                self.stage = .idle
            } catch {
                let message = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
                self.lastError = message
                self.stage = .idle
                LogConsole.shared.error(message)
            }
            self.isRunning = false
            self.progress = 0
            self.currentItem = ""
        }
    }

    func cancel() {
        launchTask?.cancel()
        launchTask = nil
        RuntimeLauncher.stopLogCapture()
        stage = .idle
        isRunning = false
    }

    // MARK: - The sequence

    private func run(instance: GameInstance, account: MinecraftAccount) async throws {
        // ── 1. Can this process run a JVM at all? ───────────────────────────────
        setStage(.checkingRuntime)
        let jit = RuntimeLauncher.jitStatus
        switch jit {
        case .enabled:
            LogConsole.shared.info("JIT 已启用，可以启动 Java 虚拟机。")
        case .unknown:
            LogConsole.shared.warning(jit.message)
        case .disabled:
            // Not fatal: the entitlement can be granted between this check and the
            // actual launch by an on-demand debugger attach. Warn loudly and try.
            LogConsole.shared.warning(jit.message)
        }

        let missing = RuntimeLauncher.missingDependencies()
        if !missing.isEmpty {
            throw LauncherError.runtimeCorrupt(
                tag: "Frameworks",
                detail: "缺少 \(missing.count) 个库文件（\(missing.map { ($0 as NSString).lastPathComponent }.joined(separator: "、"))）"
            )
        }

        // ── 2. Credentials ──────────────────────────────────────────────────────
        let authenticated = try await AccountManager.shared.credentials(for: account)
        guard let accessToken = accessToken(for: authenticated) else {
            throw LauncherError.notAuthenticated
        }

        // ── 3. Version metadata ────────────────────────────────────────────────
        setStage(.readingVersion)
        LogConsole.shared.info("正在读取版本 \(instance.versionId) 的信息…")
        let version = try await VersionService.shared.resolvedVersion(versionId: instance.versionId)
        LogConsole.shared.info(
            "版本 \(version.id)：主类 \(version.mainClass)，需要 Java \(version.requiredJavaMajor)"
        )

        // ── 4. Runtime selection ───────────────────────────────────────────────
        //
        // A missing runtime here is frequently *not* a broken installation: the
        // bundled runtimes are Java 8 and Java 17, and Minecraft 1.20.5 and newer
        // declare Java 21. No iOS Java 21 build is publicly obtainable, so this is a
        // hard ceiling on the supported game versions, and the message has to say so
        // rather than imply the user can go install something.
        let preferred = UserDefaults.standard.object(forKey: PrefKey.javaPreferredVersion) as? Int
        guard let runtime = JavaRuntimeManager.shared.runtime(
            requiredMajor: version.requiredJavaMajor,
            preferredMajor: instance.javaMajorOverride ?? preferred,
            overrideTag: UserDefaults.standard.string(forKey: PrefKey.javaSelectedRuntime)
        ) else {
            let available = JavaRuntimeManager.shared.runtimes
                .map { "Java \($0.majorVersion)" }
                .joined(separator: "、")
            throw LauncherError.runtimeMissing(
                tag: RuntimeTag.minimumTag(forMajor: version.requiredJavaMajor) ?? "无",
                requiredMajor: version.requiredJavaMajor,
                availableVersions: available
            )
        }
        guard runtime.isUsable else {
            throw LauncherError.runtimeCorrupt(
                tag: runtime.tag,
                detail: runtime.unusableReason ?? "运行时文件不完整"
            )
        }
        LogConsole.shared.info(
            "使用运行时：\(runtime.displayName)（\(runtime.home.lastPathComponent)）"
        )

        // ── 5. Assets ──────────────────────────────────────────────────────────
        setStage(.readingVersion)
        let assetIndex = try await VersionService.shared.assetIndex(for: version)
        LogConsole.shared.info("资源索引 \(version.assetIndexId)：\(assetIndex.objects.count) 个文件")

        // ── 6. Downloads ───────────────────────────────────────────────────────
        let verifyAssets = UserDefaults.standard.object(forKey: PrefKey.generalCheckAssets) as? Bool ?? true
        let plan = ResourceDownloader.shared.plan(
            version: version,
            assetIndex: assetIndex,
            instanceName: instance.name,
            environment: .current,
            verifyAssets: verifyAssets
        )

        if plan.totalFiles == 0 {
            LogConsole.shared.info("所有文件都已就绪，跳过下载。")
        } else {
            LogConsole.shared.info(
                "需要下载 \(plan.totalFiles) 个文件，共 \(FileUtil.humanSize(plan.totalBytes))。"
            )
            try FileUtil.requireFreeSpace(plan.totalBytes)

            // One pass over the whole plan rather than per-category batches. The
            // earlier split into libraries / client / assets had to be kept in sync
            // by hand, and adding the Log4j config to the plan silently skipped it —
            // a whole category would be missed by exactly that kind of mistake.
            setStage(.downloading(done: 0, total: plan.totalFiles))

            let maxConcurrent = UserDefaults.standard.object(
                forKey: PrefKey.generalMaxConcurrentDownloads
            ) as? Int ?? 6

            try await ResourceDownloader.shared.execute(
                plan: plan,
                maxConcurrent: maxConcurrent
            ) { update in
                // Called from a download task; hop back to the main actor to publish.
                Task { @MainActor in
                    self.stage = .downloading(done: update.completed, total: update.total)
                    self.progress = update.fraction
                    self.currentItem = update.currentLabel
                }
            }

            if !plan.legacyAssetMapping.isEmpty {
                LogConsole.shared.info("旧版资源目录已展开。")
            }
        }

        // ── 7. Natives ─────────────────────────────────────────────────────────
        setStage(.preparingNatives)
        let nativesDir = LauncherPath.nativesDir(instance: instance.name)
        // Wiped every launch: stale extracted libraries are a classic source of
        // "worked yesterday, crashes today" reports.
        try? FileManager.default.removeItem(at: nativesDir)
        LauncherPath.ensureDirectory(nativesDir)
        for sub in ["jna", "lwjgl", "netty"] {
            LauncherPath.ensureDirectory(nativesDir.appendingPathComponent(sub, isDirectory: true))
        }

        // ── 8. Verify the AWT shim ─────────────────────────────────────────────
        //
        // `libawt_xawt.dylib` must sit next to the other JDK libraries or AWT
        // refuses to initialise. Both bundled runtimes already ship it, so this is
        // a check rather than the symlink-creation dance the original design did —
        // `lib/` inside the app bundle is read-only, and the JDK builds only ever
        // lacked this file in configurations we do not use.
        let awtShim = runtime.libawtXawt
        if FileManager.default.fileExists(atPath: awtShim.path) {
            LogConsole.shared.append(.debug, "AWT 支持库已就位：lib/awt_xawt.dylib")
        } else {
            // Not fatal: only the Swing-based parts of the game (the Realms browser,
            // the crash dialog) need it.
            LogConsole.shared.warning(
                "运行时 \(runtime.tag) 缺少 lib/awt_xawt.dylib，游戏内的 Swing 界面可能不可用。"
            )
        }

        // ── 9. Assemble and go ─────────────────────────────────────────────────
        let width = Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        let height = Int(UIScreen.main.bounds.height * UIScreen.main.scale)

        let libraries = ResourceDownloader.shared.applicableLibraries(from: version)
        let config = LaunchConfiguration(
            instanceName: instance.name,
            versionId: version.id,
            username: authenticated.username,
            uuid: authenticated.uuid,
            accessToken: accessToken,
            userType: authenticated.userType,
            xuid: authenticated.id,
            clientId: MicrosoftAuth.clientId,
            isDemo: authenticated.isDemo,
            javaHome: runtime.home,
            javaMajorVersion: runtime.majorVersion,
            allocatedMemoryMB: resolveMemoryMB(instance: instance),
            customJVMArgs: JVMArguments.splitArguments(
                UserDefaults.standard.string(forKey: PrefKey.javaCustomArgs) ?? ""
            ),
            customEnvVars: JVMArguments.parseEnvironmentVariables(
                UserDefaults.standard.string(forKey: PrefKey.javaEnvVars) ?? ""
            ),
            renderer: selectedRenderer(for: version),
            width: width,
            height: height,
            resolutionScale: UserDefaults.standard.object(
                forKey: PrefKey.rendererResolutionScale
            ) as? Double ?? 1.0
        )

        let invocation = JVMArguments.build(
            config: config,
            version: version,
            libraries: libraries,
            nativesDirectory: nativesDir
        )

        setStage(.startingJVM)
        LogConsole.shared.info("启动命令：\(invocation.commandLine)")

        // The renderer string the bridge exports is the same one the JVM flags use,
        // because both the patched LWJGL and the GL translation layer read it.
        let rendererForEnv: RendererBackend = config.renderer == RendererBackend.auto
            ? RendererBackend.angleMetal
            : config.renderer

        let result = await RuntimeLauncher.launch(
            invocation: invocation,
            javaHome: runtime.home,
            renderer: rendererForEnv,
            width: width,
            height: height,
            environment: config.customEnvVars
        ) { line in
            // The bridge calls this from its log reader thread.
            LogConsole.shared.append(.game, line)
        }

        switch result {
        case let .exited(code):
            stage = .exited(code: code)
            if code == 0 {
                LogConsole.shared.info("游戏已正常退出。")
            } else {
                LogConsole.shared.error("游戏异常退出，返回码 \(code)。")
                await captureCrashReport(instance: instance)
            }

        case let .bridgeFailure(error):
            throw error
        }
    }

    // MARK: - Steps

    private func setStage(_ newStage: LaunchStage) {
        stage = newStage
        progress = 0
        currentItem = ""
    }

    /// Reads the token for an account, rejecting an expired live account.
    private func accessToken(for account: MinecraftAccount) -> String? {
        switch account.kind {
        case .offline:
            // Offline launches still need a non-empty token on the command line;
            // the Java side treats any value as "skip session validation".
            return "0"
        case .microsoft:
            return KeychainStore.accessToken(accountId: account.id)
        }
    }

    /// Memory to hand the JVM.
    ///
    /// Two entitlements change the answer, and both are frequently absent — a
    /// certificate-based signing tool will strip Apple-reserved keys, and a stock
    /// device never had them:
    ///
    /// * `com.apple.private.memorystatus` raises the jetsam ceiling, so a larger
    ///   heap is survivable.
    /// * `com.apple.developer.kernel.extended-virtual-addressing` provides the large
    ///   virtual address space Java 17+ wants for compressed class pointers; without
    ///   it `JVMArguments` adds `-XX:-UseCompressedClassPointers`.
    ///
    /// Both are probed rather than assumed, so the same build behaves correctly
    /// whether it was signed by Xcode, SideStore, or a certificate tool.
    private func resolveMemoryMB(instance: GameInstance) -> Int {
        if let override = instance.memoryMBOverride { return override }

        let auto = UserDefaults.standard.object(forKey: PrefKey.javaAutoMemory) as? Bool ?? true
        if !auto {
            let stored = UserDefaults.standard.integer(forKey: PrefKey.javaAllocatedMemory)
            if stored > 0 { return stored }
        }

        let physicalMB = Double(ProcessInfo.processInfo.physicalMemory) / 1_048_576

        // The entitlement is probed rather than assumed, so the same build behaves
        // correctly whether it was signed by Xcode, SideStore, or a certificate tool
        // that strips keys it cannot issue. `RuntimeLauncher.entitlements` reads the
        // *effective* entitlements via SecTask, in the same place the JIT probe lives.
        //
        // `com.apple.private.memorystatus` raises the jetsam ceiling, which is what
        // makes a large heap survivable rather than an instant kill.
        let hasExtendedMemory = RuntimeLauncher.entitlements.extendedMemory
        let ratio = hasExtendedMemory ? 0.4 : 0.25
        let calculated = Int((physicalMB * ratio).rounded())

        // Clamp: below 512 MB the game cannot generate terrain; above 4096 MB on a
        // phone it will be jetsam-killed before it finishes loading.
        return min(max(calculated, 512), 4096)
    }

    private func selectedRenderer(for version: MinecraftVersion) -> RendererBackend {
        if let raw = UserDefaults.standard.string(forKey: PrefKey.rendererBackend),
           let backend = RendererBackend(rawValue: raw),
           backend != .auto {
            return backend
        }
        // ANGLE is the only backend that works for 1.20.2+, which switched to
        // demanding a core profile the GL4ES path cannot provide.
        return version.requiredJavaMajor >= 17 ? .angleMetal : .gl4es
    }

    /// On a non-zero exit, copy the newest crash report somewhere the user can
    /// reach it from Files.app, and say so in the log.
    private func captureCrashReport(instance: GameInstance) async {
        let fm = FileManager.default
        let gameDir = LauncherPath.instance(instance.name)
        let reports = gameDir.appendingPathComponent("crash-reports", isDirectory: true)

        guard let files = try? fm.contentsOfDirectory(
            at: reports,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), let newest = files
            .filter({ $0.pathExtension == "txt" })
            .max(by: { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                return da < db
            })
        else {
            LogConsole.shared.warning("游戏异常退出。控制台日志已保存在 logs/console.log。")
            return
        }

        LauncherPath.ensureDirectory(LauncherPath.crashReports)
        let destination = LauncherPath.crashReports
            .appendingPathComponent("\(instance.name)-\(newest.lastPathComponent)")
        try? fm.removeItem(at: destination)
        try? fm.copyItem(at: newest, to: destination)

        LogConsole.shared.error("已保存崩溃报告：crash-reports/\(destination.lastPathComponent)")
    }
}
