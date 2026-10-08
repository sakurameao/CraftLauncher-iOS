# 用全能签侧载

本文假设你用 Mac 上的 Xcode 构建出 `.ipa`，再用全能签签名安装到设备。

---

## 如果你是非越狱 iPad + 较新 iPadOS（例如 26.x）

这是约束最紧的一种情况，路线只有一条。先说清楚为什么：

| 方案 | 为什么不行 / 行 |
|---|---|
| TrollStore | ❌ 只支持 iOS ≤16.6.1 和 17.0，26.x 远超范围 |
| 越狱 | ❌ 越狱工具通常滞后新系统很多，26.x 基本没有 |
| 全能签注入 `dynamic-codesigning` | ❌ 超出证书签发范围，任何签名工具都做不到 |
| **签名安装 + SideJITServer 附加调试器** | ✅ **唯一可行** |

所以成败取决于**一件事**：全能签签出来的 App 里，`get-task-allow` 还在不在。

判断依据是证书类型：

| 证书类型 | 描述文件含 `get-task-allow`？ | 结果 |
|---|---|---|
| **个人开发者证书 / 免费证书** | ✅ 含 | 全能签会保留，SideJITServer 能附加 → **可行** |
| **企业证书 / 分发证书** | ❌ 不含 | 全能签无法注入 → 被丢掉 → **附加会被拒，走不通** |

**不用猜 —— 装好后一眼就能看出来。** 打开启动器 →「设置 → 运行环境」，
看「调试器附加许可」那一行：

- 显示**已授予** → 你有救，按下面第 4 步走 SideJITServer
- 显示**未授予** → 换个人开发者证书重新签名，否则这条路走不通

这一行读的是签名**实际生效**的权限，不是源码里声明的。全能签剥掉了什么，这里就显示什么。

### 还需要准备什么

| 需要 | 用途 | 能不能省 |
|---|---|---|
| 一台 **Mac** | 跑 `bootstrap-runtime.sh` 拉取 Java 运行时、用 Xcode 出 `.ipa` | ❌ 省不了，运行时的编译和打包只有 macOS 能做 |
| 一台**常开的电脑 / 树莓派 / 旧手机** | 跑 SideJITServer | ❌ 省不了，但你不需要它一直开着 —— 只在开 JIT 那几秒需要 |
| 手机和上面那台设备在**同一个 Wi-Fi** | 调试器连接 | — |

SideJITServer 跑在局域网里任意一台设备上都行，不必是 Mac —— Windows PC、
Linux、树莓派都可以。iPad 上装 SideJITServer 客户端，选 CraftLauncher 点激活即可。

### iPadOS 26.x 的一个额外风险

26.x 比本文写作时验证过的版本新很多。如果 `attach-jit.sh` 报「开启 JIT 失败」，
先确认不是以下原因：

1. iPad 锁屏了 —— 解锁后重试
2. 没在同一 Wi-Fi，或者路由器开了 AP 隔离
3. `pymobiledevice3` 版本太旧，不认识新系统的隧道协议 —— `pip3 install -U pymobiledevice3`

第 3 条在新系统上最常见。

---

## 先分清两件事

这是最容易混淆、也最容易白忙一场的地方：

| | 作用 | 全能签能做吗 |
|---|---|---|
| **签名** | 让 iOS 愿意安装并运行这个 App | ✅ 这是它的本职 |
| **JIT** | 让 Java 虚拟机跑得动 Minecraft | ❌ 签名解决不了 |

**签名成功 ≠ 能玩游戏。** 签完名装上去，启动器界面能打开、能下载版本、能登账号，
但点「启动」之后 Java 会以解释模式运行，进世界基本不可玩。

## 为什么签名给不了 JIT

JIT 在 iOS 上由内核的 `dynamic-codesigning` 授权控制，或者由调试器附加时设置的
`CS_DEBUGGED` 标志控制。这两者都不在证书的签发范围内 —— 证书能签的是
`get-task-allow`、`application-identifier`、`keychain-access-groups` 这一类。

所以只有三条路能拿到 JIT：

1. **越狱** —— 越狱本身授予
2. **TrollStore** —— 利用 CoreTrust 漏洞拿到扩展授权（iOS ≤16.6.1 / 17.0）
3. **调试器附加** —— AltStore / SideStore / SideJITServer / Xcode

第 3 条**恰好需要 `get-task-allow`** —— 而这个是全能签能签的。所以在非越狱设备上，
全能签 + SideJITServer 是一条真实可行的组合，见下面「方案 B」。

## 签名里最容易踩的坑

我原来的工程在 `project.yml` 里内联声明了一堆 Apple 保留权限：

```
com.apple.private.memorystatus
com.apple.developer.kernel.extended-virtual-addressing
com.apple.security.cs.allow-jit
```

**这些会让签名失败。** 它们不在任何证书的签发范围内。更麻烦的是另一种情况：
签名工具「成功」了，但实际上把它们静默剥掉了 —— 那你装上去的 App 就带着一套
它以为存在、实际不存在的权限在跑，问题会以别的形式冒出来。

**已经修好了。** 现在基础授权只有两个：

```
Resources/CraftLauncher.entitlements
├── get-task-allow                              ← SideStore / Xcode 靠它给 JIT
└── com.apple.security.cs.disable-library-validation  ← 不签这个就 dlopen 不了 Java 运行时
```

那几条私有权限的说明和启用方法留在了同一个文件的注释里，越狱设备上需要时再打开。

### 效果差异

少了私有内存授权，启动器会自动降级，不会崩：

| 权限 | 有 | 没有（全能签的常见情况） |
|---|---|---|
| `com.apple.private.memorystatus` | 按物理内存 40% 分配 | 按 25% 分配 |
| `extended-virtual-addressing` | 正常 | 自动加 `-XX:-UseCompressedClassPointers` |

这两处都是运行时探测的，同一份构建在越狱和非越狱设备上都能跑。

---

## 完整流程

### 1. 在 Mac 上构建（还没有 `.ipa` 的话）

```bash
./Scripts/bootstrap-runtime.sh     # 拉运行时，约 400 MB / 十分钟
./Scripts/generate-project.sh
open CraftLauncher.xcodeproj
```

在 Xcode 里：选你的 Team → 选 **Any iOS Device (arm64)** → **Product → Archive** →
在 Organizer 里 **Distribute App → Custom → App Store Connect** 导出，
然后从导出的包里取 `Payload/CraftLauncher.app`。

打包成 ipa：

```bash
mkdir -p Payload
cp -R CraftLauncher.app Payload/
zip -qry CraftLauncher.ipa Payload
```

> **注意**：Java 运行时压缩包是在**首次启动时**从 App 包内解压到 Documents 的。
> 所以构建产物体积会比较大（约 400 MB），这是正常的，不是打包错了。

### 2. 用全能签签名

导入 `CraftLauncher.ipa` 和一个可用证书，签名安装。

### 3. 装好后先做这个检查

打开启动器 → **设置 → 运行环境**：

| 显示 | 含义 |
|---|---|
| JIT 权限：**未启用** | 正常，签名给不了。看第 4 步 |
| JIT 权限：**已启用** | 直接玩 |
| **调试器附加许可：未授予** | ⚠️ 证书类型不对，JIT 开不了。换个人开发者证书重新签名 |
| **加载外部动态库：未授予** | ⚠️ 更严重，Java 运行时载入不了，游戏一定起不来 |
| **扩展内存上限：未授予** | 正常，功能不受影响，只是内存按 25% 而非 40% 分配 |
| 运行时库：**缺少 N 个** | App 包不完整，回去检查 `bootstrap-runtime.sh` 有没有跑 |

第三行是最需要留意的一项 —— 它决定第 4 步有没有意义。

### 4. 开启 JIT

**方案 A —— 设备已越狱**

全能签在越狱环境下可以注入额外权限。把 `Resources/CraftLauncher.entitlements`
注释里的两行打开，重新构建签名：

```xml
<key>com.apple.private.memorystatus</key>
<true/>
<key>com.apple.developer.kernel.extended-virtual-addressing</key>
<true/>
```

越狱本身已给 JIT，这两条只是把内存上限和虚拟地址空间还回来。

**方案 B —— 非越狱，用 SideJITServer**

`get-task-allow` 已经签进去了，所以调试器能附加：

1. 电脑上跑 SideJITServer（和手机连同一个 Wi-Fi）
2. 手机上用 SideJITServer 客户端，选中 CraftLauncher，点激活
3. 从后台**彻底划掉** App，重新打开
4. 回「设置 → 运行环境」确认变成「已启用」

或者用本工程的脚本（需要数据线）：

```bash
./Scripts/attach-jit.sh
```

**方案 C —— 设备在 TrollStore 支持范围内（iOS ≤16.6.1 / 17.0）**

别用全能签了，直接用 TrollStore 装。它给的授权比任何签名工具都多，而且是永久的、
不需要每次重启后重新激活。

### 5. 验证

「设置 → 运行环境」显示 JIT 已启用之后，「主页 → 启动游戏」。

首次启动会解压 Java 运行时（约 600 MB，几十秒到几分钟），然后才开始下载游戏文件。

---

## 怎么确认权限真的生效了

启动器的「运行环境」页会显示 JIT 状态，但那只反映 JIT。想确认内存授权，
看控制台里这一行：

```
[INFO] 内存分配上限 2048 MB
```

- 数字约等于物理内存 × 0.4 → 内存授权在
- 数字约等于物理内存 × 0.25 → 被剥掉了，功能正常，只是上限低一些

如果你有 `ldid`（jailbreak 环境或 macOS 上），也可以直接看签名里的权限：

```bash
ldid -e CraftLauncher.app/CraftLauncher
```

---

## 我确认不了的

我对全能签的**具体**能力没有可靠来源 —— 搜索结果只有推广页面，没有技术说明。
以下几件事我给不出确定答案：

- 它会不会静默剥离它签不了的权限
- 免费证书的 7 天过期策略在你用的版本里是怎么处理的
- 它在 iPadOS 26.x 上的签名兼容性

**第一件事你不需要猜** —— 启动器的「设置 → 运行环境」直接把结果摊开给你看，
这也是我加那几行诊断的原因。
