# 待办与已知问题

这份清单来自对 PojavLauncher 真实 IPA 的结构解剖（v2.2，103.16 MB，SHA-256
`1be34026…e4f02b`），以及对照官方 issue、工作流文件和 OpenJDK 源码的核实。

**标记说明**：`[P0]` 不修就跑不起来 ｜ `[P1]` 能跑但会误导或卡住用户 ｜ `[P2]` 体验问题 ｜ `[P3]` 清理
**状态**：`[ ]` 待办 ｜ `[x]` 已完成

---

## 一、运行时装载 —— `[P0]` ✅ 已完成

原始设计的核心假设是错的。实测结果（对照真实 IPA）：

| 原假设 | 实际情况 |
|---|---|
| JRE 是 `Frameworks/` 下的 `.zip` | 是 `java_runtimes/` 下的**完整目录**：`java-8-openjdk/`、`java-17-openjdk/` |
| 需要按大小猜哪个 zip 是哪个 JDK | 目录名固定，直接读 `release` 文件即可 |
| JRE 有 `bin/java` | **没有 `bin/` 目录**，是精简运行时，只有 `lib/` |
| 需要给 `libawt_xawt.dylib` 做符号链接 | **JRE 里本来就有**，链接逻辑多余 |
| `libs/` 里有完整 LWJGL 全家桶 | 只有 8 个 jar，其中 `lwjgl3-minecraft.jar` 是整合版 |
| 只有 `libs_caciocavallo` | 还有 **`libs_caciocavallo17`** |

- [x] **[P0] 重写 `Scripts/bootstrap-runtime.sh`**
      现在从 `java_runtimes/`、`Frameworks/`、`libs/` + `libs_caciocavallo/` +
      `libs_caciocavallo17/` 提取，并带上两个 log4j 补丁。
      **已在 Windows 上实际跑通**（用本地 IPA），产出 266 MB。

- [x] **[P0] `RuntimeTag` 收敛到两个桶**
      标签改为上游真实的目录名 `java-8-openjdk` / `java-17-openjdk`；
      `minimumTag(forMajor:)` 改为返回 `String?`，Java 21+ 返回 nil 而不是降级。

- [x] **[P0] `JVMArguments` 的 JRE 路径改为包内**
      `argv[0]` 不再指向不存在的 `bin/java`，改为传运行时根目录
      （`JLI_Launch` 只用它定位 `libjli` 和 `libjvm`）。

- [x] **[P0] `JavaRuntimeManager` 改为从包内发现运行时**
      删掉全部解压/安装逻辑。运行时随 App 一起签名，设备上不做任何写入。

- [x] **[P0] 删除 `linkAWTStub()` 和多余的 `-javaagent`**
      AWT 库改为「检查存在」；`patchjna_agent.jar` 本来就没写进参数表，已确认。

- [x] **[P0] 修复一个真跑脚本才发现的错误**
      `JavaRuntime.libawtXawt` 写成了 `lib/awt_xawt.dylib`，
      真实文件名是 **`lib/libawt_xawt.dylib`**（带 lib 前缀）。
      静态校验器抓不到这个 —— 它检查的是我自己的假设。

---

## 二、日志与崩溃排查（P1）✅ 完成

- [x] **[P1] 接入 `log4j-rce-patch-1.7.xml` / `-1.12.xml`**
      `JVMArguments.log4jConfiguration` 按 `version.logging.client.file.id` 选择：
      `client-1.12.xml` → patch-1.12，`client-1.7.xml` → patch-1.7，
      其余用下载到游戏目录的原文件。文件缺失时退回内置配置而不是启动失败。

- [x] **[P1] 两个补丁文件打进 App 包**
      `project.yml`、bootstrap 脚本、CI 都覆盖了。

- [x] **[P1] `ResourceDownloader` 下载 log4j 配置**
      `DownloadPlan.log4jConfig` 新增；`shouldDownloadLog4jConfig` 明确跳过那两个
      被补丁替换掉的 id —— 否则会把补丁覆盖回有漏洞的原文件。

- [x] **[P1] 顺手修掉一个真实的漏下载**
      `LaunchPipeline` 原来是按类别手写三批下载（库 / 客户端 / 资源），
      往 `DownloadPlan` 加第四类时**被静默跳过**。改成一次 `execute()` 走整个 plan。
      校验器新增了「plan 里每个下载类别都必须在 execute 里出现」的断言。

- [ ] **[P2] 检查是否还需要 `LIBGL_ES` / `LIBGL_GL` 环境变量**
      上游导出了这两个，本项目没设。需要真机实测是否影响 GL4ES 行为。

---

## 三、Java 版本覆盖（P1 —— 已确认做不到「全版本」）

调研结论：

| 来源 | Java 8 | Java 17 | Java 21 | Java 25 |
|---|---|---|---|---|
| 正式版 v2.2 的 `java_runtimes/` | ✅ | ✅ | ❌ | ❌ |
| 开发构建（Actions） | ✅ | ✅ | ✅ 曾经有 | ❌ 从未见过 |
| `android-openjdk-build-multiarch` 的 `buildjre17-21` 分支产物 | — | ✅ | ✅ 曾经有 | ❌ |
| **现在可下载的** | ✅ | ✅ | **❌ 全过期** | ❌ |

- [x] **[P1] 确认 Java 21 的 iOS 构建确实存在过** —— `development.yml` 里有 `Get JRE21` 步骤，
      产物名 `jre21-ios-aarch64`，取自 `PojavLauncherTeam/android-openjdk-build-multiarch` 的
      `buildjre17-21` 分支。维护者在 [issue #705](https://github.com/PojavLauncherTeam/PojavLauncher_iOS/issues/705) 确认开发构建含 Java 21。

- [x] **[P1] 写 `docs/JAVA-RUNTIMES.md`**
      已核实并写全：为什么做不到全版本；Java 21 的确切来源
      （`android-openjdk-build-multiarch` 的 `buildjre17-21` 分支，产物名
      `jre21-ios-aarch64`）；该仓库**已归档**、产物全部过期、最新开发构建 #1236 是
      cancelled；以及完整的自建步骤和接进来的注意事项。

- [x] **[P1] 探明 Java 21 自建的可行性 —— 找到了根因，并做成了可执行方案**

  **根因（这是我这次最有价值的发现）**：上游的 iOS 构建跑在**自托管的 MacStadium runner** 上，
  而那台机器早就不存在了：

  ```yaml
  build_iosport:
    strategy: { matrix: { version: [17, 21] } }   # Java 21 的构建任务确实存在
    runs-on: MacStadium                            # ← 自托管，不是 GitHub 托管
    continue-on-error: true                        # ← 失败也不让 workflow 变红
  ```

  `continue-on-error: true` 意味着它消失之后**没人注意到**，直到所有产物过期。
  这就解释了「最新开发构建 #1236 是 cancelled」和「artifacts 接口返回 0 条」。

  **做成了什么**：`.github/workflows/build-ios-jre21.yml` —— 同一个构建配方，
  换成 GitHub 托管的 `macos-14`，去掉 `continue-on-error`，加 `if-no-files-found: error`
  让空产物直接失败。照抄进 fork、开 Actions、点运行即可。

  文档 `docs/JAVA-RUNTIMES.md` 里有完整的七步操作说明和「加 Java 21 桶」的确切 diff。

- [ ] **[P3] 若拿到 Java 21，`RuntimeTag` 加回 `java21` 桶**
      确切 diff 已写在 `docs/JAVA-RUNTIMES.md`。关键：**不要动 `minimumTag(forMajor:)`** ——
      它已经是「取最小足够版本」的写法，加桶后自动正确；
      改回阈值链会把 1.17–1.20.4 错配到 Java 21，而那些版本在新 JDK 上会崩。

---

## 四、签名与 JIT（P0/P1）

- [x] **[P0] entitlements 收敛到最小集**
      原来内联声明了 `com.apple.private.memorystatus`、`extended-virtual-addressing`
      和两个 macOS 硬化运行时的键 —— 这些会让证书签名直接失败。
      现在只在 `Resources/CraftLauncher.entitlements` 里声明
      `get-task-allow` + `disable-library-validation`，私有权限移到注释里。

- [x] **[P0] 加入权限探针诊断**
      `RuntimeBridge.hasGetTaskAllow()` / `hasLibraryValidationDisabled()` /
      `hasExtendedMemoryEntitlement()`，读的是 `SecTaskCopyValueForEntitlement`
      拿到的**实际生效权限**。设置页「运行环境」会显示，用来区分
      「签名的证书类型不对」和「还没激活 JIT」。

- [ ] **[P1] JIT 方案文档更新为 StikDebug**
      `docs/JIT.md` 现在主推 SideJITServer（需要常开电脑）。应改为主推
      [StikDebug](https://github.com/StikDebug/StikDebug)：设备本地、支持 iOS 17.4–26.x、
      初始配对后不需要电脑。配对文件可用
      [iloader](https://github.com/nab138/iloader/releases/latest/download/iloader-windows-x64.exe)
      **在 Windows 上**生成。`Scripts/attach-jit.sh` 降级为备用方案。

- [ ] **[P1] 验证 `全能签` 是否重签内嵌二进制**
      App 包里会有 ~88 个 Mach-O（`Frameworks/` 的 dylib + `java_runtimes/` 的库），
      全部已是 arm64 + 已签名。**如果重签工具不逐个重签这些嵌套二进制**，
      iOS 会在启动时因签名团队不匹配而拒绝 —— 这是除 JIT 之外最可能导致「装了打不开」的原因。
      用「设置 → 运行环境」的「加载外部动态库」那一行判断。

- [ ] **[P2] 记录一个未验证的风险**
      `java_runtimes/` 里的 dylib 若是 PojavLauncher 团队签名，重签后主 App 与它们签名团队不一致。
      有 `disable-library-validation` 应该能绕过，但**没有真机验证过**。

---

## 五、下载与构建（P1）

- [x] **[P1] GitHub Actions 工作流**
      `.github/workflows/build.yml`：macOS runner、跑 `verify.py`、缓存运行时、
      `xcodebuild CODE_SIGNING_ALLOWED=NO`、打包无签名 `.ipa`、上传产物。
      出包约 300–400 MB（含两个 JRE）。

- [x] **[P1] 工作流适配新的 bootstrap 脚本**
      缓存路径改为 `Runtime/java_runtimes`、`Runtime/libs`、`Runtime/Frameworks` 和两个
      log4j 补丁；报告步骤改为逐个运行时检查 `libjli` + `libjvm` 是否都在。
      构建后的 bundle 校验改成 hard failure：缺目录或 JDK 目录结构被拍平都会直接失败，
      而不是产出一个装上去打不开的包。

- [x] **[P1] 支持离线使用本地 IPA**
      `./Scripts/bootstrap-runtime.sh --ipa <路径>`。文件大小会对着官方值校验
      （`108175347` 字节），不匹配就警告 —— 截断的文件会让解包中途失败。

- [ ] **[P2] `.bootstrap/` 里的临时工具**
      `fetch-resume.mjs`（断点续传下载）、`proxy-fetch.mjs`（代理探测）、
      `inspect-macho.mjs`（Mach-O 分析）是有用的调试工具，现在抛在 `.bootstrap/` 里。
      `.gitignore` 已覆盖，所以不会进仓库。要不要整理进 `Scripts/tools/` 待定。

---

## 六、一致性与清理（P2/P3）

- [x] **[P2] `verify.py` 增加「对着上游真实数据」的断言**
      **这次的教训**：校验器检查「我的 Swift 标签」和「我的 shell 脚本」是否一致 ——
      两边都是我写的，所以**一致也能同时错**。`jre21` 那个桶就是这么混过去的。
      现在新增了「运行时标签 / 脚本 / 上游 IPA 三方一致性」一节，
      解包出来的上游 IPA 是第三个真相来源，并逐个检查 `libjli` / `libjvm` /
      `libawt_xawt.dylib` 真实存在 —— **后者立刻抓出了一个我写错的文件名**。

- [x] **[P2] `verify.py` 增加「下载管线完整性」一节**
      从 `DownloadPlan` 源码里解析出所有下载类别，断言每一个都在 `execute()` 里出现。
      这正是导致 log4j 配置被静默跳过的那个 bug 类型。

- [x] **[P2] `LaunchPipeline.captureCrashReport` 的 `gameDir`**
      复查确认它在用（派生 `reports` 路径），不是死代码。

- [x] **[P2] 权限探测重复实现**
      `LaunchPipeline` 里自己写了一份 `SecTaskCopyValueForEntitlement`，和桥接层重复。
      已改为调用 `RuntimeLauncher.entitlements.extendedMemory`，
      并加了「探测只有一处实现」的断言。

- [x] **[P2] `LaunchStage` 的死 case**
      统一下载后 `downloadingAssets` / `downloadingClient` 不再被使用，
      三个 case 合并为一个 `.downloading(done:total:)`。

- [ ] **[P3] `ZipExtractor` 是否还需要**
      运行时不再解压之后，它只剩「导入第三方 JDK」一个调用点。
      保留（功能仍然有用），但如果要精简可以考虑移除。

- [x] **[P3] `docs/ARCHITECTURE.md` 更新**
      文件布局、运行时说明、「为什么放在 App 包里」、版本支持范围都已按实测重写。

- [x] **[P3] `README.md` 的运行时章节**
      已删掉「四个桶：Java 8/17/21/25」，改为实际的 Java 8 / 17，并指向
      `docs/JAVA-RUNTIMES.md`。

---

## 剩余未完成项

做完三轮之后，清单上还剩这些 —— 全部是**需要真机或需要你参与**的：

| 项 | 为什么还没做 |
|---|---|
| **编译出 `.ipa`** | 需要推仓库跑 Actions（或借一台 Mac）。**这是唯一剩下的关卡** |
| 全能签是否重签内嵌二进制 | 需要你在设备上装一次，看「设置 → 运行环境」的「加载外部动态库」 |
| 重签后签名团队不一致的风险 | 同上；有 `disable-library-validation` 应该能过，但没验证过 |
| `LIBGL_ES` / `LIBGL_GL` 环境变量 | 需要真机实测 GL4ES 行为 |
| Java 21 运行时 | 方案已就绪（见上），需要在 macOS 上跑 1–3 小时的 CI |

## 校验器怎么用

```bash
python3 Scripts/verify.py           # 222 项静态断言，需要网络
python3 Scripts/verify.py --offline  # 跳过联网检查
python3 Scripts/verify.py -v         # 列出每一项

python3 Scripts/test_verify.py      # 49 个单元测试，测校验器自身
```

两个都接进了 CI，在编译前跑 —— 几秒钟就能挡掉一类要十几分钟才发现的问题。

### 为什么校验器自己也需要测试

**因为它在写的过程中产出了四次错误结果**，每一次都是它「通过」了一件实际错的事：

| 错误 | 后果 |
|---|---|
| 断言写的是「运行时桶必须提供 Java 21+」 | 那是 Java 21 支持被有意移除**之前**的设计，它对着过时假设通过了 |
| 调用点正则匹配到了 `func name(` 声明本身 | 报出几十条幻影不匹配 |
| 同一个检查没考虑默认参数值 | 合法的 `manifest()` 调用被当成错误 |
| 一条断言结尾是 `or True` | 永远不可能失败 |

这四条现在都是 `test_verify.py` 里的测试用例。

### 断言类别

| 类别 | 抓什么 |
|---|---|
| 规则引擎 | Mojang `rules` 语义（后匹配者胜、features、arch） |
| `arguments` 展开 | 字符串与规则对象混排的解析 |
| 占位符替换 | 模板键与已知占位符集合是否自洽 |
| Java 版本映射 | 是否「向上取最小足够」，绝不降级 |
| **运行时三方一致性** | Swift 标签 / bootstrap 脚本 / **解包出来的上游 IPA** |
| Mojang 真实数据对拍 | 抓线上最新版本的 JSON，跑一遍规则与参数组装 |
| UUID | `OfflinePlayer:` 派生是否与 Java 逐位一致 |
| JVM 命令行结构 | 必需参数、模块导出、类路径顺序 |
| Log4Shell 一致性 | 补丁文件与下载器的 id 列表必须完全相同 |
| 下载管线完整性 | `DownloadPlan` 每个下载类别都必须在 `execute()` 里出现 |
| entitlements | 不含 Apple 保留权限（否则证书签名失败） |
| 必需的 import | UIKit / SafariServices / CryptoKit 等 |
| 跨文件调用签名 | 首个参数标签必须匹配某个声明的重载 |
| CI 工作流 | 不引用已删除的设计、bundle 校验是硬失败、保留期合理 |
| 脚本换行符 | `.sh` 必须纯 LF，否则 CI 上无法执行 |

**它的定位要说清楚：这是启发式检查，不是编译器。** 它证明不了一定能编译，
但能抓住跨文件不一致、重命名遗漏、以及「三方自洽但其实全都错」这类问题 ——
`jre21` 那个桶就是这么混过去的。

---

## 附：已确认的运行时清单（供实现参考）

```
java_runtimes/java-8-openjdk/          release: JAVA_VERSION="1.8.0"  OS_ARCH="aarch64"
  lib/jli/libjli.dylib                 114,816
  lib/server/libjvm.dylib           13,075,872
  lib/rt.jar                        66,378,173
  lib/awt_xawt.dylib                    58,832   ← 已存在，不需要符号链接
  （无 bin/ 目录）

java_runtimes/java-17-openjdk/         release: JAVA_VERSION="17.0.8"  OS_ARCH="aarch64"
  lib/libjli.dylib                      95,472   ← 注意：不在 lib/jli/ 下
  lib/server/libjvm.dylib           16,703,904
  lib/modules                       80,866,327
  lib/awt_xawt.dylib                    58,832
  （无 bin/ 目录）

Frameworks/  33 个文件，关键项：
  libOSMesa.8.dylib                 15,847,072   ← ANGLE→Metal 后端
  MetalANGLE.framework/MetalANGLE   11,778,176
  libshaderc.dylib                   9,682,496
  libMoltenVK.dylib                  6,961,136
  libgl4es_114.dylib                 5,905,424   ← GL4ES 后端
  libopenal.dylib                    4,165,520
  liblwjgl.dylib / liblwjgl_opengl.dylib / liblwjgl_stb.dylib / liblwjgl_vma.dylib / liblwjgl_tinyfd.dylib
  libjnidispatch.dylib                 160,976
  libtinygl4angle.dylib                 60,384
  libglapi.0.dylib                     515,648
  libawt_xawt.dylib                     58,832
  libOSMesaOverride.dylib               51,072
  （另有 Alderis / AltKit / CAltKit 三个 framework 和 libAFNetworking.dylib，属于启动器 UI，本项目不需要）

libs/  8 个 jar（launcher.jar 是 Java 侧启动器，必须保留）
libs_caciocavallo/     Java 8 用
libs_caciocavallo17/   Java 17 用
```

全部 88 个 Mach-O 二进制：**arm64、全部带 LC_CODE_SIGNATURE**。
