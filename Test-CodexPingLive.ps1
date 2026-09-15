#requires -version 5.1
# 显式真实业务验收。会发送一次 ok 并消耗额度；绝不纳入离线测试或普通启动。
[CmdletBinding()]
param([switch]$SendPing, [switch]$VerifyLastAttempt)
$ErrorActionPreference = 'Stop'
if (-not $SendPing -and -not $VerifyLastAttempt) { throw '真实测试会发送一条消息；请显式指定 -SendPing。' }

$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'CodexPetQuota.ps1'), [ref]$null, [ref]$null)
foreach ($name in @('Get-ObjectPropertyValue','Get-RateLimitSnapshot','Select-RateLimitWindow',
    'ConvertTo-QuotaMetric','ConvertTo-CreditMetric','ConvertTo-QuotaViewModel','Resolve-CodexExecutable','New-JsonLine')) {
    $f = $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]}, $true) |
        Where-Object Name -eq $name | Select-Object -First 1
    . ([scriptblock]::Create($f.Extent.Text))
}
$native = $ast.Find({param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.VariablePath.UserPath -eq 'nativeSource'}, $true)
Add-Type -TypeDefinition $native.Right.Expression.Value
. (Join-Path $PSScriptRoot 'CodexQuotaPing.ps1')

function Read-LiveSnapshot {
    $client = [CodexAppServerClient]::new()
    try {
        $client.StartWithHome((Resolve-PingCodexExecutable), $PSScriptRoot, $script:PingConfiguration.CodexHome)
        $client.SendLine((New-JsonLine -Id 1 -Method 'initialize' -Params @{
            clientInfo=@{name='codex-pet-ping-live-test';version='1.1.0'};capabilities=@{experimentalApi=$true}
        }))
        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        while ($client.IsRunning -and [DateTime]::UtcNow -lt $deadline) {
            $line = $null
            while ($client.TryDequeue([ref]$line)) {
                try { $message = $line | ConvertFrom-Json } catch { continue }
                if ($message.error) { throw '真实额度读取失败（未记录原始响应）' }
                if ($message.id -eq 1) { $client.SendLine((New-JsonLine -Id 2 -Method 'account/rateLimits/read' -OmitParams)) }
                elseif ($message.id -eq 2) { return $message }
            }
            Start-Sleep -Milliseconds 50
        }
        throw '真实额度读取超时'
    }
    finally { $client.Dispose() }
}

# 与正常监视器互斥，避免并发 ping 或覆盖状态。
$created = $false
$mutex = [Threading.Mutex]::new($true, 'Local\CodexPetQuotaOverlay.SingleInstance', [ref]$created)
if (-not $created) { $mutex.Dispose(); throw '请先停止监视器，再运行真实验收。' }
$report = [ordered]@{ StartedAt=[DateTimeOffset]::Now.ToString('o'); Completed=$false; ActiveBefore=$null; WindowResult='unverified'; SessionVerified=$false }
try {
    Initialize-QuotaPing
    if (-not $script:PingRuntimeEnabled) { throw 'ping 初始化未就绪' }
    if ($VerifyLastAttempt) {
        $previous = Get-ChildItem (Join-Path $PSScriptRoot 'verification') -Filter 'ping-live-*.json' |
            Sort-Object LastWriteTime -Descending | ForEach-Object {
                $r = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                if ($r.AttemptId -eq $script:PingState.AttemptId) { $r }
            } | Select-Object -First 1
        if ($null -eq $previous) { throw '未找到本次尝试的验收记录' }
        $report.ActiveBefore = $previous.ActiveBefore
        $report.VerificationOnly = $true
        $beforeReset = $previous.BeforeReset
    }
    else {
    $before = Read-LiveSnapshot
    $snapshot = Get-RateLimitSnapshot $before
    $five = Select-RateLimitWindow $snapshot 300
    $week = Select-RateLimitWindow $snapshot 10080
    $fiveUsed = Get-PingNumber $five.usedPercent; $weekUsed = Get-PingNumber $week.usedPercent
    $report.Precheck = [ordered]@{ FivePresent=($null -ne $five); WeekPresent=($null -ne $week); FiveValuePresent=($null -ne $fiveUsed); WeekValuePresent=($null -ne $weekUsed); FiveExhausted=($fiveUsed -ge 100); WeekGuard=($weekUsed -ge 99) }
    if ($null -eq $fiveUsed -or $null -eq $weekUsed -or $weekUsed -ge 99) { throw '当前额度不适合执行真实测试' }
    $beforeReset = [long]$five.resetsAt
    $report.BeforeReset = $beforeReset
    $report.ActiveBefore = ($beforeReset - [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -lt 17970 -or $fiveUsed -gt 0)
    Write-Output ('LIVE quota precheck passed; activeBefore=' + $report.ActiveBefore)
    Start-QuotaPingAttempt -Trigger manual_validation
    $deadline = [DateTime]::UtcNow.AddSeconds(130)
    while ($script:PingStartedAt -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        Update-QuotaPingProcess
        Start-Sleep -Milliseconds 200
    }
    }
    $report.AttemptId = $script:PingState.AttemptId
    $report.Outcome = $script:PingState.AttemptOutcome
    if ($script:PingState.AttemptOutcome -ne 'completed') { throw ('真实 CLI 回合未通过：' + $script:PingState.AttemptOutcome) }
    $report.Completed = $true

    # 再独立检查新会话，不能仅信 helper 的退出码或自身测试替身。
    $sessionRoot = Join-Path $script:PingConfiguration.CodexHome 'sessions'
    foreach ($day in @([DateTime]::Now, [DateTime]::Now.AddDays(-1))) {
        $directory = Join-Path $sessionRoot $day.ToString('yyyy/MM/dd')
        foreach ($file in @(Get-ChildItem -LiteralPath $directory -Filter '*.jsonl' -File -ErrorAction SilentlyContinue)) {
            if ($file.CreationTimeUtc -lt [DateTimeOffset]::FromUnixTimeSeconds($script:PingState.LastAttempt).UtcDateTime.AddSeconds(-2)) { continue }
            $promptFound = $false; $replyFound = $false; $failed = $false; $matchingDirectory = $false
            foreach ($line in [IO.File]::ReadLines($file.FullName)) {
                try { $item = $line | ConvertFrom-Json } catch { continue }
                if ($item.type -eq 'session_meta') {
                    $matchingDirectory = ([string]$item.payload.cwd).Replace('\\?\','').TrimEnd('\','/') -eq $script:PingConfiguration.WorkingDirectory.TrimEnd('\','/')
                }
                if ($item.type -eq 'response_item' -and $item.payload.role -eq 'user') {
                    foreach ($content in $item.payload.content) { if (([string]$content.text).Trim() -eq 'ok') { $promptFound = $true } }
                }
                if ($item.type -eq 'event_msg' -and $item.payload.type -eq 'task_complete') {
                    if ($item.payload.error) { $failed = $true }
                    if (-not [string]::IsNullOrWhiteSpace([string]$item.payload.last_agent_message)) { $replyFound = $true }
                }
            }
            if ($matchingDirectory -and $promptFound -and $replyFound -and -not $failed) {
                $report.SessionVerified = $true
                $report.SessionFile = $file.FullName
                break
            }
        }
    }
    if (-not $report.SessionVerified) { throw 'helper 报告完成，但独立会话核验未通过' }
    $after = Read-LiveSnapshot
    $afterFive = Select-RateLimitWindow (Get-RateLimitSnapshot $after) 300
    if ($report.ActiveBefore) {
        $report.WindowResult = if ($null -eq $beforeReset) { 'existing_window_no_before_reset_record' } elseif ([long]$afterFive.resetsAt -eq $beforeReset) { 'existing_window_unchanged' } else { 'existing_window_changed_unattributed' }
    }
    else {
        $report.WindowResult = if ([math]::Abs([long]$afterFive.resetsAt - ($script:PingState.LastAttempt + 18000)) -le 180) { 'new_window_observed' } else { 'activation_unconfirmed' }
    }
    Update-QuotaPingSnapshot $after
    Write-Output ('LIVE completed=True sessionVerified=True windowResult=' + $report.WindowResult)
}
finally {
    Stop-QuotaPing
    $report.FinishedAt = [DateTimeOffset]::Now.ToString('o')
    $directory = Join-Path $PSScriptRoot 'verification'
    [void][IO.Directory]::CreateDirectory($directory)
    $path = Join-Path $directory ('ping-live-' + [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '.json')
    $report | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Output ('Evidence: ' + $path)
    $mutex.ReleaseMutex(); $mutex.Dispose()
}
