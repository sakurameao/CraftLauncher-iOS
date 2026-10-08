# CraftLauncher for iOS

在 iPhone / iPad 上启动 **Minecraft: Java Edition** 的原生启动器。

SwiftUI 界面 + Objective-C++ JVM 桥接层。版本管理、微软账号登录、Mod 与整合包管理、
Java 运行时设置、实时控制台日志全部可用。

> **重要前提（请先读）**
> iOS 不允许应用在运行时生成并执行代码，而 Java 虚拟机必须靠 JIT 才能跑得动 Minecraft。
> 因此本启动器**必须**安装在一个允许 JIT 的环境里：TrollStore、越狱设备，
> 或用 AltStore / SideStore / SideJITServer 在启动时附加调试器。这不是本项目的缺陷，
> 而是 Apple 的安全策略 —— 所有 iOS 上的 Java 版启动器都受同一限制。
> 详见 [docs/JIT.md](docs/JIT.md)。

---

## 这个项目由两部分组成

理解这一点能省下几小时：

| 部分 | 做什么 | 在哪 |
|---|---|---|
| **Swift 启动器**（本项目主体） | 界面、下载版本与资源、登录账号、管理 Mod、组装 JVM 参数、拉起进程、抓日志 | `Sources/` |
| **iOS 版 Java 运行时**（预编译二进制） | 真正的 OpenJDK + 打补丁的 LWJGL + OpenGL→Metal 转译层 | `Runtime/`（脚本拉取，不入库） |

第二部分有几万个源文件（OpenJDK、Mesa、MoltenVK、ANGLE、GL4ES），必须在 macOS 上交叉编译，
不可能靠在 Windows 上敲代码产出。所以本项目**不重复造它**，而是通过 `JLI_Launch` 这个稳定接口
把它接进来 —— 这正是所有 iOS Java 启动器的做法。

`Scripts/bootstrap-runtime.sh` 会从上游公开发布拉取运行时并放进工程。

---

## 快速开始

### 1. 拉取 Java 运行时依赖

```bash
# 需要网络。解包是纯 zip 操作，所以 Windows / Linux 上也能跑
./Scripts/bootstrap-runtime.sh

# 国内直连 GitHub 很慢，可以手动下好 IPA 再指定
./Scripts/bootstrap-runtime.sh --ipa ~/Downloads/pojavlauncher.ipa
```

脚本从上游 PojavLauncher 的发行包里提取：

- **Java 运行时**（两个，都是完整目录树而非压缩包）：
  `java-8-openjdk`（Minecraft ≤ 1.16.5，Java 1.8.0）和
  `java-17-openjdk`（1.17 – 1.20.4，Java 17.0.8）
- **Frameworks**：`libgl4es_114`、ANGLE、`libMoltenVK`、`libOpenAL` 等图形库
  （会跳过上游启动器自己的 UI 框架，本项目不用）
- **libs**：打补丁的 LWJGL、Java 侧入口 `launcher.jar`、Caciocavallo
  （Java 8 与 Java 17 两套，包名不同）
- **log4j 安全补丁**：`log4j-rce-patch-1.7.xml` / `-1.12.xml`

提取结果约 **266 MB**，全部打进 App 包 —— 所以最终 `.ipa` 在 300 MB 上下。

> **1.20.5 及更新的版本无法启动**，它们需要 Java 21，而 iOS 上没有可公开获取的
> Java 21 构建。原因、证据和自建步骤见 [docs/JAVA-RUNTIMES.md](docs/JAVA-RUNTIMES.md)。

### 2. 生成 Xcode 工程

```bash
brew install xcodegen
./Scripts/generate-project.sh
open CraftLauncher.xcodeproj
```

### 3. 签名与安装

在 Xcode 里设置你的 Team，然后构建。要启用 JIT，用 SideStore / TrollStore 安装，
或构建 Debug 配置并用 `Scripts/attach-jit.sh` 附加调试器。

用**全能签**之类的证书工具侧载也可以 —— 但要知道签名给不了 JIT，
而且工程里的授权已经为了兼容这类工具收敛到最小集。详见 [docs/SIGNING.md](docs/SIGNING.md)。

### 4. 在 App 里

1. 「设置 → Java 运行时」确认 JDK 8 / 17 都被识别（首次启动会从 App 包内自动安装）
2. 「账号」登录微软账号，或建一个离线账号
3. 「版本」下载一个游戏版本
4. 回主页，点「启动」

---

## 已实现的功能

**版本管理与下载**
- 读取 Mojang 官方 `version_manifest_v2`，正式版/快照/远古版分类与搜索
- 完整实现 Mojang 的 `rules` 规则引擎（操作系统、CPU 架构、feature 开关）
- 并发下载库 / 资源索引 / 客户端，带 SHA-1 校验与断点续传
- 继承式版本（`inheritsFrom`）合并，Fabric / Forge / OptiFine 这类派生版本可直接用
- 资产索引（assets index）解包与对象下载，支持 `resources.download.minecraft.net` 分片

**账号**
- 微软账号完整 OAuth 链：`login.live.com` → Xbox Live → XSTS → `login_with_xbox` → `minecraft/profile`
- 刷新令牌存 Keychain（`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`）
- Xbox 错误码翻译（无 Xbox 账号 / 未成年 / 区域限制 / 需要验证）
- 离线账号；UUID 按 `OfflinePlayer:<name>` 派生
- 无游戏所有权时自动降级为 Demo 模式

**Mod 与整合包**
- 扫描 `mods/`，读取 `fabric.mod.json` / `quilt.mod.json` / `META-INF/mods.toml` 元数据
- 开关切换用 `.disabled` 后缀，不动文件内容
- 导入 `.zip` / `.mrpack` 整合包，解析 `modrinth.index.json` 与 `manifest.json`（CurseForge）
- 拖入 jar 导入

**Java 运行时**
- 两个运行时（Java 8 / 17）直接放在 App 包内，按游戏版本自动选择
- **取「满足要求的最小版本」而不是最新版本** —— 1.17–1.20.4 在 Java 21+ 上会崩，
  无脑用最新版会把能跑的环境变成崩溃
- 超出范围的版本（1.20.5+ 需要 Java 21）**明确拒绝并说明原因**，
  而不是用旧 JDK 硬启动后抛一个看不懂的 class 版本错误
- 内存自动分配（按设备物理内存比例，带 entitlement 感知）
- 自定义 JVM 参数与自定义环境变量（会被安全过滤：`-Xmx` 等由启动器接管）
- 支持导入第三方 JDK 压缩包

**启动与控制台**
- 严格复刻 iOS 上的 JVM 启动序列（详见 `Sources/Runtime/RuntimeBridge.mm`）
- 环境变量、Caciocavallo AWT 桥（Java 8 与 17 用两套包名）
- Log4Shell 补丁：1.7 / 1.12 用包内硬化配置，其余版本下载 Mojang 的原文件
- 实时日志（stdout/stderr 重定向到管道 + 文件）、分级着色、崩溃报告导出

---

## 目录结构

```
CraftLauncher-iOS/
├── project.yml                 XcodeGen 工程定义
├── Resources/
│   └── CraftLauncher.entitlements  签名授权（刻意保持最小集）
├── Scripts/
│   ├── bootstrap-runtime.sh    拉取 Java 运行时与 Frameworks
│   ├── generate-project.sh     生成 .xcodeproj
│   ├── attach-jit.sh           SideJITServer / pymobiledevice3 启用 JIT
│   └── verify.py               静态校验（参数逻辑 + 源码结构）
├── Sources/
│   ├── App/                    入口、全局状态、Tab 导航
│   ├── Core/                   路径、Keychain、日志总线、错误
│   ├── Models/                 版本 JSON / 账号 / 运行时 / 启动配置
│   ├── Services/               清单获取、下载器、启动管线
│   ├── Auth/                   微软 OAuth 与离线账号
│   ├── Mods/                   jar 元数据解析、整合包导入
│   ├── Runtime/                Objective-C++ JVM 桥接
│   └── UI/                     全部 SwiftUI 页面与设计系统
├── Runtime/                    bootstrap 拉取的二进制（.gitignore）
└── docs/
    ├── ARCHITECTURE.md         启动序列与设计说明
    ├── JIT.md                  JIT 各方案对比与操作步骤
    ├── SIGNING.md              用全能签等证书工具侧载
    └── TROUBLESHOOTING.md      常见崩溃与排查
```

---

## 校验

```bash
python3 Scripts/verify.py
```

不依赖 macOS，检查：启动参数组装逻辑（用真实 Mojang 规则数据跑等价实现）、
Swift 源码结构完整性、规则引擎真值表、模板占位符是否全部有对应值。

---

## 许可与致谢

本工程以 **GPL-3.0** 发布，因为它链接了 GPL-3.0 的 Java 运行时桥接层。

iOS 上的 Java 运行时、LWJGL 移植与 rendering 转译层来自这些项目，请一并遵守其许可：

- [PojavLauncher_iOS](https://github.com/PojavLauncherTeam/PojavLauncher_iOS) — iOS 运行时的来源，GPL-3.0
- [Boardwalk](https://github.com/PojavLauncherTeam/Boardwalk) — iOS 版 LWJGL 移植
- [Caciocavallo](https://github.com/caciocavallo-silano) — 无 X11 的 AWT 实现
- [GL4ES](https://github.com/ptitSeb/gl4es) / [ANGLE](https://github.com/google/angle) / [MoltenVK](https://github.com/KhronosGroup/MoltenVK) — 图形转译

Minecraft 是 Mojang Studios 的商标。本项目不包含、不分发任何 Minecraft 游戏文件，
游戏本体由官方服务器下载，使用时需遵守 [Minecraft EULA](https://www.minecraft.net/eula)。
