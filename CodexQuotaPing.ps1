#requires -version 5.1
# 可选窗口启动策略。仅处理额度快照、路径及非敏感状态，不解析认证文件。
$script:PingConfigPath = Join-Path $PSScriptRoot 'config.local.ping.json'
$script:PingLocalRoot = Join-Path $PSScriptRoot '.codex-pet-local'
$script:PingStatePath = Join-Path $script:PingLocalRoot 'ping-state.json'

function Get-PingConfiguration {
    $config = [pscustomobject]@{
        Enabled = $false; CodexHome = (Join-Path $script:PingLocalRoot 'codex-home')
        Model = 'gpt-5.6-luna'; Valid = $true
        WorkingDirectory = (Join-Path $script:PingLocalRoot 'ping-workspace')
    }
    if (Test-Path -LiteralPath $script:PingConfigPath) {
        try {
            $saved = Get-Content -LiteralPath $script:PingConfigPath -Raw | ConvertFrom-Json
            if ($saved.Enabled -isnot [bool] -or
                -not [IO.Path]::IsPathRooted([string]$saved.CodexHome) -or
                [string]::IsNullOrWhiteSpace([string]$saved.Model)) { throw 'Invalid configuration' }
            $config.Enabled = $saved.Enabled
            $config.CodexHome = [IO.Path]::GetFullPath($saved.CodexHome)
            $config.Model = [string]$saved.Model
            if ($saved.WorkingDirectory) {
                if (-not [IO.Path]::IsPathRooted([string]$saved.WorkingDirectory)) { throw 'Invalid working directory' }
                $config.WorkingDirectory = [IO.Path]::GetFullPath($saved.WorkingDirectory)
            }
        }
        catch { $config.Valid = $false; $config.Enabled = $false }
    }
    return $config
}

function Save-PingConfiguration {
    param($Configuration)
    $Configuration | Select-Object Enabled, CodexHome, Model, WorkingDirectory |
        ConvertTo-Json | Set-Content -LiteralPath $script:PingConfigPath -Encoding UTF8
}

function New-PingState {
    return [pscustomobject]@{
        LastAttempt = 0L; SuppressUntil = 0L; Status = '未发送'
        PreviousAt = 0L; PreviousReset = 0L; Home = ''; Valid = $true
        AttemptId = ''; AttemptOutcome = 'none'; WindowStatus = 'unknown'; Trigger = 'automatic'
    }
}

function Read-PingState {
    $state = New-PingState
    if (Test-Path -LiteralPath $script:PingStatePath) {
        try {
            $saved = Get-Content -LiteralPath $script:PingStatePath -Raw | ConvertFrom-Json
            foreach ($key in @('LastAttempt', 'SuppressUntil')) {
                $value = 0L
                if (-not [long]::TryParse([string]$saved.$key, [ref]$value) -or $value -lt 0) { throw 'Invalid state' }
                $state.$key = $value
            }
            $state.Status = [string]$saved.Status
            $state.Home = [string]$saved.Home
            foreach ($key in @('AttemptId','AttemptOutcome','WindowStatus','Trigger')) {
                if ($saved.$key) { $state.$key = [string]$saved.$key }
            }
            if ($state.LastAttempt -gt 0 -and $state.AttemptOutcome -eq 'none') { $state.AttemptOutcome = 'legacy_unverified' }
        }
        catch { $state.Valid = $false; $state.Status = '状态文件异常，已暂停自动 ping' }
    }
    return $state
}

function Save-PingState {
    param($State)
    if (-not $State.Valid) { throw '异常状态需要人工检查；不覆盖防重发记录。' }
    [void][IO.Directory]::CreateDirectory($script:PingLocalRoot)
    $json = $State | Select-Object LastAttempt, SuppressUntil, Status, Home, AttemptId, AttemptOutcome, WindowStatus, Trigger | ConvertTo-Json
    $temporary = $script:PingStatePath + '.tmp'
    [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($true))
    # 先落盘再启动模型；崩溃、重新启动也不会立即重复请求。
    if (Test-Path -LiteralPath $script:PingStatePath) {
        [IO.File]::Replace($temporary, $script:PingStatePath, [System.Management.Automation.Language.NullString]::Value)
    }
    else { [IO.File]::Move($temporary, $script:PingStatePath) }
}

function Write-PingEvent {
    param([string]$Event, [string]$Detail = '', [string]$AttemptId = '')
    # 固定字段白名单：不记录账户快照、终端原文或异常对象。
    try {
        [void][IO.Directory]::CreateDirectory($script:PingLocalRoot)
        $path = Join-Path $script:PingLocalRoot 'ping-events.jsonl'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -ge 1MB) {
            $previous = Join-Path $script:PingLocalRoot 'ping-events.previous.jsonl'
            if ([IO.File]::Exists($previous)) { [IO.File]::Replace($path, $previous, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($path, $previous) }
        }
        $record = [ordered]@{ time = [DateTimeOffset]::Now.ToString('o'); event = $Event; detail = $Detail; attemptId = $AttemptId }
        [IO.File]::AppendAllText($path, (($record | ConvertTo-Json -Compress) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
    }
    catch { Write-Warning 'ping 事件日志写入失败。' }
}

function Resolve-PingHelper {
    $helper = Join-Path $PSScriptRoot 'bin\codex-pet-ping.exe'
    if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw '缺少 ping helper，请先运行 helper\limitping\Build.ps1。' }
    return $helper
}

function Get-PingNumber {
    param($Value)
    $number = 0.0
    if ($null -eq $Value -or $Value -is [bool] -or
        -not [double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$number) -or
        [double]::IsNaN($number) -or [double]::IsInfinity($number)) { return $null }
    return $number
}

function Get-WindowPingDecision {
    param($Response, $State, [long]$Now, [bool]$Enabled, [bool]$Busy = $false)
    $decision = [pscustomobject]@{ Send = $false; Reason = 'disabled'; Reset = 0L; Active = $false }
    if (-not $Enabled -or -not $State.Valid) { return $decision }
    try {
        # 不回退到其他 limit id；畸形响应/缺少窗口不是空闲窗口。
        $result = Get-ObjectPropertyValue $Response 'result'
        if ($null -eq $result) { $result = $Response }
        if ($null -ne (Get-ObjectPropertyValue $Response 'error')) { throw 'RPC error' }
        $byId = Get-ObjectPropertyValue $result 'rateLimitsByLimitId'
        if ($null -ne $byId) { $snapshot = Get-ObjectPropertyValue $byId 'codex' }
        else { $snapshot = Get-ObjectPropertyValue $result 'rateLimits' }
        $five = Select-RateLimitWindow $snapshot 300
        $week = Select-RateLimitWindow $snapshot 10080
        $used = Get-PingNumber (Get-ObjectPropertyValue $five 'usedPercent')
        $weekly = Get-PingNumber (Get-ObjectPropertyValue $week 'usedPercent')
        $reset = Get-PingNumber (Get-ObjectPropertyValue $five 'resetsAt')
        $duration = Get-PingNumber (Get-ObjectPropertyValue $five 'windowDurationMins')
        if ($null -eq $used -or $used -lt 0 -or $used -gt 100 -or
            $null -eq $weekly -or $weekly -lt 0 -or $weekly -gt 100 -or
            $null -eq $reset -or $reset -le 0 -or $reset -ne [math]::Floor($reset) -or
            $duration -ne 300) { throw 'Incomplete quota' }
        [void][DateTimeOffset]::FromUnixTimeSeconds([long]$reset)
        $decision.Reset = [long]$reset
        $delta = $reset - $Now
        # 使用原始已用量；显示为100%的0.1%消耗并不满足条件。
        $candidate = $used -eq 0 -and [math]::Abs($delta - 18000) -le 15
        $elapsed = $Now - $State.PreviousAt
        $rolling = $candidate -and $State.PreviousAt -gt 0 -and $elapsed -ge 30 -and $elapsed -le 150 -and
            [math]::Abs(($reset - $State.PreviousReset) - $elapsed) -le 10
        $decision.Active = $delta -gt 0 -and ($used -gt 0 -or $delta -lt 17970)
        if ($candidate) { $State.PreviousAt = $Now; $State.PreviousReset = [long]$reset }
        else { $State.PreviousAt = 0L; $State.PreviousReset = 0L }
        if ($Busy) { $decision.Reason = 'busy' }
        elseif ($weekly -ge 99) { $decision.Reason = 'weekly-guard' }
        elseif ($Now -lt $State.LastAttempt + 60 -or $Now -lt $State.SuppressUntil) { $decision.Reason = 'cooldown' }
        elseif ($rolling) { $decision.Send = $true; $decision.Reason = 'rolling-idle-window' }
        elseif ($candidate) { $decision.Reason = 'confirm-next-sample' }
        else { $decision.Reason = 'active-or-unknown' }
    }
    catch {
        $State.PreviousAt = 0L; $State.PreviousReset = 0L
        $decision.Reason = 'invalid-snapshot'
    }
    return $decision
}

# 只决定下一次只读查询时间；不产生发送许可，不持久化查询锚点。
function New-PingReadSchedule {
    return [pscustomobject]@{ Reset = 0L; LastAt = 0L }
}

function Get-PingReadDelay {
    param($Decision, $State, $Schedule, [long]$Now)
    if ($Now -lt $Schedule.LastAt -or $Decision.Reason -in @('disabled', 'invalid-snapshot', 'weekly-guard', 'busy')) {
        $Schedule.Reset = 0L
        $Schedule.LastAt = $Now
        return 60
    }
    $Schedule.LastAt = $Now
    if ($Decision.Reason -eq 'confirm-next-sample') {
        # 首个候选后停止快速复查，避免不断覆盖 PreviousAt 而永远不足30秒。
        $Schedule.Reset = 0L
        return 33
    }
    if ($Decision.Send) { $Schedule.Reset = 0L; return 60 }
    $reset = $Decision.Reset
    if ($reset -gt $Now) {
        $Schedule.Reset = $reset
        if ($State.SuppressUntil -gt ($reset + 3) -or $State.LastAttempt + 60 -gt ($reset + 3)) { return 60 }
        # 平时60秒；临近已知reset时对齐reset+3，不到点发送。
        return [int][math]::Min(60, $reset + 3 - $Now)
    }
    # 仅对本进程先前见过的未来reset做短暂复查；启动时陈旧数据不进入快轮询。
    if ($reset -gt 0 -and $reset -eq $Schedule.Reset -and $Now -lt ($reset + 60) -and
        $Now -ge $State.SuppressUntil -and $Now -ge ($State.LastAttempt + 60)) {
        return [int][math]::Min(5, $reset + 60 - $Now)
    }
    $Schedule.Reset = 0L
    return 60
}

function Resolve-PingCodexExecutable {
    # 与 limitping 的 Windows 路径优先级一致，但运行时不依赖 limitping。
    $root = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    $paths = @((Join-Path $root 'codex.exe'))
    if (Test-Path -LiteralPath $root) {
        $paths += @(Get-ChildItem -LiteralPath $root -Directory | ForEach-Object { Join-Path $_.FullName 'codex.exe' })
    }
    $candidate = $paths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Get-Item | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
    if ($null -ne $candidate) { return $candidate.FullName }
    return (Resolve-CodexExecutable)
}

function Get-PingWorkingDirectory {
    $directory = Join-Path $script:PingLocalRoot 'ping-workspace'
    [void][IO.Directory]::CreateDirectory($directory)
    return $directory
}

function Invoke-PingLoginCheck {
    param($Configuration)
    if (-not $Configuration.Valid -or -not (Test-Path -LiteralPath $Configuration.CodexHome -PathType Container)) {
        return '未配置登录环境'
    }
    $probe = [CodexAppServerClient]::new()
    try {
        $probe.StartWithHome((Resolve-PingCodexExecutable), (Get-PingWorkingDirectory), $Configuration.CodexHome)
        $probe.SendLine((New-JsonLine -Id 1 -Method 'initialize' -Params @{
            clientInfo = @{ name = 'codex-pet-quota-auth-check'; version = '1.1.0' }
            capabilities = @{ experimentalApi = $true }
        }))
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ([DateTime]::UtcNow -lt $deadline -and $probe.IsRunning) {
            $line = $null
            while ($probe.TryDequeue([ref]$line)) {
                try { $message = $line | ConvertFrom-Json } catch { continue }
                if ($null -ne $message.error) {
                    $errorText = [string]$message.error.message
                    if ($errorText -match '(?i)401|unauthorized|not logged in|authentication|refresh token|sign in|login required') {
                        return '需要重新登录'
                    }
                    return '额度访问未验证：服务或网络错误'
                }
                if ($message.id -eq 1) {
                    $probe.SendLine((New-JsonLine -Id 2 -Method 'account/rateLimits/read' -OmitParams))
                }
                elseif ($message.id -eq 2) {
                    $view = ConvertTo-QuotaViewModel $message
                    if ($view.FiveHour.Available -or $view.Weekly.Available) { return '额度访问验证通过（未发送模型请求）' }
                    return '已收到响应，但额度窗口不可用'
                }
            }
            Start-Sleep -Milliseconds 50
        }
        return '额度访问未验证：超时或进程退出'
    }
    catch { return '额度访问未验证：启动或通信错误' }
    finally { $probe.Dispose() }
}

function Show-PingSettings {
    $configuration = Get-PingConfiguration
    Write-Host '可选：空闲 5H 窗口自动 ping（内置 limitping 单回合 helper / Codex CLI）'
    Write-Host "启用：$($configuration.Enabled)；配置正常：$($configuration.Valid)"
    Write-Host "登录环境：$($configuration.CodexHome)"
    Write-Host "固定工作目录：$($configuration.WorkingDirectory)"
    Write-Host "模型：$($configuration.Model)；用量：每次一个 ok 请求，会消耗少量额度。"
    Write-Host '启用后，额度读取与 ping 使用此同一登录环境；请确认是你要显示的账户。'
    Write-Host '1 启用（先只读验证） / 2 关闭 / 3 检查登录（不 ping）'
    Write-Host '4 登录独立环境 / 5 使用已有 CODEX_HOME / 6 查看 ping 状态 / 7 初始化固定工作目录（不发消息） / Enter 退出'
    switch (Read-Host '选择') {
        '1' {
            $status = Invoke-PingLoginCheck $configuration
            Write-Host $status
            if ($status -eq '额度访问验证通过（未发送模型请求）') {
                $configuration.Enabled = $true; Save-PingConfiguration $configuration
                Write-Host '已启用。请停止并重新启动悬浮窗后生效。'
            }
        }
        '2' {
            $configuration.Enabled = $false; Save-PingConfiguration $configuration
            Write-Host '已关闭。运行中的实例在下一次计时器检查时停止 ping；重启后恢复默认额度来源。'
        }
        '3' { Write-Host (Invoke-PingLoginCheck $configuration) }
        '4' {
            [void][IO.Directory]::CreateDirectory($configuration.CodexHome)
            # 仅修改当前进程环境；不改系统 CODEX_HOME，不复制登录信息。
            $previousHome = $env:CODEX_HOME
            try {
                $env:CODEX_HOME = $configuration.CodexHome
                & (Resolve-PingCodexExecutable) login
                if ($LASTEXITCODE -eq 0) { Save-PingConfiguration $configuration }
            }
            finally { $env:CODEX_HOME = $previousHome }
            Write-Host (Invoke-PingLoginCheck $configuration)
        }
        '5' {
            $homePath = Read-Host '现有 CODEX_HOME 绝对目录（仅保存路径，不复制凭证）'
            if ([IO.Path]::IsPathRooted($homePath) -and (Test-Path -LiteralPath $homePath -PathType Container)) {
                $configuration.CodexHome = [IO.Path]::GetFullPath($homePath)
                $configuration.Enabled = $false; $configuration.Valid = $true
                Save-PingConfiguration $configuration
                Write-Host (Invoke-PingLoginCheck $configuration)
                Write-Host '路径已保存，保持关闭；再次进入设置选择启用。'
            }
            else { Write-Host '请输入已有目录的绝对路径。' }
        }
        '7' {
            [void][IO.Directory]::CreateDirectory($configuration.WorkingDirectory)
            $previousHome = $env:CODEX_HOME
            Push-Location $configuration.WorkingDirectory
            try {
                $env:CODEX_HOME = $configuration.CodexHome
                Write-Host '完成 CLI 启动提示后退出即可；这里不传入消息。'
                & (Resolve-PingCodexExecutable)
            }
            finally { Pop-Location; $env:CODEX_HOME = $previousHome }
        }
        '6' {
            $state = Read-PingState
            Write-Host $state.Status
            Write-Host "请求结果：$($state.AttemptOutcome)；窗口状态：$($state.WindowStatus)"
            Write-Host "事件日志：$(Join-Path $script:PingLocalRoot 'ping-events.jsonl')"
            if ($state.LastAttempt -gt 0) { Write-Host ('上次尝试：' + [DateTimeOffset]::FromUnixTimeSeconds($state.LastAttempt).ToLocalTime()) }
        }
    }
}

function Initialize-QuotaPing {
    $script:PingConfiguration = Get-PingConfiguration
    $script:PingState = Read-PingState
    $script:PingTransport = $null
    $script:PingStartedAt = 0L
    $script:PingNextPoll = 0L
    $script:PingReadSchedule = New-PingReadSchedule
    $script:PingRuntimeEnabled = $script:PingConfiguration.Enabled -and $script:PingConfiguration.Valid -and $script:PingState.Valid
    if ($script:PingRuntimeEnabled) {
        try {
            if (-not (Test-Path -LiteralPath $script:PingConfiguration.CodexHome -PathType Container)) { throw 'missing profile' }
            [void][IO.Directory]::CreateDirectory($script:PingConfiguration.WorkingDirectory)
            [void](Resolve-PingHelper)
            if ($null -eq ('CodexPingTransport' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'CodexPingTransport.cs') }
            Write-PingEvent 'monitor_enabled' 'helper_ready'
        }
        catch { $script:PingRuntimeEnabled = $false; Write-PingEvent 'monitor_paused' 'initialization_failed' }
    }
}

function Stop-QuotaPing {
    if ($null -ne $script:PingTransport) { $script:PingTransport.Dispose(); $script:PingTransport = $null }
    if ($script:PingStartedAt -gt 0 -and $script:PingState.AttemptOutcome -eq 'running') {
        $script:PingState.AttemptOutcome = 'interrupted'
        $script:PingState.Status = '请求已停止；保留防重发保护'
        try { Save-PingState $script:PingState } catch { }
        Write-PingEvent 'attempt_finished' 'interrupted' $script:PingState.AttemptId
    }
    $script:PingStartedAt = 0L
}

function Start-QuotaPingAttempt {
    param([ValidateSet('automatic','manual_validation')][string]$Trigger = 'automatic')
    if (-not $script:PingRuntimeEnabled -or $script:PingStartedAt -gt 0) { throw 'ping not ready' }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try {
        $script:PingState.AttemptId = [Guid]::NewGuid().ToString('N')
        $script:PingState.LastAttempt = $now
        $script:PingState.SuppressUntil = $now + 18000
        $script:PingState.AttemptOutcome = 'running'
        $script:PingState.WindowStatus = 'unconfirmed'
        $script:PingState.Trigger = $Trigger
        $script:PingState.Status = '已预留一次 ping，正在启动 helper'
        $script:PingState.Home = $script:PingConfiguration.CodexHome
        Save-PingState $script:PingState
        Write-PingEvent 'attempt_started' $Trigger $script:PingState.AttemptId
        $script:PingStartedAt = $now
        $script:PingTransport = [CodexPingTransport]::new()
        $script:PingTransport.Start((Resolve-PingHelper), $script:PingConfiguration.WorkingDirectory,
            $script:PingConfiguration.CodexHome, $script:PingConfiguration.Model)
        Write-PingEvent 'helper_started' 'limitping_provider' $script:PingState.AttemptId
    }
    catch {
        $script:PingState.AttemptOutcome = 'start_failed'
        $script:PingState.Status = 'helper 启动或状态保存失败；自动 ping 已暂停'
        Stop-QuotaPing
        $script:PingRuntimeEnabled = $false
        try { Save-PingState $script:PingState } catch { }
        Write-PingEvent 'attempt_finished' 'start_failed' $script:PingState.AttemptId
    }
}

function Update-QuotaPingProcess {
    if (-not $script:PingRuntimeEnabled) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    if ($now -lt $script:PingNextPoll) { return }
    $script:PingNextPoll = $now + 1
    $current = Get-PingConfiguration
    if (-not $current.Enabled -or -not $current.Valid -or $current.CodexHome -ne $script:PingConfiguration.CodexHome -or
        $current.Model -ne $script:PingConfiguration.Model -or $current.WorkingDirectory -ne $script:PingConfiguration.WorkingDirectory) {
        Stop-QuotaPing
        $script:PingRuntimeEnabled = $false
        Write-PingEvent 'monitor_paused' 'configuration_changed'
        return
    }
    if ($script:PingStartedAt -eq 0) { return }
    try {
        if (-not $script:PingTransport.IsRunning) {
            if ($script:PingTransport.Completed -and $script:PingTransport.ExitCode -eq 0) {
                $outcome = 'completed'
                $script:PingState.Status = '本次 CLI 会话已完成并收到回复'
            }
            else {
                $outcome = $script:PingTransport.ResultCategory
                if (-not $outcome) { $outcome = 'unverified_exit' }
                $script:PingState.Status = '本次 CLI 请求未成功：' + $outcome
            }
        }
        elseif ($now -ge $script:PingStartedAt + 120) {
            $outcome = 'watchdog_timeout'
            $script:PingState.Status = 'helper 超时；保留防重发保护'
        }
        else { return }
        $script:PingState.AttemptOutcome = $outcome
        Write-PingEvent 'attempt_finished' $outcome $script:PingState.AttemptId
        Stop-QuotaPing
        Save-PingState $script:PingState
        if ($outcome -eq 'authentication') { $script:PingRuntimeEnabled = $false }
        $script:NextReadAt = [DateTime]::UtcNow
    }
    catch {
        $script:PingState.AttemptOutcome = 'observation_failed'
        $script:PingState.Status = '结果观察失败；自动 ping 已暂停'
        Stop-QuotaPing
        $script:PingRuntimeEnabled = $false
        try { Save-PingState $script:PingState } catch { }
        Write-PingEvent 'attempt_finished' 'observation_failed' $script:PingState.AttemptId
    }
}

function Update-QuotaPingSnapshot {
    param($Response)
    if (-not $script:PingRuntimeEnabled) { return }
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $busy = $script:PingStartedAt -gt 0
    $decision = Get-WindowPingDecision $Response $script:PingState $now $true $busy
    Write-PingEvent 'quota_decision' $decision.Reason $script:PingState.AttemptId
    if ($decision.Active -and $script:PingState.LastAttempt -gt 0 -and
        $script:PingState.Home -eq $script:PingConfiguration.CodexHome -and -not $busy) {
        $windowStatus = 'active_unattributed'
        if ($script:PingState.AttemptOutcome -eq 'completed' -and $script:PingState.Trigger -eq 'automatic' -and
            [math]::Abs($decision.Reset - ($script:PingState.LastAttempt + 18000)) -le 180) { $windowStatus = 'active_after_completed_ping' }
        if ($script:PingState.SuppressUntil -ne $decision.Reset -or $script:PingState.WindowStatus -ne $windowStatus) {
            $script:PingState.SuppressUntil = $decision.Reset
            $script:PingState.WindowStatus = $windowStatus
            # 保留 AttemptOutcome 和 Status；别的请求激活窗口不洗掉本次失败。
            try { Save-PingState $script:PingState } catch { $script:PingRuntimeEnabled = $false }
            Write-PingEvent 'window_observed' $windowStatus $script:PingState.AttemptId
        }
    }
    if ($null -eq $script:PingReadSchedule) { $script:PingReadSchedule = New-PingReadSchedule }
    $delay = Get-PingReadDelay $decision $script:PingState $script:PingReadSchedule $now
    $script:NextReadAt = [DateTime]::UtcNow.AddSeconds($delay)
    Write-PingEvent 'read_scheduled' ('delay_' + $delay + 's') $script:PingState.AttemptId
    if ($decision.Send) { Start-QuotaPingAttempt }
}