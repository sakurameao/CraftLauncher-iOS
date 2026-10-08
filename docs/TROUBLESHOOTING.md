# 排查手册

先做两件事：**看「设置 → 运行环境」**，再**看「控制台」**。绝大多数问题在这两处
已经有明确答案，下面的条目帮你读懂它们。

---

## 启动前的检查清单

在报告任何问题之前，请确认这几项：

1. 「设置 → 运行环境」的 **JIT 权限**是「已启用」
2. 「设置 → 运行环境」的 **运行时库**是「完整」
3. 「设置 → Java 运行时」里至少有一个运行时，且能看出 Java 版本号
4. 已登录账号，并且主页的**游戏版本**是「已安装」状态
5. 剩余存储空间大于 2 GB

**用证书工具（全能签这类）侧载的话，额外看一项：**

「设置 → 运行环境」里的 **调试器附加许可**。

- 显示**已授予** → 你还能通过 SideJITServer 附加调试器来开 JIT
- 显示**未授予** → 证书类型不对（多半是企业证书），**没有任何办法**给这个
  App 开 JIT。换个人开发者证书重新签名

这一项读的是签名实际生效的权限，不是源码里声明的 —— 签名工具剥离了什么，
这里就显示什么。详见 [SIGNING.md](SIGNING.md)。

---

## 症状：点启动后立刻回到启动器，没有报错

**最可能：JIT 没开。**

看「设置 → 运行环境」。如果是「未启用」，JVM 会在几十毫秒内退出。控制台里通常能看到：

```
Error occurred during initialization of VM
```

或者干脆什么都没有 —— 因为 JVM 在接管日志之前就死了。

→ 按 [JIT.md](JIT.md) 开启 JIT。

**次可能：内存分太多，进程被系统杀掉。**

iOS 的 jetsam 机制会在内存超限时直接杀进程，不给任何机会写日志，所以看起来像闪退。
把「设置 → 内存」改成自动，或者手动降到 2048 MB 以下再试。

---

## 症状：黑屏，没有报错，进程还在

**最可能：`-XstartOnFirstThread` 没生效，GLFW 卡在等 run loop。**

在控制台里搜 `-XstartOnFirstThread`：

- **搜不到** → 版本元数据的 `osx` 规则没有被应用。这是 `RuleEnvironment.osName`
  被改成 `"ios"` 了，见 [ARCHITECTURE.md](ARCHITECTURE.md) 里那一节。改回 `"osx"`。
- **搜得到** → 问题在渲染后端。见下一条。

**次可能：图形后端选错了。**

1.20.2 及以后要求 OpenGL 核心模式，GL4ES 提供不了，必须用 ANGLE。
到「设置 → 图形 → 图形后端」改成「ANGLE → Metal」，重启游戏。

---

## 症状：`UnsatisfiedLinkError` 或 `no lwjgl in java.library.path`

运行时库没进 App 包。

1. 在工程根目录跑 `./Scripts/bootstrap-runtime.sh`
2. 跑 `./Scripts/generate-project.sh` 重新生成工程
3. 在 Xcode 里 **Product → Clean Build Folder**，重新构建

`Runtime/Frameworks` 和 `Runtime/libs` 都应该是非空的。检查一下：

```bash
ls Runtime/Frameworks/*.dylib | wc -l    # 应该是几十个
ls Runtime/libs/*.jar | wc -l            # 应该是十几个
```

---

## 症状：`找不到 libjli.dylib`

App 包里的运行时文件不完整。

**先看「设置 → 运行环境」的「运行时库」那一行** —— 它会指出具体缺哪个文件。

**在设备上没法修** —— 运行时现在直接放在 App 包里（随 App 一起签名，因此是只读的），
不像早期版本那样解压到 Documents。所以：

1. 在电脑上重跑 `./Scripts/bootstrap-runtime.sh`
2. 重新构建并重新安装 App

**检查提取结果**：`Runtime/java_runtimes/` 下应该有两个目录，各含关键的库：

```
Runtime/java_runtimes/java-8-openjdk/lib/jli/libjli.dylib        ← 注意 jli 子目录
Runtime/java_runtimes/java-8-openjdk/lib/server/libjvm.dylib
Runtime/java_runtimes/java-17-openjdk/lib/libjli.dylib           ← Java 17 直接在 lib/ 下
Runtime/java_runtimes/java-17-openjdk/lib/server/libjvm.dylib
```

两个目录加起来约 204 MB。明显偏小说明提取不完整。

---

## 症状：`找不到 Java N 运行时` / `这个版本需要 Java 21`

**这不是故障，是已知的硬上限。**

启动器内置两个运行时：

| 运行时 | 对应游戏版本 |
|---|---|
| Java 8 | 1.16.5 及更早 |
| Java 17 | 1.17 – 1.20.4 |

**1.20.5 及更新的版本需要 Java 21，iOS 上没有可公开获取的构建。**
这是上游产物缺失，不是配置问题 —— 你去「设置」里也装不到。

完整的证据链和自建步骤见 [JAVA-RUNTIMES.md](JAVA-RUNTIMES.md)。

**别做的事**：不要为了「试试看」把一个 macOS 或 Linux 的 JDK 导进去。
目标平台必须是 `arm64-apple-ios`，否则加载会失败，而且失败信息不会告诉你原因。

**注意选择逻辑**：启动器取「满足要求的最小版本」，而不是最新版本 ——
1.17–1.20.4 在 Java 21+ 上会崩，所以即使将来加了 Java 21，老版本也不会被影响。

---

## 症状：登录卡住 / `获取 XSTS 令牌` 失败

Xbox Live 的拒绝原因会显示成中文提示，最常见的是：

| 提示 | 原因 | 解决 |
|---|---|---|
| 这个账号没有 Xbox 档案 | 微软账号没建过 Xbox 档案 | 先去 xbox.com 登录一次 |
| 你需要先完成年龄验证 | 账号没有验证年龄 | 去 account.microsoft.com 补全 |
| 这是未成年账号 | 家庭组限制 | 让家庭组的成年人授权 |
| 你所在的地区不支持 | 区域限制 | 换网络环境 |

**反复失败**：地址栏里的授权码是一次性的，用过就失效。重新点「打开微软登录页面」
拿一个新的码。

---

## 症状：`NOT_FOUND`，以 Demo 模式启动

账号验证通过，但**没有 Minecraft: Java Edition 的拥有权**。这不是 bug ——
启动器如实反映账号状态。用拥有游戏的账号登录即可。

---

## 症状：Mod 装上了但游戏里看不到

按顺序排查：

1. **Mod 被禁用了？** 「Mod」页面里左边的方框应该是勾选状态。禁用的 Mod 会被移到
   `mods.disabled/`。

2. **加载器不匹配？** Mod 页面上会显示从 jar 里读出来的加载器标签。
   一个 Fabric Mod 装到 Forge 实例里不会生效，反过来也一样。

3. **游戏版本不匹配？** 大部分 Mod 只支持特定版本区间。看 Mod 页面上的版本标签。

4. **缺前置库？** 很多 Mod 要求 Fabric API 或别的库。
   这类错误会打在控制台里，典型的是：

   ```
   Caused by: net.fabricmc.loader.api.ModDependencyException
   ```

   搜 `Missing` 或 `requires` 能找到具体缺哪个。

5. **看控制台里有没有 `Loading X mods`** —— 如果数量是 0，说明 `mods/` 目录不对，
   确认当前实例是不是你以为的那个。

---

## 症状：整合包导入失败

| 报错 | 原因 |
|---|---|
| `CurseForge 整合包（只含 N 个项目编号，未内嵌文件）` | 这个包只带项目 id，下载链接需要 CurseForge API 密钥 |
| `无法识别整合包格式` | 既不是 `.mrpack`，也没有 `manifest.json` |

**整合包只带项目编号怎么办**：在电脑上用 CurseForge 客户端把它导出成带文件的压缩包
（导出时会内嵌全部 Mod），再传到手机上导入。或者优先选 Modrinth 上的 `.mrpack`，
它的清单里直接带下载地址。

---

## 症状：游戏崩溃，想要崩溃报告

启动器会把它收集到 `crash-reports/` 目录：

```
Documents/CraftLauncher/crash-reports/<实例名>-crash-<时间>.txt
```

在「文件」App 里可以找到并分享出来。控制台的完整输出在
`Documents/CraftLauncher/logs/console.log`，右上角菜单里也能直接导出。

---

## 症状：磁盘占用一直在涨

资源和依赖库是**所有版本共用**的，删掉版本不会清掉它们。

「设置 → 维护 → 清理未使用的资源文件」会扫描所有已安装版本实际引用的资源，
其余删除。存档和 Mod 不受影响。

---

## 症状：Xcode 构建报 `RuntimeBridge.h file not found`

桥接头文件的搜索路径没配对。

1. 确认 `project.yml` 里有 `SWIFT_OBJC_BRIDGING_HEADER` 和 `HEADER_SEARCH_PATHS`
2. 重新跑 `./Scripts/generate-project.sh`
3. 如果手动改过 `.xcodeproj`，改动会在重新生成时丢失 —— 请改 `project.yml`

---

## 还是不行？

导出控制台日志（控制台页面右上角 → 导出日志），连同以下信息一起提供：

- 设备型号和 iOS 版本
- 安装方式（TrollStore / SideStore / Xcode）
- 「设置 → 运行环境」的截图
- 出问题的游戏版本和 Mod 加载器
