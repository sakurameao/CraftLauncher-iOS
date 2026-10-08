import Foundation

// MARK: - Version manifest (version_manifest_v2.json)

/// The version list served by `https://piston-meta.mojang.com/mc/game/version_manifest_v2.json`.
struct VersionManifest: Codable, Equatable {
    struct Latest: Codable, Equatable {
        let release: String
        let snapshot: String
    }

    struct Entry: Codable, Equatable, Identifiable, Hashable {
        let id: String
        /// `release`, `snapshot`, `old_beta`, `old_alpha`.
        let type: String
        let url: String
        let time: Date
        let releaseTime: Date
        let sha1: String
        let complianceLevel: Int?

        var isRelease: Bool { type == "release" }
        var isSnapshot: Bool { type == "snapshot" }
        var isAncient: Bool { type.hasPrefix("old_") }

        /// Release date rendered the way Mojang's own UI shows it.
        var releaseDateLabel: String {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            f.locale = Locale(identifier: "en_US_POSIX")
            return f.string(from: releaseTime)
        }
    }

    let latest: Latest
    let versions: [Entry]
}

// MARK: - Version detail (<hash>/<id>.json)

/// A single version's metadata. This mirrors Mojang's schema exactly — every field
/// name here was verified against a live `1.21.x`/`26.x` document.
struct MinecraftVersion: Codable, Equatable {
    struct AssetIndex: Codable, Equatable {
        let id: String
        let sha1: String
        let size: Int
        let totalSize: Int
        let url: String
    }

    struct Download: Codable, Equatable {
        let sha1: String
        let size: Int
        let url: String
    }

    struct Downloads: Codable, Equatable {
        let client: Download
        let server: Download?
        /// Omitted by many older versions.
        let client_mappings: Download?
        let server_mappings: Download?
    }

    struct JavaVersion: Codable, Equatable {
        /// e.g. `java-runtime-delta`. Only meaningful for the official launcher,
        /// which maps it to a Mojang-hosted JRE we cannot use on iOS.
        let component: String
        /// This is the number that decides which runtime bucket we pick.
        let majorVersion: Int
    }

    struct LoggingConfig: Codable, Equatable {
        struct Client: Codable, Equatable {
            struct File: Codable, Equatable {
                let id: String
                let sha1: String
                let size: Int
                let url: String
            }
            let argument: String
            let file: File
            let type: String
        }
        let client: Client
    }

    // Identity
    let id: String
    let type: String
    let mainClass: String
    let minimumLauncherVersion: Int?
    let releaseTime: Date
    let time: Date
    let complianceLevel: Int?

    // Modded / inherited versions
    /// Set by Fabric, Forge, OptiFine and friends to point at the vanilla version
    /// they build on. Must be merged before launching.
    let inheritsFrom: String?
    /// Present on Forge 1.17+ which needs a bootstrapper instead of a main class.
    let jar: String?

    // Launch data
    let arguments: Arguments?
    /// Only present on versions older than 1.13.
    let minecraftArguments: String?
    let javaVersion: JavaVersion?
    let assetIndex: AssetIndex?
    let assets: String?
    let downloads: Downloads?
    let libraries: [Library]
    let logging: LoggingConfig?

    // MARK: Convenience

    /// Java major version required to run this version. Defaults to 8 because every
    /// version predating the `javaVersion` field is Java 8 era.
    var requiredJavaMajor: Int {
        javaVersion?.majorVersion ?? 8
    }

    /// The runtime tag that satisfies this version's Java requirement, or nil when
    /// no bundled runtime is new enough.
    ///
    /// Nil is a real possibility, not a defensive flourish: Minecraft 1.20.5 and
    /// newer ask for Java 21, and no iOS Java 21 runtime is publicly obtainable.
    /// Callers must turn nil into a clear message rather than launching.
    var runtimeTag: String? {
        RuntimeTag.minimumTag(forMajor: requiredJavaMajor)
    }

    /// True when this version cannot run with the bundled runtimes.
    var requiresUnavailableJava: Bool {
        runtimeTag == nil
    }

    var assetIndexId: String {
        assetIndex?.id ?? assets ?? "legacy"
    }
}

// MARK: - Arguments (the polymorphic bit)

/// `arguments` is an array whose elements are *either* a bare string *or* an object
/// carrying `rules` plus a `value` that is either a string or an array of strings:
///
/// ```json
/// "jvm": [
///   "-XX:StackShadowPages=32",
///   { "rules": [{"action":"allow","os":{"name":"osx"}}], "value": ["-XstartOnFirstThread"] },
///   { "rules": [...], "value": "--demo" }
/// ]
/// ```
///
/// A plain `Decodable` synthesis cannot express this, so the decoder below walks the
/// array manually. Getting this wrong is the single most common cause of a launcher
/// producing an argument list the game rejects, so it is written defensively: any
/// element shaped unexpectedly is skipped rather than throwing.
struct Arguments: Codable, Equatable {
    /// Either a plain string or a conditional group.
    enum Element: Equatable {
        case literal(String)
        case conditional(ConditionalArgument)
    }

    struct ConditionalArgument: Codable, Equatable {
        let rules: [Rule]
        /// Mojang uses both forms interchangeably; normalised to an array here.
        let value: [String]

        private enum CodingKeys: String, CodingKey { case rules, value }

        init(rules: [Rule], value: [String]) {
            self.rules = rules
            self.value = value
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            rules = (try? c.decode([Rule].self, forKey: .rules)) ?? []
            if let many = try? c.decode([String].self, forKey: .value) {
                value = many
            } else if let one = try? c.decode(String.self, forKey: .value) {
                value = [one]
            } else {
                value = []
            }
        }
    }

    var jvm: [Element]
    var game: [Element]
    /// Present on very new versions (1.21.9+). Same element shape as `jvm`, but it
    /// is a *suggested default* heap configuration that a launcher is expected to
    /// override, not append to.
    var defaultUserJvm: [Element]

    init(jvm: [Element] = [], game: [Element] = [], defaultUserJvm: [Element] = []) {
        self.jvm = jvm
        self.game = game
        self.defaultUserJvm = defaultUserJvm
    }

    private enum CodingKeys: String, CodingKey {
        case jvm, game
        case defaultUserJvm = "default-user-jvm"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        jvm = Arguments.decodeElements(from: c, forKey: .jvm)
        game = Arguments.decodeElements(from: c, forKey: .game)
        defaultUserJvm = Arguments.decodeElements(from: c, forKey: .defaultUserJvm)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(jvm, forKey: .jvm)
        try c.encode(game, forKey: .game)
        try c.encode(defaultUserJvm, forKey: .defaultUserJvm)
    }

    private static func decodeElements(
        from container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [Element] {
        // A catch-all lets one array hold both shapes without a custom container.
        enum AnyElement: Decodable {
            case text(String)
            case object(ConditionalArgument)

            init(from decoder: Decoder) throws {
                let single = try decoder.singleValueContainer()
                if let s = try? single.decode(String.self) {
                    self = .text(s)
                } else {
                    self = .object(try single.decode(ConditionalArgument.self))
                }
            }
        }

        guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: key) else {
            return []
        }
        var out: [Element] = []
        while !unkeyed.isAtEnd {
            guard let raw = try? unkeyed.decode(AnyElement.self) else { break }
            switch raw {
            case let .text(s): out.append(.literal(s))
            case let .object(o): out.append(.conditional(o))
            }
        }
        return out
    }
}

// MARK: - Rules

/// The `rules` engine. A library or argument is permitted when the rule list
/// evaluates to true, using Mojang's exact semantics:
///
/// * an **empty** rule list means allowed;
/// * otherwise the *last* matching rule wins;
/// * if no rule matches, the result is the opposite of the default — which is
///   `disallow` when the first rule is an `allow`.
struct Rule: Codable, Equatable {
    enum Action: String, Codable {
        case allow, disallow
    }

    struct OS: Codable, Equatable {
        /// `windows`, `osx`, `linux`. Absent means "any OS".
        let name: String?
        /// `x86`, `x86_64`, `arm64`. Absent means "any architecture".
        let arch: String?
        let version: String?
        /// Only used by a handful of Windows-specific libraries.
        let versionRange: VersionRange?
    }

    struct VersionRange: Codable, Equatable {
        let min: String?
        let max: String?
    }

    struct Features: Codable, Equatable {
        let is_demo_user: Bool?
        let has_custom_resolution: Bool?
        let has_quick_plays_support: Bool?
        let is_quick_play_singleplayer: Bool?
        let is_quick_play_multiplayer: Bool?
        let is_quick_play_realms: Bool?
    }

    let action: Action
    let os: OS?
    let features: Features?
}

/// The environment a rule is evaluated against.
///
/// **iOS is deliberately reported as `osx`.** The bundled LWJGL and the
/// Caciocavallo AWT bridge are Darwin builds, and the version metadata gates
/// macOS-only libraries — most importantly `-XstartOnFirstThread`, without which
/// GLFW never pumps the run loop on a Darwin kernel — behind `"os.name": "osx"`.
/// Reporting `ios` here would silently drop those entries and the game would hang
/// on a black screen at startup.
struct RuleEnvironment: Equatable {
    var osName: String
    var osVersion: String
    var arch: String
    var features: FeatureFlags

    struct FeatureFlags: Equatable {
        var isDemoUser = false
        var hasCustomResolution = true
        var hasQuickPlaysSupport = false
        var isQuickPlaySingleplayer = false
        var isQuickPlayMultiplayer = false
        var isQuickPlayRealms = false
    }

    static var current: RuleEnvironment {
        RuleEnvironment(
            osName: "osx",
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            arch: RuleEnvironment.hostArch,
            features: FeatureFlags()
        )
    }

    /// Mojang's arch vocabulary is `x86`, `x86_64`, `arm64`. Every iOS device this
    /// launcher can run on is arm64, but simulator builds are not, so detect it.
    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "arm64"
        #endif
    }

    func allows(_ rules: [Rule]) -> Bool {
        guard !rules.isEmpty else { return true }

        // If no rule matches we invert whether the first rule was a disallow,
        // which is the documented Mojang behaviour.
        var result = rules.first?.action == .disallow

        for rule in rules where matches(rule) {
            result = rule.action == .allow
        }
        return result
    }

    private func matches(_ rule: Rule) -> Bool {
        if let os = rule.os {
            if let name = os.name, name != osName { return false }
            if let arch = os.arch, arch != self.arch { return false }
            // Windows build-range rules never apply here, but evaluate them
            // faithfully for completeness.
            if let range = os.versionRange {
                guard let current = VersionRangeCompare.parse(osVersion) else { return false }
                if let min = range.min, let minV = VersionRangeCompare.parse(min), current < minV {
                    return false
                }
                if let max = range.max, let maxV = VersionRangeCompare.parse(max), current > maxV {
                    return false
                }
            }
        }

        if let f = rule.features {
            if let v = f.is_demo_user, v != features.isDemoUser { return false }
            if let v = f.has_custom_resolution, v != features.hasCustomResolution { return false }
            if let v = f.has_quick_plays_support, v != features.hasQuickPlaysSupport { return false }
            if let v = f.is_quick_play_singleplayer, v != features.isQuickPlaySingleplayer { return false }
            if let v = f.is_quick_play_multiplayer, v != features.isQuickPlayMultiplayer { return false }
            if let v = f.is_quick_play_realms, v != features.isQuickPlayRealms { return false }
        }

        return true
    }
}

/// Dotted-numeric comparison for the Windows `versionRange` field.
enum VersionRangeCompare {
    static func parse(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".").map { Int($0) ?? 0 }
        return parts.isEmpty ? nil : parts
    }

    static func less(_ a: [Int], _ b: [Int]) -> Bool {
        for i in 0..<Swift.max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x < y }
        }
        return false
    }
}

extension Array where Element == Int {
    static func < (lhs: [Int], rhs: [Int]) -> Bool { VersionRangeCompare.less(lhs, rhs) }
    static func > (lhs: [Int], rhs: [Int]) -> Bool { VersionRangeCompare.less(rhs, lhs) }
}

// MARK: - Libraries

struct Library: Codable, Equatable {
    struct Artifact: Codable, Equatable {
        let path: String
        let sha1: String
        let size: Int
        let url: String
    }

    struct Classifiers: Codable, Equatable {
        let natives_linux: Artifact?
        let natives_macos: Artifact?
        let natives_osx: Artifact?
        let natives_windows: Artifact?

        /// Classifier key Mojang uses for the current platform. Returns nil on iOS
        /// because the bundled LWJGL ships its own natives inside `Frameworks/`.
        var currentPlatformArtifact: Artifact? {
            #if os(macOS)
            return natives_macos ?? natives_osx
            #else
            return nil
            #endif
        }
    }

    struct Downloads: Codable, Equatable {
        let artifact: Artifact?
        let classifiers: Classifiers?
    }

    struct Extract: Codable, Equatable {
        let exclude: [String]?
    }

    struct Natives: Codable, Equatable {
        let osx: String?
        let linux: String?
        let windows: String?
    }

    /// Maven coordinates: `group:artifact:version[:classifier]`.
    let name: String
    let downloads: Downloads?
    /// Only present on pre-1.19 metadata.
    let natives: Natives?
    let extract: Extract?
    let rules: [Rule]?
    /// 1.21.9+ flag for libraries that ship native code and need
    /// `--enable-native-access`. Informational on iOS.
    let artifact: Artifact?

    /// `group:artifact:version` Maven path, e.g. `org/lwjgl/lwjgl/3.4.3`.
    var mavenDirectory: String {
        let parts = name.split(separator: ":").map(String.init)
        guard parts.count >= 3 else { return "" }
        return "\(parts[0].replacingOccurrences(of: ".", with: "/"))/\(parts[1])/\(parts[2])"
    }

    var artifactId: String {
        let parts = name.split(separator: ":").map(String.init)
        return parts.count >= 2 ? parts[1] : name
    }

    var groupId: String {
        name.split(separator: ":").first.map(String.init) ?? ""
    }

    /// True for the LWJGL and JInput bundles Mojang ships for desktop platforms.
    ///
    /// These must be filtered out on iOS: the app bundle provides Darwin-built
    /// replacements, and leaving the stock jars on the classpath shadows them,
    /// producing `UnsatisfiedLinkError` on the first GLFW call.
    var isDesktopNativeBundle: Bool {
        let id = artifactId
        return id.hasPrefix("lwjgl") || id.hasPrefix("jinput") || id == "java-objc-bridge"
    }

    /// True for libraries whose only purpose is a desktop windowing/compositor
    /// stack that does not exist on iOS.
    var isDesktopOnly: Bool {
        ["jna-platform"].contains(artifactId) || groupId == "ca.weblite"
    }
}

// MARK: - Runtime tags

/// The Java runtimes the launcher can use.
///
/// The tag **is** the directory name inside the app bundle, because that is how the
/// upstream ships them. Verified against the real v2.2 IPA:
///
///     PojavLauncher.app/java_runtimes/
///     ├── java-8-openjdk/     release: JAVA_VERSION="1.8.0"    OS_ARCH="aarch64"
///     └── java-17-openjdk/    release: JAVA_VERSION="17.0.8"   OS_ARCH="aarch64"
///
/// ## Only two runtimes, and that is not a choice
///
/// Minecraft 1.20.5 and newer declare `javaVersion.majorVersion` of 21 or higher.
/// **No iOS build of Java 21 or 25 is publicly downloadable** — the upstream CI
/// produces a `jre21-ios-aarch64` artifact in `android-openjdk-build-multiarch`
/// on the `buildjre17-21` branch, but every artifact on that repo has expired, and
/// the newest PojavLauncher development build is cancelled.
///
/// So the supported range is Minecraft 1.16.5 and older (Java 8) plus 1.17 through
/// 1.20.4 (Java 17). A version requiring more is refused with a clear message
/// rather than launched into an `UnsupportedClassVersionError` — see
/// `docs/JAVA-RUNTIMES.md` for how to obtain a newer runtime.
///
/// ## Selection is by smallest sufficient runtime, never newest
///
/// Handing Minecraft 1.17 a Java 21 runtime breaks it: several of its bundled
/// dependencies reject newer class files. "Newest always works" is false here and
/// produces crashes far from their cause, so `minimumTag` rounds *up* to the
/// smallest bucket that satisfies the requirement.
enum RuntimeTag {
    static let java8 = "java-8-openjdk"
    static let java17 = "java-17-openjdk"

    /// Every tag, oldest first.
    static let all = [java8, java17]

    /// The Java major version a tag provides.
    static func major(for tag: String) -> Int {
        switch tag {
        case java8: return 8
        case java17: return 17
        // A runtime the launcher does not recognise. Treated as modern so it is
        // never selected for a legacy version by accident.
        default: return 17
        }
    }

    static func label(for tag: String) -> String {
        "Java \(major(for: tag))"
    }

    /// The *smallest* tag that satisfies a requirement of `major`, or nil when no
    /// bundled runtime is new enough.
    ///
    /// Returning nil is deliberate. Rounding down to Java 17 for a version needing
    /// Java 21 would move the failure deep into the JVM, where it surfaces as a
    /// class-version error that tells the user nothing actionable.
    static func minimumTag(forMajor major: Int) -> String? {
        all
            .filter { self.major(for: $0) >= major }
            .min { self.major(for: $0) < self.major(for: $1) }
    }

    /// Highest Java version any bundled runtime provides.
    static var highestMajor: Int {
        all.map { major(for: $0) }.max() ?? 8
    }
}

// MARK: - Merge

extension MinecraftVersion {
    /// Flattens an `inheritsFrom` chain into one standalone version document.
    ///
    /// `child` is the derived version (Fabric/Forge/OptiFine); `parent` is the
    /// vanilla version it inherits from. The merge follows the official launcher's
    /// rules: the child overrides scalars, and **libraries are concatenated with
    /// the child first** so a mod loader can shadow a vanilla dependency.
    static func merge(child: MinecraftVersion, parent: MinecraftVersion) -> MinecraftVersion {
        MinecraftVersion(
            id: child.id,
            type: child.type,
            mainClass: child.mainClass,
            minimumLauncherVersion: child.minimumLauncherVersion ?? parent.minimumLauncherVersion,
            releaseTime: child.releaseTime,
            time: child.time,
            complianceLevel: child.complianceLevel ?? parent.complianceLevel,
            inheritsFrom: nil,
            jar: child.jar ?? parent.jar,
            arguments: mergeArguments(child: child.arguments, parent: parent.arguments),
            minecraftArguments: child.minecraftArguments ?? parent.minecraftArguments,
            // Java requirement: take the stricter of the two. A Forge build for
            // 1.20 must not be allowed to run on Java 8 just because it omitted
            // the field.
            javaVersion: {
                switch (child.javaVersion, parent.javaVersion) {
                case let (c?, p?): return c.majorVersion >= p.majorVersion ? c : p
                case let (c?, nil): return c
                case let (nil, p?): return p
                case (nil, nil): return nil
                }
            }(),
            assetIndex: child.assetIndex ?? parent.assetIndex,
            assets: child.assets ?? parent.assets,
            downloads: child.downloads ?? parent.downloads,
            libraries: child.libraries + parent.libraries,
            logging: child.logging ?? parent.logging
        )
    }

    /// Arguments concatenate: JVM defaults first, then the child's, so the derived
    /// version can add module flags that the vanilla list does not carry.
    private static func mergeArguments(child: Arguments?, parent: Arguments?) -> Arguments? {
        switch (child, parent) {
        case let (c?, p?):
            return Arguments(
                jvm: p.jvm + c.jvm,
                game: p.game + c.game,
                defaultUserJvm: c.defaultUserJvm.isEmpty ? p.defaultUserJvm : c.defaultUserJvm
            )
        case let (c?, nil): return c
        case let (nil, p?): return p
        case (nil, nil): return nil
        }
    }
}
