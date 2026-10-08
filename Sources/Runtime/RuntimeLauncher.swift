import Foundation

/// Swift-facing wrapper over the Objective-C++ JVM bridge.
///
/// `JLI_Launch` blocks its calling thread until the game exits, so the blocking
/// call is wrapped in a continuation that is explicitly run off the main actor.
enum RuntimeLauncher {

    enum JITStatus {
        case enabled, disabled, unknown

        var isBlocking: Bool {
            if case .disabled = self { return true }
            return false
        }

        var message: String {
            switch self {
            case .enabled:
                return "JIT 已启用。"
            case .disabled:
                return """
                当前进程没有 JIT 权限。

                Java 虚拟机会以纯解释模式运行，Minecraft 在这种模式下几乎无法游玩。\
                请用 TrollStore 或越狱设备安装，或用 SideStore / SideJITServer 附加调试器后重试。\
                详见 docs/JIT.md。
                """
            case .unknown:
                return "无法探测 JIT 状态，将直接尝试启动。"
            }
        }
    }

    static var jitStatus: JITStatus {
        switch RuntimeBridge.jitStatus() {
        case .enabled: return .enabled
        case .disabled: return .disabled
        default: return .unknown
        }
    }

    /// Libraries the runtime needs that are missing from the bundle.
    static func missingDependencies() -> [String] {
        RuntimeBridge.validateRuntimeDependencies()
    }

    static var lastLoadError: String? {
        RuntimeBridge.lastDynamicLoadError()
    }

    /// A snapshot of what the *signature* actually granted the process.
    ///
    /// These come from `SecTaskCopyValueForEntitlement`, so they report the
    /// effective entitlements rather than what the source `.entitlements` file
    /// asked for — which is the whole point, because signers silently drop keys
    /// they cannot issue.
    struct EntitlementReport {
        /// SideStore / AltStore / SideJITServer need this to attach a debugger,
        /// and the debugger attach is what grants JIT.
        let getTaskAllow: Bool
        /// Required to `dlopen` the Java runtime's dylibs.
        let libraryValidationDisabled: Bool
        /// Raises the jetsam ceiling, allowing a larger heap.
        let extendedMemory: Bool

        /// The single most useful bit: without this, no tool can hand out JIT on a
        /// non-jailbroken device.
        var canReceiveJITByDebugger: Bool { getTaskAllow }
    }

    static var entitlements: EntitlementReport {
        EntitlementReport(
            getTaskAllow: RuntimeBridge.hasGetTaskAllow(),
            libraryValidationDisabled: RuntimeBridge.hasLibraryValidationDisabled(),
            extendedMemory: RuntimeBridge.hasExtendedMemoryEntitlement()
        )
    }

    /// The outcome of a JVM run. Negative codes never reach the VM; they are raised
    /// by the bridge and translated here into something a user can act on.
    enum LaunchResult {
        case exited(code: Int32)
        case bridgeFailure(LauncherError)

        var exitCode: Int32 {
            if case let .exited(code) = self { return code }
            return -1
        }

        var isSuccess: Bool {
            if case let .exited(code) = self { return code == 0 }
            return false
        }
    }

    /// Starts the JVM and waits for it to exit.
    ///
    /// Must not be called from the main actor: it blocks for the entire game
    /// session. `HACK_IGNORE_START_ON_FIRST_THREAD` is exported by the bridge so the
    /// VM tolerates being started from a background thread, which is required
    /// because UIKit will otherwise be starved of the main run loop.
    static func launch(
        invocation: JVMArguments.Invocation,
        javaHome: URL,
        renderer: RendererBackend,
        width: Int,
        height: Int,
        environment: [String: String],
        onLine: @escaping (String) -> Void
    ) async -> LaunchResult {
        let arguments = [invocation.executable.path] + invocation.arguments
        let userHome = LauncherPath.launcherRoot.path

        return await withCheckedContinuation { (continuation: CheckedContinuation<LaunchResult, Never>) in
            // A dedicated thread so the blocking call cannot occupy a cooperative
            // pool thread that other async work needs.
            let thread = Thread {
                let code = RuntimeBridge.launchJVM(
                    withArguments: arguments,
                    javaHome: javaHome.path,
                    userHome: userHome,
                    renderer: renderer.rawValue,
                    width: Int32(width),
                    height: Int32(height),
                    environment: environment,
                    logBlock: { line in
                        onLine(line)
                    }
                )

                switch code {
                case -1:
                    continuation.resume(returning: .bridgeFailure(
                        .runtimeCorrupt(tag: javaHome.lastPathComponent, detail: "无法加载 libjli.dylib")
                    ))
                case -2:
                    continuation.resume(returning: .bridgeFailure(
                        .runtimeCorrupt(tag: javaHome.lastPathComponent, detail: "缺少 JLI_Launch 符号")
                    ))
                case -3:
                    continuation.resume(returning: .bridgeFailure(
                        .jvmLaunchRefused("JVM 参数为空")
                    ))
                default:
                    continuation.resume(returning: .exited(code: Int32(code)))
                }
            }
            thread.name = "craftlauncher.jvm"
            // Above default so the game is never starved by background downloads.
            thread.qualityOfService = .userInitiated
            thread.stackSize = 8 * 1024 * 1024
            thread.start()
        }
    }

    static func stopLogCapture() {
        RuntimeBridge.stopLogCapture()
    }
}
