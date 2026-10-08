# Java 运行时

## 结论

**本启动器支持 Minecraft 1.16.5 及更早（Java 8）和 1.17 – 1.20.4（Java 17）。**

**1.20.5 及更新的版本需要 Java 21，目前做不到。**

这不是实现上的取舍，而是**运行时二进制不存在**。下面是核实过的完整情况。

---

## 内置的运行时

它们直接来自上游 PojavLauncher v2.2 的发行包，位于 App 包内：

```
CraftLauncher.app/java_runtimes/
├── java-8-openjdk/       release: JAVA_VERSION="1.8.0"    OS_ARCH="aarch64"
└── java-17-openjdk/      release: JAVA_VERSION="17.0.8"   OS_ARCH="aarch64"
```

两个都是**精简构建**：

- **没有 `bin/` 目录**，不存在 `bin/java` 可执行文件
- Java 8 的 `libjli.dylib` 在 `lib/jli/`，Java 17 的在 `lib/`
- 都自带 `lib/libawt_xawt.dylib`（58,832 字节）

启动方式不是执行 `bin/java`，而是 `dlopen("libjli.dylib")` 后调用 `JLI_Launch` ——
所以缺少 `bin/` 完全不影响。

## 版本映射

Mojang 的版本元数据里有 `javaVersion.majorVersion`，启动器据此选择运行时：

| 元数据要求 | 选用的运行时 | 对应游戏版本 |
|---|---|---|
| ≤ 8 | `java-8-openjdk` | 1.16.5 及更早 |
| 9 – 17 | `java-17-openjdk` | 1.17 – 1.20.4 |
| ≥ 21 | **无** —— 明确拒绝 | 1.20.5 及更新 |

选择逻辑取「**满足要求的最小版本**」，不是最新版本。这一点很关键：
Minecraft 1.17 – 1.20.4 在 Java 21+ 上会崩，因为它们的部分依赖会拒绝更新的 class 文件。
「用最新版总没错」在这里是错的，而且产生的崩溃离原因很远。

---

## 为什么没有 Java 21

### 直接原因：上游的 iOS 构建用的是自托管 runner，那台机器没了

关键证据在上游的 CI 定义里（`.github/workflows/build.yml`，`buildjre17-21` 分支）：

```yaml
build_iosport:
  strategy:
    matrix:
      version: [17, 21]          # ← Java 21 的构建任务确实存在
    fail-fast: false
  name: "Build Java ${{ matrix.version }} for iOS aarch64"
  runs-on: MacStadium            # ← 自托管 runner，不是 GitHub 托管
  continue-on-error: true        # ← 失败也不让整个构建变红
  steps:
    - uses: actions/checkout@v4
    - name: Build with CI build script
      run: |
        export BUILD_IOS=1
        export TARGET_VERSION=${{ matrix.version }}
        bash "1_ci_build_arch_aarch64.sh"
    - uses: actions/upload-artifact@v4
      with:
        name: "jre${{ matrix.version }}-ios-aarch64"
        path: jre${{ matrix.version }}*.tar.xz
```

三点值得注意：

1. **Java 21 的构建任务存在** —— `matrix.version: [17, 21]`，同一个脚本靠
   `TARGET_VERSION` 切换，产物名 `jre21-ios-aarch64`。
2. **`runs-on: MacStadium`** —— 是他们自己的一台 Mac，不是 GitHub 的托管 runner。
   这台机器早就没了，所以这个 job 永远排不上队。
3. **`continue-on-error: true`** —— job 失败不会让整个 workflow 变红。
   所以它消失之后**没人注意到**，直到产物慢慢全部过期。

这就解释了为什么「最新的开发构建 #1236 是 cancelled」、以及为什么那个仓库的
artifacts 接口返回 0 条。

### 其他来源的核查结果

| 来源 | Java 8 | Java 17 | Java 21 | Java 25 |
|---|---|---|---|---|
| PojavLauncher **正式版** v2.2 的 `java_runtimes/` | ✅ | ✅ | ❌ | ❌ |
| PojavLauncher **开发构建**（GitHub Actions） | ✅ | ✅ | ✅ 曾经有 | ❌ 从未见过 |
| `android-openjdk-build-multiarch` 的 `buildjre17-21` 产物 | — | ✅ | ✅ 曾经有 | ❌ |
| **现在可下载的** | ✅ | ✅ | **❌ 全部过期** | ❌ |

正式版里确实没有 Java 21：我下载了 v2.2 的 IPA 并解剖，`java_runtimes/` 下只有两个目录。
维护者在 [issue #705](https://github.com/PojavLauncherTeam/PojavLauncher_iOS/issues/705)
也确认了正式版是两年前发布的，那时还没有 Java 21。

### Java 25 没有任何来源

上游从没构建过，`matrix.version` 里只有 17 和 21。

---

## 如果你需要 Java 21：可执行的复现步骤

**配方完整，障碍是 runner。** 换成 GitHub 托管的 macOS runner 就能跑。

仓库 `.github/workflows/build-ios-jre21.yml` 就是为此准备的，照抄进你的 fork 即可。

### 步骤

1. **Fork** [`PojavLauncherTeam/android-openjdk-build-multiarch`](https://github.com/PojavLauncherTeam/android-openjdk-build-multiarch)
2. **切到 `buildjre17-21` 分支**（默认分支是 `buildjre8`，那是给 Java 8 的）
3. **把 `.github/workflows/build-ios-jre21.yml` 复制进 fork**，放在
   `.github/workflows/` 下
4. **启用 Actions**：仓库已归档，fork 出来的副本默认关闭工作流。
   到 `Settings → Actions → General` 打开，然后推一个空 commit 触发识别
5. **运行**：`Actions → Build iOS arm64 JRE 21 → Run workflow`
6. **下载产物** `jre21-ios-aarch64`
7. 解压后按下面的结构放好，并改 `RuntimeTag`

### 必须放进 App 包，不能解压到 Documents

产物是一个 `.tar.xz`，解开后应包含：

```
java-21-openjdk/
├── release                       # 必须有 —— 启动器据此识别版本
└── lib/
    ├── libjli.dylib
    └── server/libjvm.dylib
```

放到 `Runtime/java_runtimes/java-21-openjdk/`，然后重跑
`Scripts/bootstrap-runtime.sh` 会覆盖这个目录 —— 所以要么把产物放在
`Runtime/java_runtimes/` 之外用脚本拷进来，要么在跑完 bootstrap 之后再放。

`Scripts/verify.py` 会对着 `Runtime/java_runtimes/` 里的实际目录检查
`libjli` / `libjvm` / `libawt_xawt.dylib` 是否存在，结构不对会直接报错。

### 改 Swift：只有两处，且第二处不要动

```swift
// Sources/Models/VersionManifest.swift

enum RuntimeTag {
    static let java8 = "java-8-openjdk"
    static let java17 = "java-17-openjdk"
    static let java21 = "java-21-openjdk"        // ← 新增

    static let all = [java8, java17, java21]     // ← 加进列表

    static func major(for tag: String) -> Int {
        switch tag {
        case java8: return 8
        case java17: return 17
        case java21: return 21                    // ← 新增
        default: return 17
        }
    }
}
```

**`minimumTag(forMajor:)` 一个字都不要改。** 它现在的写法是：

```swift
static func minimumTag(forMajor major: Int) -> String? {
    all
        .filter { self.major(for: $0) >= major }
        .min { self.major(for: $0) < self.major(for: $1) }
}
```

加桶之后自动正确：需要 8 的仍拿 Java 8，需要 17 的仍拿 Java 17，需要 21 的才拿
Java 21。**如果改回阈值链的写法**（`if major <= 8 { return java8 }` …），
`all` 的顺序或阈值一旦写错，就会把 1.17–1.20.4 错配到 Java 21 ——
而那些版本在新 JDK 上会崩，且崩溃离原因很远。

### 预期

- **耗时 1–3 小时**。完整 OpenJDK 交叉编译就是这么慢。
- **第一次大概率失败。** 配方最后是针对 Xcode 12 调的，而 macOS runner 已经更新了
  很多代。留几轮调试的余量，**看编译日志而不是直接怀疑配置**。
- **`.ipa` 会再大约 100 MB**（当前 266 MB 运行时，加完接近 370 MB）。
  如果你用免费证书侧载，注意证书有效期和包体大小都可能成为问题。

---

## 为什么不能在本项目里交叉编译 OpenJDK

即便配方齐全，也绕不过这个前提：

- **必须是 macOS。** `ios-arm64-clang` 包装的是 Xcode 的 clang 和 iOS SDK，
  `macos-host-cc` 需要 macOS 的本地编译器构建 JDK 自己的工具（`javac`、`jlink` 等）。
- **需要数小时 CI 时间**，而且大概率要几轮调试。
- **仓库已归档**，没有上游维护。

这是一个独立于启动器的项目，量级和本工程相当。所以本项目选择**依赖上游产物**，
拿不到时诚实地告诉你范围到哪里，而不是假装能支持。
