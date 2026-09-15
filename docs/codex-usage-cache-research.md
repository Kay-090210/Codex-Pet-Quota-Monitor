# Codex Desktop 额度缓存复用调查

调查日期：2026-09-11  
本机版本：Codex Desktop `26.903.9818.0`；`codex-cli 0.153.4`

## 目标

确认额度悬浮窗能否直接复用 Codex Desktop 已取得的额度结果，从而避免为悬浮窗额外发起额度查询；重点检查稳定的本地缓存、IPC 或 app-server 通知，而不是依赖进程内存地址。

## 当前实现

`CodexPetQuota.ps1` 启动一个独立的 `codex.exe app-server --stdio`，初始化后调用 `account/rateLimits/read`。正常情况下每 60 秒读取一次；连接失败时按 5、15、30、60 秒逐级重试。脚本已有单实例互斥，因此同一用户只运行一个悬浮窗实例时，不会因自身重复启动而叠加查询。

## 本机调查结果

1. **Desktop 前端确有自身刷新状态，但没有对外缓存接口。** 该版本的渲染端使用 `rate-limit-status` 查询状态并调用 `/wham/usage`；基础刷新间隔为 30 秒，接近额度上限时可缩短到 5 秒，并允许后台刷新。这属于 Desktop 内部实现，不是稳定的跨进程 API。
2. **app-server 协议提供读取与更新通知。** `account/rateLimits/read` 可主动读取完整快照；协议中还有 `account/rateLimits/updated` 通知。后者是稀疏更新，客户端需要先保留最近一次完整读取结果再合并，不能把单条通知独立当作完整快照。
3. **独立 app-server 未观察到可直接复用的推送。** 初始化并完成一次 `account/rateLimits/read` 后继续观察 12 秒，没有收到 `account/rateLimits/updated`。这不证明通知永远不会出现，但说明它不适合作为悬浮窗启动后的唯一数据来源。
4. **没有发现稳定的共享存储。** 本机 `.codex` 下的 SQLite 数据库表结构中未发现明确的额度快照表；`codex-ipc` 用于应用协调，未发现公开的额度缓存方法。
5. **Desktop 的 app-server 不提供可复用的 Windows 端点。** 主进程通过父子进程 stdio 管理 app-server；Windows 上未发现可让第二个客户端安全复用的固定 socket、命名管道或调试端口。app-server 的 daemon/proxy 生命周期入口目前不能作为本项目的 Windows 共享通道。
6. **直接扫描 Desktop/V8 内存不具备可维护性。** 对象地址受 ASLR、垃圾回收、构建压缩和版本更新影响；读取到的对象也无法可靠证明所属账户、时间新鲜度和完整性。该方案没有稳定 ABI，风险和维护成本都高于现有协议调用。

## 结论

当前版本没有可供本项目稳定读取的 Codex Desktop 额度缓存或共享 IPC。保持现有 `account/rateLimits/read` 方案比进程内存读取更可靠；本次不引入内存扫描，也不把内部 `/wham/usage` 当作公共接口。

如果未来 Codex Desktop 提供第一方共享额度 IPC，可让悬浮窗改为订阅该通道。若项目未来出现多个独立消费者，可再把现有查询逻辑提取为单实例本地 broker：broker 维持一个 app-server 会话并在内存中保存最近快照，其他 UI 只读本地命名管道；这能减少多个消费者的重复查询，但不会减少 Desktop 自身的刷新。

## 验证边界

- 已验证：本机安装版本、CLI 版本、协议方法、Desktop 包内调用路径、SQLite 表结构、Windows 进程/端点形态，以及一次 12 秒通知观察。
- 未验证：未来版本是否会新增共享缓存或改变内部刷新策略；本文记录只对应上述版本与调查日期。
