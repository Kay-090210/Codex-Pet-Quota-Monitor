# 可选的空闲 5H 窗口 ping / Optional idle-window ping

## 简体中文

### 入口与默认行为

双击 `Configure-CodexPetQuota.cmd` 打开独立设置菜单。功能默认关闭，原启动器与点击穿透悬浮窗保持不变，不增加托盘或可点击覆盖层。

- **登录独立环境**：通过安装的 Codex CLI `login` 登录。新用户无需安装 limitping。
- **检查登录**：调用该登录环境的 `account/rateLimits/read`，不发送模型请求。
- **启用**：先通过上述只读检查，保存设置，停止并重新启动悬浮窗后生效。开关持久保存，以后正常启动即生效，不必重复启用。
- **关闭**：正在运行的实例约一秒内停止自动 ping；重启后恢复默认额度来源。
- **使用已有 CODEX_HOME**：高级选项，只保存路径，不读取或复制凭证。可以用于本机已有的独立登录环境，不是其他用户的安装前提。
- **查看 ping 状态**：显示上一次尝试和结果，不显示账户、令牌或终端原始输出。

启用时，额度读取和 ping **使用设置中同一 CODEX_HOME、同一 Codex 引擎**，避免根据甲账户的额度向乙账户发请求。该环境的账号就是悬浮窗展示的账号，请选择自己实际要监控的登录环境。程序不改系统环境变量或桌面端默认登录。更换目录或模型后需重新启动。

### 何时发送

每次成功获取额度后判断，不运行固定每 5 小时的独立定时器：

1. 必须有明确的 `codex` 额度桶、300 分钟窗口、有效原始已用百分比和重置时间。只有周额度、数据缺失、错误、过期重置时间均不触发。
2. 原始 `usedPercent` 必须等于 **0**，不使用界面取整后的剩余 100%。
3. 重置时间与“当前 UTC 时间 + 18000 秒”相差不超过 **15 秒**。
4. 等待第二次新鲜读取：两次间隔 **30–150 秒**，重置时间的增长与两次间隔相差不超过 **10 秒**。固定不动的 reset 表明已有窗口，即使用量仍是 0 也不发送。
5. 周已用量达到 **99%**、有请求进行中、距上次尝试不足 **60 秒**或处于持久化抑制期时不发送。

这是根据窗口时间行为推断“未启动窗口”，不是服务端承诺的专用状态字段。连续采样比单次“100% + 五小时”更保守；首次有效空闲候选后约 33 秒再次读取，最少 30 秒的确认门槛保持不变。系统时钟偏差、响应延迟或未来接口行为变化可能造成跳过，不会把缺失值当作零。

### 重置附近的只读查询调度

- 平时仍为每次响应后 60 秒读取。已知有效窗口临近重置时，下一次读取提前到旧 `reset + 3 秒`；该时间只安排查询，不直接发送 ping。
- 同一旧 reset 到点后仍返回旧数据时，每 5 秒复查，最晚到该 reset 后 60 秒结束快速复查。启动时只有陈旧数据、数据异常、周额度保护、忙碌或更长的发送抑制期均不启用快速复查。
- 首次空闲候选后停止 5 秒复查，改为 33 秒后确认，避免连续覆盖候选导致始终达不到 30 秒。固定 reset、已用量非零或畸形数据仍不发送。
- 新活动窗口使用其新 reset；断线重连会清除候选和查询锚点，保留 5/15/30/60 秒连接退避。候选和查询锚点不持久化。
- 正常网络且服务端及时更新时，预计重置到启动约 35–45 秒；这是调度估算，不是跨窗口实测保证，CLI 启动与模型回合耗时另计。
- 事件日志新增 `quota_read_started` / `quota_read_received`（RPC ID）及 `read_scheduled`（等待秒数），不保存原始额度、账号或凭据。用于分别核对真实读取及调度；回合完成仍不等同于窗口启动验证。

### CLI 途径与成本

直接使用 Windows **ConPTY 交互式 Codex CLI**，不是 `codex exec`，通过项目内置的 Go helper 复用 limitping 的单回合 provider，不启动 limitping 定时器，也无需另外安装 limitping。发送初始消息 `ok`，默认模型 `gpt-5.6-luna`、推理强度 `low`。实际请求会消耗额度；模型可在本机配置的 `Model` 字段修改，可用性取决于账号与 CLI。

使用固定的 `WorkingDirectory` 和所选 `CODEX_HOME`，沿用原 provider 的参数、环境过滤、ConPTY、会话检查和退出流程。首次使用新目录时，应先在该 CLI 环境中交互完成登录/目录信任等启动提示；设置菜单的“初始化固定工作目录”不附带消息，不会主动发送 ping。不要配置含不必要项目指令的目录。

helper 结合新会话 `task_complete`、无错误和非空回复判断回合完成；C# 只负责启动、Job 进程树和严格结果协议。另用后续额度读取观察窗口。进程退出码为 0 不等于 ping 成功。来源、MIT 许可、文件哈希及修改点见 `helper/limitping/README.md`。

### 防重发和失败处理

- 启动 CLI **之前**原子保存尝试时间，重启后依旧去重；同时至多一个请求。
- provider 等待回合最多 90 秒，外层看门狗最多 120 秒，关闭或退出时通过 Windows Job 清理该请求的进程树。
- 即便失败、超时、退出或回复未确认，也默认抑制至本次尝试后的 5 小时，避免每分钟产生重复用量。这个期限只限制重试，不触发定时发送。
- 后续观察到有效的固定窗口后，抑制期限更新为该窗口实际的 reset 时间。请求结果 `AttemptOutcome` 与窗口观察 `WindowStatus` 分开保存：后来的窗口不会覆盖失败记录，也不默认归因于本次 ping。
- 认证错误会暂停本次运行的自动 ping；重新登录并重启后再检查。配置或状态损坏时保守停止发送。
- 网络失败不等于凭证失效；只读检查只证明检查当时额度接口可访问，不保证凭证永久有效或模型调用必定成功。

若另一个工具也在自动 ping，两者没有共同锁；建议只保留一个自动启动窗口的工具。特别是本机复用已有 CODEX_HOME 时，避免另一个工具同时刷新相同 OAuth 登录或发送请求。

### 本机文件与隐私

- `config.local.ping.json`：开关、登录目录、模型、固定工作目录；Git 忽略。
- `.codex-pet-local/codex-home/`：新用户通过 CLI 创建的独立登录环境；Git 忽略。认证由 CLI 自行维护，项目代码不解析它。
- `.codex-pet-local/ping-state.json`：尝试 ID、时间、抑制期限、请求结果、窗口状态和目录；无令牌或账户额度。
- `.codex-pet-local/ping-workspace/`：默认固定工作目录，不随请求删除；可由本机配置覆盖。

- `.codex-pet-local/ping-events.jsonl`：时间、事件、原因和尝试 ID；记录额度判断、启动、完成/超时/失败和暂停。超过 1 MB 轮换为 `ping-events.previous.jsonl`，不含原始账户响应、终端输出或凭据。

不复制、备份或提交认证信息。账号会话仍由 Codex CLI 按自身规则维护。卸载或移动项目时需自行妥善处理个人登录环境，切勿上传 `.codex-pet-local`。

### 验证边界

最小离线测试包含策略边界、配置与状态持久化、C# 编译以及原有 WPF/定位测试。`-CheckPingLogin` 是只读联网检查，不发 ping；常规 `-ProbeOnce` 仍是原来的默认登录环境只读探测，不会触发自动 ping。

显式运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File .\Test-CodexPingLive.ps1 -SendPing` 执行真实请求验收（先停止监视器，会消耗额度）。它调用生产发送函数并独立核对会话，结果保存在 Git 忽略的 `verification/ping-live-*.json`。`-VerifyLastAttempt` 只复核已有尝试，不重发。真实测试既不自动兑换额度重置，也不纳入普通启动或离线测试。

真实模型请求、窗口启动效果以及用户的真实拖动体验必须单独记录；离线通过不代表这些已经验证。Windows ConPTY 需要 Windows 10 1809 或更新版本，CLI 更新可能影响功能开关、登录、会话事件或窗口行为。

## English

Run `Configure-CodexPetQuota.cmd`. Idle-window ping is **off by default** and does not change the click-through overlay. Sign in with the installed Codex CLI, check quota access without a model request, then enable and restart. No limitping installation is needed; reusing an existing `CODEX_HOME` is an optional local setup choice.

When enabled, quota reads and ping use the **same configured profile and engine**. The overlay therefore displays that profile's account. No credentials are copied or parsed by this project, and system/Desktop login settings are not changed.

After successful quota reads, require raw `usedPercent == 0`, an exact 300-minute window, and reset approximately `now + 18000s` (15s tolerance). A second sample 30–150s later must show the reset moving forward by the elapsed time (10s tolerance). Fixed resets, missing/expired/invalid data, weekly usage of 99% or more, concurrent requests and cooldowns do not trigger ping. This is a conservative heuristic, not a documented idle-window API flag.

Reads normally remain 60s apart after responses. Near a known reset, schedule a read at reset + 3s; stale responses for that same reset are retried every 5s only until reset + 60s. The first idle candidate schedules confirmation 33s later (the minimum 30s gate is unchanged). Reconnection clears candidate and scheduling anchors; guards and persistent send suppression remain in place. The estimated 35–45s reset-to-start latency requires real cross-window validation. Redacted read events include RPC IDs and scheduled delays, never raw quota responses.

The transport directly launches the interactive Codex CLI in Windows ConPTY, with `ok`, model `gpt-5.6-luna`, low reasoning, a fixed trusted working directory and the configured profile. The bundled Go helper reuses limitping’s provider, ConPTY, environment filtering and session verification. It does not use `codex exec` or a fixed five-hour scheduler. Actual requests consume quota. A completed session response and a later observed active quota window are separate confirmations; exit code zero alone is insufficient.

Attempts are persisted before launch, deduplicated for at least 60s and conservatively suppressed for up to five hours after ambiguous failure. An observed active window updates suppression to its reset time. The 90s provider wait and 120s outer watchdog and Job cleanup terminate owned process trees. Authentication errors pause automatic ping; network errors are not labeled invalid credentials. A quota-access check establishes current access only, not permanent credential validity or guaranteed model access.

The enabled setting persists across restarts. Local configuration, profile, state and workspace directories are Git-ignored. Request outcomes and observed windows are recorded separately; later quota observations never overwrite request failures. Redacted events are in `.codex-pet-local/ping-events.jsonl` (1 MB rotation). Run `Test-CodexPingLive.ps1 -SendPing` explicitly for a real paid/quota-consuming request; `-VerifyLastAttempt` rechecks without resending. Initialize new trusted directories interactively without a prompt first. Do not run another automatic window-ping tool concurrently. Offline tests cover policy/state and compilation plus existing UI tests; real model activation and physical dragging require separate validation. ConPTY requires Windows 10 1809 or later.

Official authentication reference: [OpenAI documentation — Authentication](https://learn.chatgpt.com/docs/auth).
