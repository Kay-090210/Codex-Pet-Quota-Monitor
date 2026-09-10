#requires -version 5.1

[CmdletBinding()]
param([switch]$SkipIntegration)

$ErrorActionPreference = 'Stop'
$mainScript = Join-Path $PSScriptRoot 'CodexPetQuota.ps1'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

if (-not (Test-Path -LiteralPath $mainScript)) {
    throw "未找到主程序：$mainScript"
}
if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
    throw "未找到 Windows PowerShell：$windowsPowerShell"
}

$tokens = $null
$errors = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) {
    $messages = $errors | ForEach-Object { $_.Message }
    throw "PowerShell 语法检查失败：`n$($messages -join "`n")"
}
Write-Output 'PASS PowerShell 语法检查'

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -SelfTest
if ($LASTEXITCODE -ne 0) {
    throw "内置测试失败，退出码：$LASTEXITCODE"
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -PositionSelfTest
if ($LASTEXITCODE -ne 0) {
    throw "定位测试失败，退出码：$LASTEXITCODE"
}

if (-not $SkipIntegration) {
    Write-Output '开始只读集成测试：account/rateLimits/read'
    & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -ProbeOnce
    if ($LASTEXITCODE -ne 0) {
        throw "限额集成测试失败，退出码：$LASTEXITCODE"
    }
    Write-Output 'PASS Codex app-server 限额读取'
}

& $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -STA -File $mainScript -UiSelfTest
if ($LASTEXITCODE -ne 0) {
    throw "WPF 渲染测试失败，退出码：$LASTEXITCODE"
}

Write-Output '全部测试通过。'
