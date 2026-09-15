# Codex Pet Quota Monitor

[简体中文](#简体中文) · [English](#english)

一个面向 Windows 的轻量悬浮窗：跟随 Codex Desktop 桌宠显示当前账户的 5 小时额度、周额度和积分余额。

A lightweight Windows overlay that follows the Codex Desktop pet and displays the current account's five-hour limit, weekly limit, and credit balance.

## 简体中文

### 预览

| 正常额度 | 积分模式 | 正在重连 |
| --- | --- | --- |
| <img src="docs/images/quota.png" alt="5 小时和周额度" width="192"> | <img src="docs/images/credits.png" alt="积分余额" width="192"> | <img src="docs/images/reconnecting.png" alt="正在重连" width="192"> |

截图使用测试数据，不包含真实账户信息。

### 功能

- 同时显示 5 小时额度和周额度的剩余百分比与重置时间。
- 只有在 5 小时额度实际耗尽后，才将上方额度球切换为积分余额。
- 额度恢复后自动切回 5 小时额度；连接异常时清空旧数据并显示“正在重连”。
- 常态每 60 秒刷新一次；启用可选 ping 后，重置附近会提前只读查询，首次空闲候选后 33 秒确认；连接失败后按 5、15、30、60 秒逐级重试。
- 悬浮窗常态下以 8 DIP 间距贴近桌宠右侧；右侧空间不足时沿用原有规则，自动翻到桌宠左侧。
- 任务信息框出现后保持上述左右选择，从角色旁的居中位置做最小避让：上方卡片限制竖排上缘，下方卡片限制竖排下缘，保留 8 DIP 间距。只避开任务卡，不把角色、按钮和装饰的整体边界当成卡片，避免额度 UI 远落到角色上方或下方。
- 每个采样周期都先计算任务卡对侧的完整竖排位置；对侧竖排放不下时才切换为任务卡同侧横排。无任务卡时仍先尝试角色旁的完整竖排，横排下方可完整容纳时优先放在下方，否则尝试上方。允许的配对方向均无空间时临时隐藏，空间恢复后的当前周期立即恢复显示，不沿用历史方向。
- 角色左右都放不下完整竖排时，转而尝试横排，不通过横坐标钳位把额度 UI 压到角色身上；横排边界同时包含任务卡、实际内容与稳定角色锚点。
- 支持多显示器和 DPI 缩放；窗口每 250 毫秒同步到桌宠之后的相邻 Z 序（跟随其置顶/非置顶状态，不独立抢占最上层）、鼠标穿透、不抢焦点且不出现在任务栏中。
- 单实例运行；桌宠窗口不可见时自动隐藏额度悬浮窗。

### 运行要求

- Windows，且系统包含 Windows PowerShell 5.1 和 WPF。
- 已安装并登录 Codex Desktop。
- Codex Desktop 桌宠窗口处于可见状态。
- `codex.exe` 位于 `PATH`，或安装在 `%LOCALAPPDATA%\OpenAI\Codex\bin` 下。

本项目不需要额外安装 PowerShell 模块或第三方运行库。

### 快速开始

1. 下载或克隆仓库，并保持目录结构不变。
2. 双击 `Start-CodexPetQuota.cmd`。启动器会在后台隐藏 PowerShell 窗口。
3. 打开 Codex Desktop 桌宠；识别到桌宠后，额度悬浮窗会自动出现。
4. 双击 `Stop-CodexPetQuota.cmd` 停止悬浮窗及其子进程。

若需要查看启动错误，可在项目目录中直接运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexPetQuota.ps1
```

停止正在运行的实例：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexPetQuota.ps1 -Stop
```

### 可选：自动启动空闲 5H 窗口

双击 `Configure-CodexPetQuota.cmd` 设置。默认关闭；通过 Codex CLI 登录独立环境后，可启用“额度读取发现未启动窗口才 ping”。**无需另外安装 limitping，不按固定五小时定时发送，也不发测试消息来判断登录。** 内置 helper 复用其实际 CLI 单回合路径。 使用连续两次额度采样、防重发和失败保护；实际 ping 会消耗少量额度。

启用时，额度显示与 ping 使用所选同一登录环境。开关、入口、检测条件、凭证检查及验证限制见 [详细说明](docs/optional-window-ping.md)。

### 显示规则

- 剩余量大于 50%：青绿色。
- 剩余量为 20%–50%：琥珀色。
- 剩余量低于 20%：红色。
- 积分模式使用紫色；余额小于或等于 0 时使用红色。
- 积分没有总额度分母，因此不会显示虚构的百分比或水位。
- 额度不可用或连接中断时显示 `—` 和“正在重连”，不会继续展示过期数值。

### 数据与隐私

程序在本机启动 `codex.exe app-server --stdio`，并通过实验性 `account/rateLimits/read` 方法读取当前账户的限额快照。它不会直接读取或复制 Codex 认证文件，也不会把额度、积分或 app-server 标准错误写入日志。

`-ProbeOnce` 和不带 `-SkipIntegration` 的测试会将当前额度及积分数据输出到终端。分享终端记录前请先检查内容。

本项目是独立的社区工具，并非 OpenAI 官方产品。

### 常见问题

**悬浮窗没有出现**

- 确认 Codex Desktop 桌宠当前可见。
- 使用上面的 PowerShell 命令前台启动，检查是否出现 `未找到 codex.exe` 等错误。
- 再次运行启动脚本不会创建第二个实例。

**一直显示“正在重连”**

- 确认 Codex Desktop 已登录且当前网络可用。
- 等待自动重试，或先运行停止脚本，再重新启动。

**如何彻底退出**

- 运行 `Stop-CodexPetQuota.cmd`。主悬浮窗退出时会同时结束由它启动的 app-server 子进程。

### 开发与验证

最小离线验证不会读取真实账户数据：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-CodexPetQuota.ps1 -SkipIntegration
```

完整只读集成测试会额外读取并输出当前账户额度：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-CodexPetQuota.ps1
```

测试覆盖 PowerShell 语法、额度数据映射、异常值、积分切换、桌宠锚点、左右放置、贴边信息框偏移/变宽/消失、任务卡上下方向与横竖布局配对、截图紧凑定位及上下镜像、最小避让一像素临界值、外部按压经过角色不误触拖动、锚点轻微相交回归、竖排空间动态判定、原 35% 分界位置不提前横排、顶部/底部镜像触发、恢复空间后立即切回竖排、无任务卡时的横排下方优先及上方回退、负坐标工作区、窄屏避让与隐藏恢复、100%/125%/150%/200% DPI 缩放、WPF 横竖布局渲染及原生窗口位置/尺寸切换。

### 文件说明

| 文件 | 用途 |
| --- | --- |
| `CodexPetQuota.ps1` | 主程序、额度读取、桌宠识别、定位和 WPF 界面 |
| `Start-CodexPetQuota.cmd` | 后台启动入口 |
| `Run-CodexPetQuotaHidden.vbs` | 隐藏 PowerShell 宿主窗口 |
| `Stop-CodexPetQuota.cmd` | 向运行实例发送停止信号 |
| `Test-CodexPetQuota.ps1` | 离线测试和只读集成测试入口 |
| `Configure-CodexPetQuota.cmd` | 可选 ping 设置、CLI 登录和只读凭证检查 |
| `CodexQuotaPing.ps1` / `CodexPingTransport.cs` | 窗口检测、防重发与内置 Go helper 进程管理 |
| `Test-CodexQuotaPing.ps1` | ping 策略与持久化的独立离线测试 |
| `docs/images/` | README 使用的测试数据截图 |

### 已知限制

- 仅支持 Windows PowerShell 5.1 / STA 环境。
- 悬浮窗只会在识别到 Codex Desktop 桌宠窗口时显示。
- 额度读取依赖实验性 app-server 接口；Codex 更新后，该接口或桌宠窗口结构可能变化。
- 项目不包含开机自启动安装器；需要时请自行创建指向 `Start-CodexPetQuota.cmd` 的启动项。

### 许可证

本项目采用 [MIT License](LICENSE)。

## English

### Preview

The three screenshots above use test data and contain no real account information.

### Features

- Shows remaining percentages and reset times for both the five-hour and weekly limits.
- Switches the upper orb to the credit balance only after the five-hour limit is actually exhausted.
- Returns to the five-hour view when the limit recovers and clears stale values while reconnecting.
- Normally refreshes every 60 seconds; optional ping uses reset-aware reads and 33-second candidate confirmation. Retries failed connections after 5, 15, 30, and 60 seconds.
- Normally stays close to the pet's right side with an 8-DIP gap, retaining the original fallback to the left when the right side has insufficient room.
- When the task card appears, keeps that left/right choice and applies only the minimum vertical shift from the pet-centered position: below an upper card or above a lower card, with an 8-DIP clearance. It avoids the card itself, not the combined bounds of the pet, controls, and decorations, so the stack stays close to the pet.
- Re-evaluates a complete safe vertical placement on every sample and switches to a horizontal row only when the vertical stack does not fit. With a card, the stack stays on the opposite side of the card and the row uses the same side as the card. Without a card, the row prefers below, then above. The overlay temporarily hides if the permitted placements do not fit and immediately restores the vertical layout when space returns.
- If neither side has enough width for the stack, it tries a row rather than clamping the stack over the pet. Horizontal placement includes the task card, current content, and stable pet anchor in its obstacle bounds.
- Supports multiple monitors and DPI scaling; the overlay follows immediately behind the pet in Z order every 250 ms (including its topmost/non-topmost state, without independently raising itself to the top), click-through, non-activating, and hidden from the taskbar.
- Runs as a single instance and hides automatically when the pet window is unavailable.

### Requirements

- Windows with Windows PowerShell 5.1 and WPF.
- Codex Desktop installed and signed in.
- A visible Codex Desktop pet window.
- `codex.exe` available on `PATH` or installed under `%LOCALAPPDATA%\OpenAI\Codex\bin`.

No additional PowerShell modules or third-party runtime dependencies are required.

### Quick start

1. Download or clone the repository and keep its directory structure intact.
2. Double-click `Start-CodexPetQuota.cmd`. It launches PowerShell hidden in the background.
3. Open the Codex Desktop pet. The quota overlay appears after the pet is detected.
4. Double-click `Stop-CodexPetQuota.cmd` to stop the overlay and its child process.

To diagnose startup errors in a visible terminal, run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexPetQuota.ps1
```

To stop the running instance:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\CodexPetQuota.ps1 -Stop
```

### Optional idle-window ping

Open `Configure-CodexPetQuota.cmd`. This feature is off by default, uses a bundled helper reusing limitping’s CLI provider (no separate limitping installation), and detects an idle five-hour window from consecutive quota reads rather than a fixed timer. Login checks do not send model requests; actual pings consume quota. When enabled, the overlay and ping use the same selected profile. See [configuration, safeguards and limitations](docs/optional-window-ping.md#english).

### Display behavior

- More than 50% remaining: teal.
- 20%–50% remaining: amber.
- Less than 20% remaining: red.
- Credit mode uses purple, or red when the balance is zero or negative.
- Credits have no total allowance, so the UI does not invent a percentage or fill level.
- Unavailable data is shown as `—` with a reconnecting status instead of keeping stale values.

### Data and privacy

The tool starts `codex.exe app-server --stdio` locally and reads the current account snapshot through the experimental `account/rateLimits/read` method. It does not directly read or copy Codex authentication files, and it does not persist quota values, credit balances, or app-server standard error to log files.

`-ProbeOnce` and tests run without `-SkipIntegration` print the current quota and credit data to the terminal. Review terminal output before sharing it.

This is an independent community project and is not an official OpenAI product.

### Troubleshooting

**The overlay does not appear**

- Make sure the Codex Desktop pet is visible.
- Start the PowerShell script in a visible terminal and check for errors such as `未找到 codex.exe`.
- Starting the launcher again does not create a second instance.

**The overlay stays in the reconnecting state**

- Confirm that Codex Desktop is signed in and the network is available.
- Wait for automatic retry, or run the stop launcher before starting it again.

**Exit completely**

- Run `Stop-CodexPetQuota.cmd`. Closing the overlay also terminates the app-server child process it created.

### Development and verification

Run the minimum offline verification without reading real account data:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-CodexPetQuota.ps1 -SkipIntegration
```

Run the complete read-only integration test, which also prints the current account limits:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-CodexPetQuota.ps1
```

The suite covers PowerShell syntax, quota mapping, invalid values, credit switching, pet anchoring, left/right placement, shifted/resized/dismissed task cards near screen edges, compact screenshot regression, mirrored minimal card avoidance, one-pixel fit boundaries, rejecting drag gestures started outside the pet, dynamic vertical-space decisions, no premature switch at the former 35% boundaries, mirrored top/bottom triggers, immediate vertical recovery when room returns, below-first horizontal placement with an above fallback, negative-coordinate work areas, narrow-screen avoidance and hide/recovery placement, 100%/125%/150%/200% DPI scaling, WPF rendering in both orientations, and native window position/size transitions.

### Project files

| File | Purpose |
| --- | --- |
| `CodexPetQuota.ps1` | Main program, quota reader, pet detection, positioning, and WPF UI |
| `Start-CodexPetQuota.cmd` | Background launcher |
| `Run-CodexPetQuotaHidden.vbs` | Hides the PowerShell host window |
| `Stop-CodexPetQuota.cmd` | Signals the running instance to stop |
| `Test-CodexPetQuota.ps1` | Offline and read-only integration test entry point |
| `docs/images/` | Test-data screenshots used by this README |

### Known limitations

- Windows PowerShell 5.1 / STA only.
- The overlay is visible only while a Codex Desktop pet window is detected.
- Quota retrieval relies on an experimental app-server interface; a future Codex update may change the interface or pet-window structure.
- No startup installer is included. Create a startup entry for `Start-CodexPetQuota.cmd` manually if needed.

### License

Licensed under the [MIT License](LICENSE).
