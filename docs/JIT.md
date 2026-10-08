# iOS 上的 JIT：为什么绕不过去，以及怎么办

## 结论先行

**没有 JIT，这个启动器启动的 Minecraft 基本没法玩。** 这不是本项目的缺陷，
是 Apple 的安全策略，所有 iOS 上的 Java 版启动器都受同一限制。

> **用全能签之类的证书工具侧载？** 签名解决不了 JIT —— JIT 由内核的
> `dynamic-codesigning` 授权或调试器的 `CS_DEBUGGED` 标志控制，都不在证书签发范围内。
> 但 `get-task-allow` 是可以签的，所以「全能签安装 + SideJITServer 附加调试器」
> 是一条真实可行的组合。具体步骤见 [SIGNING.md](SIGNING.md)。

Java 虚拟机有两种执行字节码的方式：

- **解释执行** —— 逐条翻译，不需要生成新代码，任何环境都能跑
- **即时编译（JIT）** —— 把热点方法编译成机器码再执行，快一到两个数量级

iOS 对"运行时生成并执行代码"有严格限制（`MAP_JIT` 需要专门授权，且代码签名
不允许页面在签名后被改成可执行）。所以 JVM 只能退回纯解释模式。

实测差距大致是：一个在现代 iPhone 上能跑 60 fps 的场景，解释模式下会掉到个位数，
并且区块加载慢到走出去就掉进未加载的地形里。

## 探测当前状态

启动器在「设置 → 运行环境」里显示 JIT 状态，也可以通过日志确认：

```
[INFO] JIT 已启用，可以启动 Java 虚拟机。
```

探测方式是对内核的 `kern.jit_enable` 取一个整数：

```objc
int mib[2] = { CTL_KERN, 43 /* KERN_JIT_ENABLE */ };
int value = 0; size_t size = sizeof(value);
sysctl(mib, 2, &value, &size, NULL, 0);
```

三种结果都会如实显示：

| 结果 | 含义 | 处理 |
|---|---|---|
| 已启用 | 当前进程有 JIT 权限 | 直接启动 |
| 未启用 | 内核明确拒绝 | 提示用户，但仍然尝试启动（调试器可能在之后才附加） |
| 未知 | 探测本身失败（老系统没有这个开关） | 直接尝试启动 |

**"未启用"不是硬性阻断。** AltStore / SideStore 是在 App 启动后再附加调试器来
授予 JIT 的，所以按下启动按钮那一刻探测到的结果可能还是"未启用"，而实际启动时
权限已经到位了。把它做成硬性阻断只会让这些用户完全无法使用。

## 四种可行方案

按推荐程度排列。

### 1. TrollStore（最省事，但受系统版本限制）

利用 CoreTrust 漏洞安装，App 会拿到包括 JIT 在内的扩展授权，装上就能用，
不需要连电脑。

- **支持范围**：iOS 14.0 – 16.6.1，以及 17.0
- **要求**：设备在支持范围内
- **步骤**：
  1. 在设备上安装 [TrollStore](https://ios.cfw.guide/installing-trollstore)
  2. 把构建好的 `.ipa` 用 AirDrop 或「文件」传进设备
  3. 在 TrollStore 里点开它安装
  4. 首次启动后，启动器的「设置」里应该显示 JIT 已启用

TrollStore 安装的 App 带有 `get-task-allow` 之外的额外授权，`project.yml` 里已经
声明了需要的几项。

### 2. 越狱设备

越狱环境下 JIT 由越狱本身授予，不需要额外操作。

- **支持范围**：取决于越狱工具（palera1n、Dopamine、unc0ver 等）
- **步骤**：越狱后直接安装 `.ipa`
- **注意**：某些越狱会用 `sandbox_extension` 限制 App 的写权限，
  如果「设置」里报无法创建目录，把工作目录改到 App 自己的容器里即可

### 3. SideStore / AltStore + JIT 激活（不越狱，需要电脑或同网设备）

通过附加调试器（`debugserver`）授予 `CS_DEBUGGED` 标志，App 由此获得 JIT 权限。

- **支持范围**：
  - iOS 17.0.1 以下：SideStore 内置 JIT 激活，或 AltStore 的 AltJIT
  - iOS 17.0.1 及以上：需要借助 `pymobiledevice3`，见下
- **iOS 17.0.1+ 的步骤**（以 SideJITServer 为例）：
  1. 在电脑上（或局域网内另一台设备）跑 SideJITServer
  2. 手机与它连同一个 Wi-Fi
  3. 在手机上打开 SideJITServer 客户端，选中 CraftLauncher，点激活
  4. 从后台彻底划掉 App，再重新打开
- **缺点**：每次设备重启后都要重新激活；必须有网络

### 4. SideJITServer / pymobiledevice3（iOS 17.0.1+ 的主要途径）

iOS 17.0.1 收紧了 `debugserver` 的连接方式，现在必须在主机侧通过
`pymobiledevice3` 发起：

```bash
# 在电脑上，手机用数据线连接
pip install pymobiledevice3
sudo pymobiledevice3 lockdownd start-tunnel   # 保持运行
# 另开一个终端
pymobiledevice3 developer dvt enable-jit --pid $(pidof CraftLauncher)
```

`Scripts/attach-jit.sh` 把这几步包成了一个命令：

```bash
./Scripts/attach-jit.sh
```

它会自动找到设备、定位 CraftLauncher 的进程号并开启 JIT。

## 各方案对比

| 方案 | 需要电脑 | 重启后要重做 | 系统要求 | 安装方式 |
|---|---|---|---|---|
| TrollStore | 否 | 否 | **≤ 16.6.1 / 17.0** | 设备内直接装 |
| 越狱 | 否 | 否 | 取决于工具，新系统通常滞后 | 设备内直接装 |
| SideStore | 首次需要 | 是 | 全部 | 电脑侧载 |
| SideJITServer | 是（每次） | 是 | **17.0.1 及以上** | 电脑侧载 |
| Xcode 直接运行 | 是 | 是 | 全部 | 开发期最方便 |

**如果你的系统比较新（例如 iPadOS 26.x）**：TrollStore 和越狱都不可用，
只剩 SideJITServer 这一条路，而且前提是签名里保留了 `get-task-allow`。
先去「设置 → 运行环境」确认那一行，再看 [SIGNING.md](SIGNING.md)。

**开发期建议**：直接用 Xcode 跑 Debug 配置。Xcode 附加调试器时天然带
`get-task-allow`，JIT 自动可用，改代码后一键重跑。等到功能稳定了再用
TrollStore 或 SideStore 装到日常使用的设备上。

## 常见误解

**"用 AltStore 装上就能玩了"** —— 装上和能玩是两件事。AltStore 只负责签名安装，
JIT 需要在 App 启动后单独激活（AltJIT 或 SideJITServer）。

**"装个 UTM 之类的模拟器跑 Linux 版就行"** —— UTM SE（App Store 版本）没有 JIT，
跑起来比解释模式还慢；完整 UTM 同样需要 JIT。绕了一圈回到同一个限制。

**"那就用解释模式凑合"** —— 可以启动，能进主菜单，但进入世界后基本不可用。
如果你只是想看看启动器界面和日志，解释模式完全够用。

## 参考

- [PojavLauncher 的 JIT 说明](https://github.com/PojavLauncherTeam/pojavlauncherteam.github.io/blob/main/markdown/wiki/faq/ios/JIT.md)
- [iOS 上启用 JIT 的方法汇总](https://github.com/ItAnthon/JIT-on-iOS)
- [SideStore 的 JIT 文档](https://docs.sidestore.io/docs/faq#can-i-activate-jit)
- [SideJITServer](https://github.com/nythepegasus/SideJITServer)
