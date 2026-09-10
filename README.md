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
- 每 60 秒刷新一次；连接失败后按 5、15、30、60 秒逐级重试。
- 悬浮窗跟随桌宠移动，并根据可用工作区自动放到桌宠左侧或右侧。
- 支持多显示器和 DPI 缩放；窗口置顶、鼠标穿透、不抢焦点且不出现在任务栏中。
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

测试覆盖 PowerShell 语法、额度数据映射、异常值、积分切换、桌宠锚点、左右放置、100%/125%/150%/200% DPI 缩放，以及 WPF 布局渲染。

### 文件说明

| 文件 | 用途 |
| --- | --- |
| `CodexPetQuota.ps1` | 主程序、额度读取、桌宠识别、定位和 WPF 界面 |
| `Start-CodexPetQuota.cmd` | 后台启动入口 |
| `Run-CodexPetQuotaHidden.vbs` | 隐藏 PowerShell 宿主窗口 |
| `Stop-CodexPetQuota.cmd` | 向运行实例发送停止信号 |
| `Test-CodexPetQuota.ps1` | 离线测试和只读集成测试入口 |
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
- Refreshes every 60 seconds and retries failed connections after 5, 15, 30, and 60 seconds.
- Follows the Codex Desktop pet and automatically chooses the left or right side based on the available work area.
- Supports multiple monitors and DPI scaling; the overlay is topmost, click-through, non-activating, and hidden from the taskbar.
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

The suite covers PowerShell syntax, quota mapping, invalid values, credit switching, pet anchoring, left/right placement, 100%/125%/150%/200% DPI scaling, and WPF layout rendering.

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
