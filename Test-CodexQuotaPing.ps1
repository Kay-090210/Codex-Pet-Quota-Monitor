#requires -version 5.1
# 纯离线策略测试：不启动 CLI/UI、不读取认证文件、不发送模型请求。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$mainPath = Join-Path $PSScriptRoot 'CodexPetQuota.ps1'
$modulePath = Join-Path $PSScriptRoot 'CodexQuotaPing.ps1'
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw '主程序语法检查失败' }
$names = @('Get-ObjectPropertyValue', 'Get-RateLimitSnapshot', 'Select-RateLimitWindow',
    'ConvertTo-QuotaMetric', 'ConvertTo-CreditMetric', 'ConvertTo-QuotaViewModel')
foreach ($name in $names) {
    $function = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) |
        Where-Object Name -eq $name | Select-Object -First 1
    if ($null -eq $function) { throw "缺少函数：$name" }
    . ([scriptblock]::Create($function.Extent.Text))
}
[void][Management.Automation.Language.Parser]::ParseFile($modulePath, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'ping 模块语法检查失败' }
. $modulePath
$script:TestCount = 0
function Assert-PingEqual {
    param([string]$Name, $Actual, $Expected)
    if ($Actual -cne $Expected) { throw "$Name : expected [$Expected], got [$Actual]" }
    $script:TestCount++
    Write-Output "PASS $Name"
}
function New-QuotaFixture {
    param([long]$Now = 1800000000, $Used = 0, $Weekly = 10, $Reset = ($Now + 18000))
    return [pscustomobject]@{ result = [pscustomobject]@{ rateLimitsByLimitId = [pscustomobject]@{
        codex = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = $Used; windowDurationMins = 300; resetsAt = $Reset }
            secondary = [pscustomobject]@{ usedPercent = $Weekly; windowDurationMins = 10080; resetsAt = ($Now + 604800) }
        }
    } } }
}
function New-PrimedState {
    param([long]$Now = 1800000000)
    $state = New-PingState
    [void](Get-WindowPingDecision (New-QuotaFixture -Now ($Now - 60)) $state ($Now - 60) $true)
    return $state
}
$verificationRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'verification'))
$testRoot = [IO.Path]::GetFullPath((Join-Path $verificationRoot ('ping-tests-' + [guid]::NewGuid().ToString('N'))))
if (-not $testRoot.StartsWith($verificationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw '测试路径超出 verification'
}
[void][IO.Directory]::CreateDirectory($testRoot)
$script:PingLocalRoot = $testRoot
$script:PingConfigPath = Join-Path $testRoot 'config.json'
$script:PingStatePath = Join-Path $testRoot 'state.json'
try {
    $now = 1800000000L
    $configuration = Get-PingConfiguration
    Assert-PingEqual '默认关闭' $configuration.Enabled $false
    Assert-PingEqual '默认配置有效' $configuration.Valid $true
    Assert-PingEqual '默认使用项目独立 home' $configuration.CodexHome (Join-Path $testRoot 'codex-home')
    Assert-PingEqual '默认不依赖 limitping 目录' ($configuration.CodexHome -match '(?i)limitping') $false
    Assert-PingEqual '禁用不发送' (Get-WindowPingDecision (New-QuotaFixture) (New-PrimedState) $now $false).Send $false
    $state = New-PingState
    Assert-PingEqual '首个空闲样本等待确认' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Reason 'confirm-next-sample'
    Assert-PingEqual '双样本 reset 随时钟滑动触发' (Get-WindowPingDecision (New-QuotaFixture -Now ($now + 60)) $state ($now + 60) $true).Send $true
    $state = New-PingState
    [void](Get-WindowPingDecision (New-QuotaFixture) $state $now $true)
    Assert-PingEqual '固定 reset 不触发' (Get-WindowPingDecision (New-QuotaFixture -Now ($now + 60) -Reset ($now + 18000)) $state ($now + 60) $true).Send $false
    $fixture = New-QuotaFixture -Used 0.1
    Assert-PingEqual '显示四舍五入为100%' (ConvertTo-QuotaViewModel $fixture).FiveHour.RemainingPercent 100
    Assert-PingEqual '原始已用非零不触发' (Get-WindowPingDecision $fixture (New-PrimedState) $now $true).Send $false
    foreach ($weekly in @(99, 100)) {
        Assert-PingEqual "周已用 $weekly 阻止" (Get-WindowPingDecision (New-QuotaFixture -Weekly $weekly) (New-PrimedState) $now $true).Reason 'weekly-guard'
    }
    Assert-PingEqual '忙碌不发送' (Get-WindowPingDecision (New-QuotaFixture) (New-PrimedState) $now $true $true).Reason 'busy'
    $state = New-PrimedState; $state.LastAttempt = $now - 59
    Assert-PingEqual '59秒仍冷却' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Reason 'cooldown'
    $state = New-PrimedState; $state.LastAttempt = $now - 60
    Assert-PingEqual '60秒冷却边界允许' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Send $true
    $state = New-PrimedState; $state.SuppressUntil = $now + 1
    Assert-PingEqual '持久抑制期间不发送' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Reason 'cooldown'
    $state = New-PrimedState; $state.LastAttempt = $now + 100
    Assert-PingEqual '时钟倒退至上次发送之前不发送' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Send $false
    $state = New-PrimedState; $state.PreviousAt = $now + 60; $state.PreviousReset = $now + 18060
    Assert-PingEqual '样本时间倒退不发送' (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Send $false
    foreach ($elapsed in @(0, 29, 151)) {
        $state = New-PingState; $state.PreviousAt = $now - $elapsed; $state.PreviousReset = $now - $elapsed + 18000
        Assert-PingEqual "样本间隔 $elapsed 秒不触发" (Get-WindowPingDecision (New-QuotaFixture) $state $now $true).Send $false
    }
    foreach ($bad in @($null, [pscustomobject]@{}, [pscustomobject]@{ error = [pscustomobject]@{ code = 401 } })) {
        Assert-PingEqual '空值畸形或RPC错误关闭发送' (Get-WindowPingDecision $bad (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    }
    foreach ($bad in @($null, 'bad', 'NaN', 'Infinity', $true, -1, 101)) {
        Assert-PingEqual "非法原始已用量 [$bad]" (Get-WindowPingDecision (New-QuotaFixture -Used $bad) (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    }
    foreach ($reset in @($null, 'bad', 'NaN', -1, 0, 1800018000.5, 99999999999999)) {
        Assert-PingEqual "非法重置时间 [$reset]" (Get-WindowPingDecision (New-QuotaFixture -Reset $reset) (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    }
    foreach ($reset in @(($now - 1), $now, ($now + 17900), ($now + 18100))) {
        Assert-PingEqual "已过期或非候选重置 [$reset]" (Get-WindowPingDecision (New-QuotaFixture -Reset $reset) (New-PrimedState) $now $true).Send $false
    }
    $fixture = New-QuotaFixture
    $fixture.result | Add-Member rateLimits $fixture.result.rateLimitsByLimitId.codex
    $fixture.result.rateLimitsByLimitId = [pscustomobject]@{ other = $fixture.result.rateLimits }
    Assert-PingEqual '未知 bucket 不回退旧字段' (Get-WindowPingDecision $fixture (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    $fixture = New-QuotaFixture
    $fixture.result.rateLimitsByLimitId.codex.secondary = $null
    Assert-PingEqual '缺少周窗口停止发送' (Get-WindowPingDecision $fixture (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    $fixture = New-QuotaFixture
    $fixture.result.rateLimitsByLimitId.codex.primary.windowDurationMins = 299
    Assert-PingEqual '非精确5H窗口停止发送' (Get-WindowPingDecision $fixture (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    $fixture = New-QuotaFixture
    $fixture.result.rateLimitsByLimitId.codex.primary.PSObject.Properties.Remove('resetsAt')
    Assert-PingEqual '缺少重置字段停止发送' (Get-WindowPingDecision $fixture (New-PrimedState) $now $true).Reason 'invalid-snapshot'
    $legacy = [pscustomobject]@{ result = [pscustomobject]@{ rateLimits = (New-QuotaFixture).result.rateLimitsByLimitId.codex } }
    Assert-PingEqual '只有旧字段时兼容处理' (Get-WindowPingDecision $legacy (New-PrimedState) $now $true).Send $true
    # 查询调度的纯离线边界，不启动真实服务、不视为联网验收。
    $state = New-PingState; $schedule = New-PingReadSchedule
    $d = Get-WindowPingDecision (New-QuotaFixture -Used 10 -Reset ($now+20)) $state $now $true
    Assert-PingEqual '临近窗口对齐reset后3秒' (Get-PingReadDelay $d $state $schedule $now) 23
    $d = Get-WindowPingDecision (New-QuotaFixture -Used 10 -Reset ($now+20)) $state ($now+23) $true
    Assert-PingEqual '旧reset过期且响应仍旧时5秒复查' (Get-PingReadDelay $d $state $schedule ($now+23)) 5
    Assert-PingEqual '复查期限前一秒只等1秒' (Get-PingReadDelay $d $state $schedule ($now+79)) 1
    Assert-PingEqual 'reset后60秒结束快轮询' (Get-PingReadDelay $d $state $schedule ($now+80)) 60
    Assert-PingEqual '过期快轮询不会自行重启' (Get-PingReadDelay $d $state $schedule ($now+81)) 60
    $schedule = New-PingReadSchedule
    Assert-PingEqual '启动只见过期reset不快轮询' (Get-PingReadDelay $d $state $schedule ($now+23)) 60
    $d = Get-WindowPingDecision (New-QuotaFixture -Used 10 -Reset ($now+3600)) $state $now $true
    Assert-PingEqual '远离reset保持60秒' (Get-PingReadDelay $d $state (New-PingReadSchedule) $now) 60
    $state.SuppressUntil=$now+100
    $d = Get-WindowPingDecision (New-QuotaFixture -Used 10 -Reset ($now+20)) $state $now $true
    Assert-PingEqual '额外抑制期覆盖reset时不加速' (Get-PingReadDelay $d $state (New-PingReadSchedule) $now) 60
    $state.SuppressUntil=$now+20
    Assert-PingEqual '抑制期随旧窗口结束仍安排边界读取' (Get-PingReadDelay $d $state (New-PingReadSchedule) $now) 23
    foreach ($reason in @('disabled','invalid-snapshot','weekly-guard','busy')) {
        $schedule=New-PingReadSchedule; $schedule.Reset=$now-3
        $blocked=[pscustomobject]@{Reason=$reason;Reset=$now-3;Send=$false}
        Assert-PingEqual "$reason 不加速" (Get-PingReadDelay $blocked (New-PingState) $schedule $now) 60
        Assert-PingEqual "$reason 清除查询锚点" $schedule.Reset 0L
    }
    $schedule=New-PingReadSchedule; $schedule.LastAt=$now+1; $schedule.Reset=$now-3
    Assert-PingEqual '时钟倒退取消快速查询' (Get-PingReadDelay $d $state $schedule $now) 60
    Assert-PingEqual '时钟倒退清除锚点' $schedule.Reset 0L
    $state=New-PingState; $schedule=New-PingReadSchedule
    $d=Get-WindowPingDecision (New-QuotaFixture -Used 10 -Reset ($now+20)) $state $now $true
    [void](Get-PingReadDelay $d $state $schedule $now)
    $d=Get-WindowPingDecision (New-QuotaFixture -Now ($now+23) -Used 1 -Reset ($now+18023)) $state ($now+23) $true
    Assert-PingEqual '新活动窗口取消旧reset快速查询' (Get-PingReadDelay $d $state $schedule ($now+23)) 60
    $state=New-PingState; $schedule=New-PingReadSchedule
    $d=Get-WindowPingDecision (New-QuotaFixture) $state $now $true
    Assert-PingEqual '首候选等待33秒而非每5秒覆盖' (Get-PingReadDelay $d $state $schedule $now) 33
    $d=Get-WindowPingDecision (New-QuotaFixture -Now ($now+33)) $state ($now+33) $true
    Assert-PingEqual '33秒滚动候选允许发送' $d.Send $true
    Assert-PingEqual '发送后恢复常规读取' (Get-PingReadDelay $d $state $schedule ($now+33)) 60
    foreach($kind in @('fixed','used','invalid')) {
        $state=New-PingState; $schedule=New-PingReadSchedule
        $d=Get-WindowPingDecision (New-QuotaFixture) $state $now $true
        [void](Get-PingReadDelay $d $state $schedule $now)
        $f=if($kind -eq 'fixed'){New-QuotaFixture -Now ($now+33) -Reset ($now+18000)}
           elseif($kind -eq 'used'){New-QuotaFixture -Now ($now+33) -Used 0.1}
           else{$null}
        $d=Get-WindowPingDecision $f $state ($now+33) $true
        Assert-PingEqual "33秒确认遇到$kind 不发送" $d.Send $false
        Assert-PingEqual "33秒确认遇到$kind 恢复常规读取" (Get-PingReadDelay $d $state $schedule ($now+33)) 60
        Assert-PingEqual "33秒确认遇到$kind 清除候选" $state.PreviousAt 0L
    }
    $configuration.Enabled = $true
    Save-PingConfiguration $configuration
    Assert-PingEqual '配置保存与加载' (Get-PingConfiguration).Enabled $true
    '{broken' | Set-Content -LiteralPath $script:PingConfigPath -Encoding UTF8
    Assert-PingEqual '损坏配置默认关闭' (Get-PingConfiguration).Enabled $false
    Assert-PingEqual '损坏配置标记异常' (Get-PingConfiguration).Valid $false
    $state = New-PrimedState; $state.LastAttempt = $now - 1; $state.SuppressUntil = $now + 3600
    Save-PingState $state
    $restored = Read-PingState
    Assert-PingEqual '发送时间持久化' $restored.LastAttempt ($now - 1)
    Assert-PingEqual '抑制时间持久化' $restored.SuppressUntil ($now + 3600)
    Assert-PingEqual '重启不沿用待确认样本' $restored.PreviousAt 0L
    Save-PingState $state
    Assert-PingEqual '原子替换后状态有效' (Read-PingState).Valid $true
    foreach ($broken in @('{broken', '{}', '{"LastAttempt":-1,"SuppressUntil":0}', '{"LastAttempt":"bad","SuppressUntil":0}')) {
        $broken | Set-Content -LiteralPath $script:PingStatePath -Encoding UTF8
        $restored = Read-PingState
        Assert-PingEqual '损坏持久状态异常' $restored.Valid $false
        Assert-PingEqual '损坏持久状态停止发送' (Get-WindowPingDecision (New-QuotaFixture) $restored $now $true).Send $false
    }
    # 在独立测试进程中用无 I/O 的传输替身覆盖运行调度，不启动真实进程。
    Add-Type -TypeDefinition @"
public sealed class CodexPingTransport : System.IDisposable {
 public static int Starts;
 public bool IsRunning;
 public string ErrorKind = "";
 public void Start(string exe, string work, string home, string model) { Starts++; IsRunning=true; }
 public void Stop() { IsRunning=false; }
 public void Dispose() { Stop(); }
}
"@
    function Resolve-PingHelper { return 'fixture.exe' }
    $liveNow = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $script:PingConfiguration = [pscustomobject]@{ Enabled=$true; Valid=$true; CodexHome=$testRoot; Model='fixture'; WorkingDirectory=$testRoot }
    Save-PingConfiguration $script:PingConfiguration
    $script:PingRuntimeEnabled = $true
    $script:PingState = New-PingState
    $script:PingReadSchedule = New-PingReadSchedule
    $script:PingStartedAt = 0L; $script:PingTransport=$null
    $beforeSchedule = [DateTime]::UtcNow
    Update-QuotaPingSnapshot (New-QuotaFixture -Now $liveNow)
    Assert-PingEqual '生产快照入口首候选不发送' ([CodexPingTransport]::Starts) 0
    $scheduledSeconds = ($script:NextReadAt - $beforeSchedule).TotalSeconds
    Assert-PingEqual '生产快照入口应用33秒调度' ($scheduledSeconds -ge 33 -and $scheduledSeconds -lt 35) $true
    $script:PingState = New-PrimedState -Now $liveNow
    Update-QuotaPingSnapshot (New-QuotaFixture -Now $liveNow)
    Assert-PingEqual '运行调度只启动一次' ([CodexPingTransport]::Starts) 1
    Assert-PingEqual '启动前保存防重发状态' ((Read-PingState).LastAttempt -gt 0) $true
    Assert-PingEqual '失败不确定性保护五小时' ((Read-PingState).SuppressUntil - (Read-PingState).LastAttempt) 18000L
    Update-QuotaPingSnapshot (New-QuotaFixture -Now $liveNow)
    Assert-PingEqual '进行中的请求不重入' ([CodexPingTransport]::Starts) 1
    Stop-QuotaPing
    Assert-PingEqual 'Stop 不删除固定工作目录' (Test-Path -LiteralPath $testRoot) $true
    $script:PingState=Read-PingState
    Update-QuotaPingSnapshot (New-QuotaFixture -Now $liveNow)
    Assert-PingEqual '重新读取状态仍抑制重发' ([CodexPingTransport]::Starts) 1
    $script:PingState.Status='CLI 超时；保留防重发保护'
    $script:PingState.AttemptOutcome='timeout'
    Update-QuotaPingSnapshot (New-QuotaFixture -Now $liveNow -Used 1 -Reset ($liveNow+17000))
    Assert-PingEqual '后来的窗口不覆盖超时结果' $script:PingState.AttemptOutcome 'timeout'
    Assert-PingEqual '后来的窗口不覆盖超时状态' $script:PingState.Status 'CLI 超时；保留防重发保护'
    Assert-PingEqual '后来的窗口不归因于失败ping' $script:PingState.WindowStatus 'active_unattributed'
    Assert-PingEqual '有追加事件日志' (Test-Path (Join-Path $script:PingLocalRoot 'ping-events.jsonl')) $true
    $script:PingConfiguration.Enabled=$false
    Save-PingConfiguration $script:PingConfiguration
    $script:PingNextPoll=0L
    Update-QuotaPingProcess
    Assert-PingEqual '设置关闭后停止调度' $script:PingRuntimeEnabled $false
    Write-Output "全部 ping 离线测试通过：$script:TestCount 项。未调用 CLI、认证服务或模型。"
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith($verificationRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^ping-tests-[a-f0-9]{32}$') {
        if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
    }
    else { throw '测试收尾路径校验失败，未清理' }
}
