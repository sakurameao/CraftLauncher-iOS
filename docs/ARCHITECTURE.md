# 架构

## 一张图看懂

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI 界面（Sources/UI）                                  │
│  主页 · 版本 · Mod · 控制台 · 设置                            │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  服务层（Sources/Services）                                   │
│  VersionService    拉取并合并 Mojang 元数据                    │
│  ResourceDownloader 算差集、并发下载、SHA-1 校验               │
│  JVMArguments      组装 JVM 命令行（纯逻辑，可测）              │
│  LaunchPipeline    编排整条启动链路                            │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  JVM 桥接（Sources/Runtime/RuntimeBridge.mm）                 │
│  dlopen(libjli.dylib) → JLI_Launch(argv)                     │
│  重定向 stdout/stderr → 管道 → 控制台                          │
└───────────────────────────┬─────────────────────────────────┘
                            │
┌───────────────────────────▼─────────────────────────────────┐
│  App 包内的预编译运行时                                        │
│  OpenJDK · 打补丁的 LWJGL · Caciocavallo · GL4ES/ANGLE/MoltenVK│
│  → net.kdt.pojavlaunch.PojavLauncher → Minecraft              │
└─────────────────────────────────────────────────────────────┘
```

## 为什么必须调用 `JLI_Launch`

iOS 上没有"运行 java 命令"这回事。可行的路径只有一条：把为 `arm64-apple-ios`
编译的 `libjli.dylib` 用 `dlopen` 加载进来，取出 `JLI_Launch` 符号，在**同一个进程里**
调用它，把 JVM 跑起来。这正是 `java` 可执行文件内部做的事。

```objc
void *libjli = dlopen(".../lib/libjli.dylib", RTLD_NOW | RTLD_GLOBAL);
JLI_Launch_t *launch = (JLI_Launch_t *)dlsym(libjli, "JLI_Launch");
int result = launch(argc, argv, 0, NULL, 0, NULL,
                    "1.8.0-internal", "1.8", "java", "openjdk",
                    JNI_FALSE, JNI_TRUE, JNI_FALSE, JNI_TRUE);
```

函数签名在 JDK 8 到 JDK 25 之间**完全没有变化**（对照 `jdk8u/jdk/src/share/bin/java.h`
与 `jdk17u/src/java.base/share/native/libjli/java.h`），所以不需要按版本分支。

调用会阻塞到游戏退出。桥接层把它放在一条独立线程上，并导出
`HACK_IGNORE_START_ON_FIRST_THREAD=1`，让 JVM 允许从非线程 0 启动 —— 因为 iOS 上
主线程归 UIKit 所有。

## 关键设计决策

### iOS 在规则引擎里报告为 `osx`

Mojang 的版本元数据用 `rules` 决定哪些库和参数适用：

```json
{ "rules": [{ "action": "allow", "os": { "name": "osx" } }],
  "value": ["-XstartOnFirstThread"] }
```

`-XstartOnFirstThread` 是 **Darwin 内核的硬性要求**：GLFW 只有在进程的第一个线程上
才能驱动 run loop 创建窗口。iOS 也是 Darwin，同样需要它。如果
`RuleEnvironment.current` 报告 `os_name = "ios"`，这一条会被静默丢弃，游戏启动后
卡在黑屏且没有任何报错 —— 极难排查。

所以 `RuleEnvironment.current` 返回 `"osx"`。代价是会连带启用少数 macOS 专属的库
（`java-objc-bridge` 等），这些由 `Library.isDesktopNativeBundle` 单独过滤掉。

### 类路径顺序就是覆盖顺序

```
1. <App>/libs/*            打补丁的 LWJGL 与 Caciocavallo（必须放最前）
2. 元数据里的库（去掉 LWJGL）  Minecraft 自己的依赖
3. <版本>.jar               游戏本体
```

第 1 项必须在最前。原版 LWJGL 的 jar 也在第 2 项附近，如果它先被加载，第一次
`GLFW.glfwInit()` 就会抛 `UnsatisfiedLinkError` —— 因为原版 LWJGL 里是
`liblwjgl.dylib`（macOS 桌面版），而不是 iOS 版。

### `default-user-jvm` 必须忽略

新版元数据带一个建议的默认堆设置：

```json
"default-user-jvm": [{
  "value": ["-Xms2G", "-Xmx4G", "-XX:+UseCompactObjectHeaders", "-XX:+AlwaysPreTouch"]
}]
```

这是给桌面启动器在用户没设置时用的建议值。在手机上照抄会被 iOS 直接杀掉进程
（jetsam），表现成"点启动就闪退"。所以 `JVMArguments.build` 完全跳过这个字段，
堆大小由「设置 → 内存」决定。

### 占位符必须有值，否则整条参数丢弃

`substitute` 在替换后如果还残留 `${...}` 就返回 `nil`，调用方用 `compactMap` 过滤。
这样一条无法满足的参数（比如 `--quickPlayPath ${quickPlayPath}`）会被整条移除，
而不是把字面量 `${quickPlayPath}` 交给游戏 —— 后者会让游戏启动参数解析失败。

### 两个 JVM 参数必须由启动器提供，而不是照抄元数据

| 参数 | 元数据里的值 | 启动器提供的值 | 原因 |
|---|---|---|---|
| `-Djava.library.path` | `${natives_directory}`（桌面 natives 布局） | `<App>/Frameworks` | iOS 的 `.dylib` 在 App 包里，不在版本目录下 |
| `-cp` | `${classpath}`（含桌面 LWJGL） | 见上 | 必须保证补丁版 LWJGL 优先 |

`JVMArguments.shouldDropVanillaArgument` 负责把这些从元数据参数里剔除，
避免同一参数出现两次（JVM 取最后一次，会覆盖掉正确的值）。

## 启动序列

`LaunchPipeline.run` 的顺序，以及每一步失败时的表现：

| # | 步骤 | 失败表现 |
|---|---|---|
| 1 | 探测 JIT 权限 | 警告但不中止（调试器可能在之后附加） |
| 2 | 校验运行时库是否齐全 | 「缺少 N 个库文件」，提示重跑 bootstrap |
| 3 | 刷新账号令牌 | 「登录失败（获取 XSTS 令牌）：…」 |
| 4 | 读取并合并版本元数据 | 「版本元数据无法解析：缺少字段 …」 |
| 5 | 按所需 Java 版本选运行时 | 「找不到 Java 17 运行时」 |
| 6 | 取资源索引 | 下载失败 HTTP 码 |
| 7 | 算差集并下载 | 逐个文件的进度，SHA-1 不符会重下 |
| 8 | 重建 natives 目录 | — |
| 9 | 链接 `libawt_xawt.dylib` | 警告；AWT 相关界面不可用 |
| 10 | 组装并调用 `JLI_Launch` | 负返回码：-1 载入 libjli 失败，-2 缺符号，-3 参数为空 |
| 11 | 捕获 stdout/stderr | — |
| 12 | 非零退出时收集崩溃报告 | 日志里给出 `crash-reports/` 下文件名 |

第 8 步每次启动都清空 natives 目录。看起来浪费，但残留的旧 `.dylib` 是
"昨天好好的今天崩了"这类问题最常见的来源。

## 数据存储位置

```
App 包内（只读，随 App 一起签名）
├── java_runtimes/
│   ├── java-8-openjdk/            Java 8，用于 1.16.5 及更早
│   └── java-17-openjdk/           Java 17，用于 1.17 – 1.20.4
├── Frameworks/                    图形库（GL4ES / ANGLE / MoltenVK / OpenAL）
├── libs/                          打补丁的 LWJGL、Java 侧启动器、Caciocavallo
└── log4j-rce-patch-*.xml

Documents/CraftLauncher/            ← POJAV_HOME，也是 -Duser.home
├── instances/<名字>/               每个实例一个游戏目录
│   ├── mods/  mods.disabled/       开关 Mod 靠移动目录
│   ├── saves/  resourcepacks/  shaderpacks/  config/
├── versions/<id>/                  元数据 + client.jar
├── libraries/                      Maven 布局，多版本共用
├── assets/objects/<ab>/<hash>      内容寻址，多版本共用
├── runtimes/<tag>/                 用户导入的第三方 JDK（可选）
├── natives/<实例>/                 每次启动重建
├── logs/console.log
├── accounts.json                   令牌在钥匙串，不在这里
└── crash-reports/
```

在「文件」App 里可以看到 Documents 下的整个目录（`UIFileSharingEnabled` +
`LSSupportsOpeningDocumentsInPlace`），所以用户能直接拖 jar 进去装 Mod。

### 为什么运行时放在 App 包里，而不是解压出来

最初的实现把 JRE 打进 App 后在首次启动时解压到 Documents。**那个做法是错的**，两个原因：

1. **签名。** App 包内的文件由主 App 的签名覆盖，证书类重签工具（全能签等）会自动处理。
   运行期解压到 Documents 的文件**没有签名**，iOS 会拒绝 `dlopen`。要让它工作，
   就得在设备上实现 ad-hoc Mach-O 签名 —— 而那个东西没有真机根本测不了，
   一旦写错就是启动即崩，且现场无法诊断。
2. **根本不需要。** 上游的运行时是精简构建，**没有 `bin/` 目录**。
   它本来就不是靠执行 `bin/java` 启动的，而是 `dlopen("libjli.dylib")` 后调 `JLI_Launch`。

代价是体积：约 266 MB 的运行时，最终 `.ipa` 在 300 MB 上下。

## 支持的 Minecraft 版本范围

| 运行时 | 对应版本 |
|---|---|
| Java 8 | 1.16.5 及更早 |
| Java 17 | 1.17 – 1.20.4 |

**1.20.5 及更新的版本需要 Java 21，目前无法支持。** iOS 上没有可公开获取的
Java 21 构建：上游 CI 会在 `android-openjdk-build-multiarch` 的 `buildjre17-21`
分支产出 `jre21-ios-aarch64`，但该仓库的全部产物都已过期，最新的 PojavLauncher
开发构建也处于 cancelled 状态。

启动器遇到超出范围的版本会**明确拒绝并说明原因**，而不是用旧 JDK 硬启动 ——
后者会在 JVM 内部抛出 class 版本错误，用户完全无法从中推断问题。

详见 [JAVA-RUNTIMES.md](JAVA-RUNTIMES.md)。

## 上游依赖与许可

运行时二进制来自以下项目，均为 GPL-3.0 或兼容许可：

| 项目 | 作用 | 许可 |
|---|---|---|
| [PojavLauncher_iOS](https://github.com/PojavLauncherTeam/PojavLauncher_iOS) | iOS 运行时整体、`PojavLauncher` Java 入口类 | GPL-3.0 |
| [Boardwalk](https://github.com/PojavLauncherTeam/Boardwalk) | LWJGL 的 iOS 移植 | GPL-3.0 |
| [Caciocavallo](https://github.com/caciocavallo-silano) | 不依赖 X11 的 AWT | GPL-2.0 |
| [GL4ES](https://github.com/ptitSeb/gl4es) | OpenGL → OpenGL ES | MIT |
| [ANGLE](https://github.com/google/angle) | OpenGL ES → Metal | BSD-3-Clause |
| [MoltenVK](https://github.com/KhronosGroup/MoltenVK) | Vulkan → Metal | Apache-2.0 |

本工程**不包含**任何 Minecraft 游戏文件，也不包含 Mojang 的美术资源。
游戏本体、资源文件、依赖库全部在用户设备上从 Mojang 官方服务器下载。
