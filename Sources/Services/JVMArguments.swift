import Foundation

/// Assembles the full JVM invocation for a launch.
///
/// This is the piece that decides whether Minecraft starts. It is kept free of
/// UIKit and of any native bridge types so it can be exercised by
/// `Scripts/verify.py` and by unit tests on any platform.
///
/// The iOS-specific decisions it makes, and why, are documented inline — they are
/// the accumulated answers to "why does this crash on iOS but work on desktop".
enum JVMArguments {

    /// Result of assembly: `argv[0]` is the `java` executable itself, matching what
    /// `JLI_Launch` expects.
    struct Invocation {
        let executable: URL
        let arguments: [String]
        let workingDirectory: URL

        /// The command line, for the log and for the "copy launch command" action.
        var commandLine: String {
            ([executable.path] + arguments)
                .map { $0.contains(" ") ? "\"\($0)\"" : $0 }
                .joined(separator: " ")
        }
    }

    /// Bundle-relative paths the runtime needs. Resolved once.
    struct RuntimePaths {
        /// `<App.app>/Frameworks` — the patched graphics dylibs.
        let frameworks: URL
        /// `<App.app>/libs` — patched LWJGL, `launcher.jar`, Caciocavallo (both
        /// Java 8 and Java 17 builds, merged into one directory).
        let libs: URL
        let appBundle: URL

        /// Log4Shell patch configs, which live at the bundle root.
        var log4jPatch17: URL { appBundle.appendingPathComponent("log4j-rce-patch-1.7.xml") }
        var log4jPatch112: URL { appBundle.appendingPathComponent("log4j-rce-patch-1.12.xml") }

        static func current() -> RuntimePaths {
            let bundle = Bundle.main.bundleURL
            return RuntimePaths(
                frameworks: bundle.appendingPathComponent("Frameworks", isDirectory: true),
                libs: bundle.appendingPathComponent("libs", isDirectory: true),
                appBundle: bundle
            )
        }
    }

    // MARK: - Entry point

    static func build(
        config: LaunchConfiguration,
        version: MinecraftVersion,
        libraries: [Library],
        nativesDirectory: URL,
        runtimePaths: RuntimePaths = .current(),
        environment: RuleEnvironment = .current
    ) -> Invocation {
        var env = environment
        env.features = config.featureFlags

        var argv: [String] = []

        // ── Vanilla JVM arguments, filtered through the rule engine ──────────────
        // `default-user-jvm` is intentionally NOT included: it is a suggestion the
        // official launcher applies only when the user has no opinion, and it
        // carries `-Xms2G -Xmx4G` plus `-XX:+AlwaysPreTouch`, all of which are
        // actively harmful on a phone.
        let vanillaJVM = resolve(version.arguments?.jvm ?? [], env: env)
            .filter { !shouldDropVanillaArgument($0) }
        argv.append(contentsOf: vanillaJVM)

        // ── Identity, memory, Darwin platform ───────────────────────────────────
        argv.append("-XstartOnFirstThread")
        argv.append("-Xms128M")
        argv.append("-Xmx\(config.allocatedMemoryMB)M")

        // Java 8's launcher loads the system class loader before the application
        // classpath exists, so Caciocavallo's jars (which live on the boot class
        // path) cannot be seen by the default loader. `PojavClassLoader` is a
        // `URLClassLoader` subclass that can be appended to at runtime, which is
        // also what old Forge builds cast the system loader to.
        if config.javaMajorVersion <= 8 {
            argv.append("-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader")
        }

        argv.append("-Djava.library.path=\(runtimePaths.frameworks.path)")
        argv.append("-Duser.dir=\(LauncherPath.instance(config.instanceName).path)")
        // Also exported as $POJAV_HOME so the Java side can find the game root
        // without parsing JVM flags.
        argv.append("-Duser.home=\(LauncherPath.launcherRoot.path)")

        let timezone = TimeZone.current.identifier
        if !timezone.isEmpty {
            argv.append("-Duser.timezone=\(timezone)")
        }

        // ── Graphics backend ────────────────────────────────────────────────────
        let rendererName = config.renderer == .auto
            ? "libOSMesa.dylib"
            : config.renderer.rawValue
        argv.append("-Dorg.lwjgl.opengl.libname=\(rendererName)")

        // MoltenVK is the only Vulkan driver on iOS.
        argv.append("-Dorg.lwjgl.vulkan.libname=libMoltenVK.dylib")

        // ── LWJGL quirks ────────────────────────────────────────────────────────
        // GLFW's thread assertion is meaningless here because the JVM was already
        // told to start on the first thread by JLI_Launch itself.
        argv.append("-Dorg.lwjgl.glfw.checkThread0=false")
        // The default allocator probes for jemalloc, which is not present.
        argv.append("-Dorg.lwjgl.system.allocator=system")
        argv.append("-Dfml.earlyprogresswindow=false")

        // ── Security ────────────────────────────────────────────────────────────
        // Log4Shell mitigation. `formatMsgNoLookups` covers the modern Log4j 2
        // lookup path for every version, including ones whose metadata predates the
        // patch. Older versions need their own config file, handled below.
        argv.append("-Dlog4j2.formatMsgNoLookups=true")
        if let log4jConfig = log4jConfiguration(
            version: version,
            instanceName: config.instanceName,
            runtimePaths: runtimePaths
        ) {
            argv.append("-Dlog4j.configurationFile=\(log4jConfig.path)")
        }

        // ── Caciocavallo: AWT without X11 ───────────────────────────────────────
        argv.append(contentsOf: caciocavalloArguments(
            javaMajor: config.javaMajorVersion,
            width: config.width,
            height: config.height
        ))

        // ── Natives working directories ─────────────────────────────────────────
        // LWJGL, JNA and Netty all extract helper binaries at runtime. Point them
        // at the instance's writable natives directory; the default would be a
        // read-only location inside the bundle.
        let natives = nativesDirectory.path
        argv.append("-Djna.tmpdir=\(natives)/jna")
        argv.append("-Dorg.lwjgl.system.SharedLibraryExtractPath=\(natives)/lwjgl")
        argv.append("-Dio.netty.native.workdir=\(natives)/netty")

        // ── Launcher identity, surfaced in-game as the version label ────────────
        argv.append("-Dminecraft.launcher.brand=\(config.launcherName)")
        argv.append("-Dminecraft.launcher.version=\(config.launcherVersion)")

        // ── User-supplied flags, last so they win over ours ─────────────────────
        argv.append(contentsOf: sanitizeUserJVMArgs(config.customJVMArgs))

        // ── Classpath ───────────────────────────────────────────────────────────
        // Emitted as two tokens because `${classpath}` also appears inside some
        // versions' own JVM argument lists, and those are filtered out above in
        // favour of this one.
        let classpathValue = classpath(
            versionId: config.versionId,
            libraries: libraries,
            runtimePaths: runtimePaths
        )
        argv.append("-cp")
        argv.append(classpathValue)

        // ── Game arguments ──────────────────────────────────────────────────────
        let templates = templateValues(
            config: config,
            version: version,
            libraries: libraries,
            nativesDirectory: nativesDirectory,
            classpath: classpathValue,
            rendererName: rendererName
        )

        argv.append("net.kdt.pojavlaunch.PojavLauncher")
        argv.append(config.username)
        argv.append(config.versionId)

        // The launcher class reads the remaining arguments as the Minecraft
        // command line, so they are appended after the two positional ones.
        let gameArgs: [String]
        if let structured = version.arguments?.game {
            gameArgs = resolve(structured, env: env).compactMap {
                substitute($0, with: templates)
            }
        } else if let legacy = version.minecraftArguments {
            gameArgs = legacy.split(separator: " ").compactMap {
                substitute(String($0), with: templates)
            }
        } else {
            gameArgs = []
        }
        argv.append(contentsOf: gameArgs)

        return Invocation(
            // `argv[0]`. There is deliberately no `bin/java` in the bundled
            // runtimes — they are trimmed builds with only `lib/`. `JLI_Launch`
            // uses argv[0] purely to locate `libjli.dylib` and, through it,
            // `lib/server/libjvm.dylib`; the path itself is never executed.
            //
            // Passing the runtime root rather than a fabricated `bin/java` keeps
            // the value meaningful: it is what appears in `jps` output and in any
            // error the VM prints about its own location.
            executable: config.javaHome,
            arguments: argv,
            workingDirectory: LauncherPath.instance(config.instanceName)
        )
    }

    // MARK: - Log4j configuration

    /// Picks the Log4j config file to hand the game, or nil to let it use its own.
    ///
    /// Two of Minecraft's own logging configs are vulnerable to Log4Shell in a way
    /// that `-Dlog4j2.formatMsgNoLookups` alone does not fully close for the Log4j
    /// 1.x line, so the upstream ships hardened replacements:
    ///
    /// * `client-1.12.xml` → `log4j-rce-patch-1.12.xml`
    /// * `client-1.7.xml`  → `log4j-rce-patch-1.7.xml`
    ///
    /// Every other version uses the config Mojang serves for it, which
    /// `ResourceDownloader` fetches into the game directory under its own file id.
    static func log4jConfiguration(
        version: MinecraftVersion,
        instanceName: String,
        runtimePaths: RuntimePaths
    ) -> URL? {
        guard let logging = version.logging else { return nil }
        let fm = FileManager.default
        let id = logging.client.file.id

        switch id {
        case "client-1.12.xml":
            guard fm.fileExists(atPath: runtimePaths.log4jPatch112.path) else {
                LogConsole.shared.warning("缺少 log4j-rce-patch-1.12.xml，将退回游戏自带的日志配置。")
                return nil
            }
            return runtimePaths.log4jPatch112

        case "client-1.7.xml":
            guard fm.fileExists(atPath: runtimePaths.log4jPatch17.path) else {
                LogConsole.shared.warning("缺少 log4j-rce-patch-1.7.xml，将退回游戏自带的日志配置。")
                return nil
            }
            return runtimePaths.log4jPatch17

        default:
            // The game resolves `${path}` itself from the version metadata, so the
            // file only has to exist in the game directory. If the download has not
            // happened yet, returning nil is correct — the game falls back to its
            // built-in configuration rather than failing to start.
            let downloaded = LauncherPath.instance(instanceName).appendingPathComponent(id)
            guard fm.fileExists(atPath: downloaded.path) else { return nil }
            return downloaded
        }
    }

    // MARK: - Template substitution

    /// Values for the `${...}` placeholders in Mojang's argument lists.
    static func templateValues(
        config: LaunchConfiguration,
        version: MinecraftVersion,
        libraries: [Library],
        nativesDirectory: URL,
        classpath: String,
        rendererName: String
    ) -> [String: String] {
        // Mojang gives us `assets/objects/<ab>/<hash>`; lift it to the index file so
        // `startDir` becomes `assets`, which is the directory the game expects.
        let startDir = LauncherPath.assetIndex(version.assetIndexId)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path

        return [
            "auth_player_name": config.username,
            "version_name": config.versionId,
            "game_directory": LauncherPath.instance(config.instanceName).path,
            "assets_root": startDir,
            "assets_index_name": version.assetIndexId,
            "auth_uuid": config.uuid,
            "auth_access_token": config.accessToken,
            // Offline mode sends the literal `0`; the game then skips the session
            // join entirely and relies on the `--uuid` we pass.
            "auth_session": config.userType == "legacy" ? "0" : config.accessToken,
            "auth_xuid": config.xuid,
            "clientid": config.clientId,
            "user_type": config.userType,
            "version_type": version.type,
            "natives_directory": nativesDirectory.path,
            "launcher_name": config.launcherName,
            "launcher_version": config.launcherVersion,
            "classpath": classpath,
            "classpath_separator": ":",
            "library_directory": LauncherPath.libraries.path,
            "resolution_width": String(config.width),
            "resolution_height": String(config.height),
            "quickPlayPath": "",
            "quickPlaySingleplayer": config.quickPlaySingleplayer ?? "",
            "quickPlayMultiplayer": "",
            "quickPlayRealms": "",
            "renderer": rendererName,
            "game_assets": LauncherPath.assets.appendingPathComponent("virtual/legacy").path,
        ]
    }

    /// Replaces every `${key}` in `input`. Returns nil when a placeholder has no
    /// value, which is how an unsupported feature argument gets dropped instead of
    /// being handed to the game with a literal `${...}` in it.
    static func substitute(_ input: String, with values: [String: String]) -> String? {
        guard input.contains("${") else { return input }
        var out = input
        for (key, value) in values {
            out = out.replacingOccurrences(of: "${\(key)}", with: value)
        }
        // An unresolved placeholder means we do not know how to satisfy it.
        return out.contains("${") ? nil : out
    }

    // MARK: - Rule resolution

    /// Flattens `[Element]` into concrete strings, applying the rule engine.
    static func resolve(_ elements: [Arguments.Element], env: RuleEnvironment) -> [String] {
        var out: [String] = []
        for element in elements {
            switch element {
            case let .literal(text):
                out.append(text)
            case let .conditional(cond):
                if env.allows(cond.rules) {
                    out.append(contentsOf: cond.value)
                }
            }
        }
        return out
    }

    // MARK: - Vanilla argument filtering

    /// Drops vanilla JVM flags that are wrong or redundant on iOS.
    static func shouldDropVanillaArgument(_ arg: String) -> Bool {
        // We emit these ourselves with iOS-correct values. Duplicates are not
        // fatal, but a second `-XstartOnFirstThread` is, because the JVM rejects
        // it when it is already running on the first thread.
        if arg == "-XstartOnFirstThread" { return true }
        if arg.hasPrefix("-Xmx") || arg.hasPrefix("-Xms") { return true }
        if arg.hasPrefix("-Xss") { return true }

        // Desktop arguments for Windows-only heap-dump naming.
        if arg.hasPrefix("-XX:HeapDumpPath=") { return true }

        // `-Djava.library.path` points at the desktop natives layout; ours points
        // at the app's Frameworks directory.
        if arg.hasPrefix("-Djava.library.path=") { return true }

        // `-cp` / `-classpath` come from the metadata with a desktop native list.
        // We supply our own immediately before the main class.
        if arg == "-cp" || arg == "-classpath" { return true }
        if arg.contains("${classpath}") { return true }

        // Desktop launcher identity; replaced with ours.
        if arg.hasPrefix("-Dminecraft.launcher.brand=") { return true }
        if arg.hasPrefix("-Dminecraft.launcher.version=") { return true }

        return false
    }

    // MARK: - Caciocavallo

    /// The AWT toolkit that lets Minecraft's Swing-based bits (the Realms browser,
    /// the crash dialog, Forge's installer window) run with no window server.
    ///
    /// Java 8 and Java 17 use different package names for the same classes — the
    /// project was relicensed and repackaged between them — so the flags differ.
    static func caciocavalloArguments(javaMajor: Int, width: Int, height: Int) -> [String] {
        var args = [
            "-Djava.awt.headless=false",
            "-Dcacio.font.fontmanager=sun.awt.X11FontManager",
            "-Dcacio.font.fontscaler=sun.font.FreetypeFontScaler",
            "-Dcacio.managed.screensize=\(width)x\(height)",
            "-Dswing.defaultlaf=javax.swing.plaf.metal.MetalLookAndFeel",
        ]

        if javaMajor <= 8 {
            args.append("-Dawt.toolkit=net.java.openjdk.cacio.ctc.CTCToolkit")
            args.append("-Djava.awt.graphicsenv=net.java.openjdk.cacio.ctc.CTCGraphicsEnvironment")
        } else {
            args.append("-Dawt.toolkit=com.github.caciocavallosilano.cacio.ctc.CTCToolkit")
            args.append("-Djava.awt.graphicsenv=com.github.caciocavallosilano.cacio.ctc.CTCGraphicsEnvironment")

            // Caciocavallo17 reaches into JDK internals, which the module system
            // seals by default. Missing any one of these produces an
            // InaccessibleObjectException at the first AWT call, long after the
            // game window has appeared — so they are all listed, not just the
            // ones that seem necessary.
            args.append(contentsOf: [
                "--add-exports=java.desktop/java.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.image=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-exports=java.desktop/java.awt.dnd.peer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.event=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.awt.datatransfer=ALL-UNNAMED",
                "--add-exports=java.desktop/sun.font=ALL-UNNAMED",
                "--add-exports=java.base/sun.security.action=ALL-UNNAMED",
                "--add-opens=java.base/java.util=ALL-UNNAMED",
                "--add-opens=java.desktop/java.awt=ALL-UNNAMED",
                "--add-opens=java.desktop/sun.font=ALL-UNNAMED",
                "--add-opens=java.desktop/sun.java2d=ALL-UNNAMED",
                "--add-opens=java.base/java.lang.reflect=ALL-UNNAMED",
            ])

            // Forge's bootstrapper wraps the system class loader and needs its own
            // module opened. Harmless for versions that do not use it.
            args.append("--add-exports=cpw.mods.bootstraplauncher/cpw.mods.bootstraplauncher=ALL-UNNAMED")

            // Native access became a hard error rather than a warning in recent
            // JDKs; LWJGL is a heavy user of it.
            args.append("--enable-native-access=ALL-UNNAMED")
        }

        return args
    }

    // MARK: - Classpath

    /// Builds the `-cp` value for a version.
    ///
    /// Order encodes precedence, first match wins:
    ///
    /// 1. `<App>/libs/*` — the patched LWJGL and Caciocavallo jars. These **must**
    ///    shadow the vanilla ones; if Mojang's desktop LWJGL wins, the first GLFW
    ///    or OpenGL call dies with `UnsatisfiedLinkError`.
    /// 2. Per-library jars — excludes LWJGL, JInput and the macOS ObjC bridge,
    ///    all of which the app bundle replaces.
    /// 3. The client jar itself.
    static func classpath(
        versionId: String,
        libraries: [Library],
        runtimePaths: RuntimePaths
    ) -> String {
        var entries: [String] = []

        // 1. A wildcard, so a renamed or missing bundled jar degrades into a
        //    visible `NoClassDefFoundError` rather than a silently empty classpath.
        entries.append("\(runtimePaths.libs.path)/*")

        // 2. Vanilla dependencies, minus the desktop-only native bundles.
        for library in libraries where !library.isDesktopNativeBundle {
            guard let artifact = library.downloads?.artifact else { continue }
            entries.append(LauncherPath.library(artifact.path).path)
        }

        // 3. The game itself.
        entries.append(LauncherPath.versionJar(versionId).path)

        return entries.joined(separator: ":")
    }

    // MARK: - User arguments

    /// Flags the launcher owns. A user-supplied copy would either be ignored (the
    /// JVM takes the last occurrence) or break the launch, so they are stripped
    /// with a warning rather than passed through.
    private static let reservedPrefixes = [
        "-Xmx", "-Xms", "-Xss", "-cp", "-classpath",
        "-Djava.library.path", "-Djava.home", "-Duser.home", "-Duser.dir",
        "-Dorg.lwjgl.opengl.libname", "-Dorg.lwjgl.vulkan.libname",
        "-Dcacio.managed.screensize", "-Dawt.toolkit", "-Djava.awt.graphicsenv",
    ]

    static func sanitizeUserJVMArgs(_ raw: [String]) -> [String] {
        raw.compactMap { token in
            let trimmed = token.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            for prefix in reservedPrefixes where trimmed.hasPrefix(prefix) {
                LogConsole.shared.warning("已忽略由启动器接管的 JVM 参数：\(trimmed)")
                return nil
            }

            // Normalise a bare flag into the `-`-prefixed form the JVM wants.
            return trimmed.hasPrefix("-") ? trimmed : "-\(trimmed)"
        }
    }

    /// Splits a user-typed argument string on whitespace while honouring quotes,
    /// so `-Dfoo="bar baz"` survives.
    static func splitArguments(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false

        for char in input {
            if char == "\"" {
                inQuotes.toggle()
            } else if char.isWhitespace && !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(char)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    /// Parses `KEY=value KEY2=value2` into a dictionary, rejecting malformed pairs
    /// so a typo cannot inject an empty environment variable name.
    static func parseEnvironmentVariables(_ input: String) -> [String: String] {
        var out: [String: String] = [:]
        for token in splitArguments(input) {
            let parts = token.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }
            out[key] = String(parts[1])
        }
        return out
    }
}
