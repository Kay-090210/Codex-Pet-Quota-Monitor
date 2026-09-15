#requires -version 5.1
# 包装层离线测试：仅验证 helper 协议、参数引用及进程树清理。
# 假 helper 通过不代表真实 Codex 可提交消息；真实联网端到端验收必须另外执行。
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$verification = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'verification'))
$root = Join-Path $verification ('transport-tests-' + [Guid]::NewGuid().ToString('N') + ' 空格')
$transport = $null; $client = $null
$oldSession = $env:CODEX_SESSION_ID; $oldThread = $env:CODEX_THREAD_ID
$oldEncoding = [Console]::InputEncoding
try {
    [void][IO.Directory]::CreateDirectory($root)
    $fixture = Join-Path $root 'fake helper.exe'
    $fixtureSource = @"
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;
public static class Fixture {
 public static int Main(string[] args) {
  if (args.Length > 0 && args[0] == "app-server") {
   var input = Console.OpenStandardInput();
   Console.WriteLine(input.ReadByte() + "," + input.ReadByte());
   return 0;
  }
  if (args.Length > 0 && args[0] == "child") { Thread.Sleep(300000); return 0; }
  if (args.Length != 7 || args[0] != "--wait-for-parent" || args[1] != "--home" ||
      args[3] != "--workdir" || args[5] != "--model") return 3;
  var handshake = Console.ReadLine(); if(handshake != "go") return handshake.Length == 3 ? 4 : 5;
  string mode = args[6];
  File.WriteAllLines("fixture-result.txt", new string[] {
    (Path.GetFullPath(args[2]).TrimEnd('\\') == Directory.GetCurrentDirectory().TrimEnd('\\')).ToString(),
    (Path.GetFullPath(args[4]) == Directory.GetCurrentDirectory()).ToString(),
    (Environment.GetEnvironmentVariable("CODEX_SESSION_ID") == "fixture-parent").ToString(),
    (Environment.GetEnvironmentVariable("CODEX_THREAD_ID") == "fixture-thread").ToString(), mode
  });
  Console.Error.Write(new string('x', 200000));
  if (mode == "cleanup") {
   var child = Process.Start(new ProcessStartInfo(Assembly.GetExecutingAssembly().Location, "child") { UseShellExecute=false, CreateNoWindow=true });
   File.WriteAllLines("fixture-pids.txt",new string[]{Process.GetCurrentProcess().Id.ToString(),child.Id.ToString()});
   Thread.Sleep(300000); return 0;
  }
  string good = "{\"completed\":true,\"dryRun\":false,\"category\":\"completed\",\"durationMs\":1}";
  if (mode.StartsWith("success") || mode == "nonzero") Console.WriteLine(good);
  else if (mode == "dry") Console.WriteLine("{\"completed\":true,\"dryRun\":true,\"category\":\"completed\",\"durationMs\":1}");
  else if (mode == "duplicate") Console.WriteLine(good + "\n" + good);
  else if (mode == "oversize") Console.WriteLine(new string('x', 200000) + good);
  else if (mode == "malformed") Console.WriteLine("{\"completed\":true}");
  else if (mode == "duplicate_field") Console.WriteLine("{\"completed\":true,\"completed\":true,\"category\":\"completed\",\"durationMs\":1}");
  else if (mode == "quoted_bool") Console.WriteLine("{\"completed\":\"true\",\"dryRun\":false,\"category\":\"completed\",\"durationMs\":1}");
  else if (mode == "reordered") Console.WriteLine("{\"durationMs\":1,\"category\":\"completed\",\"dryRun\":false,\"completed\":true}");
  else if (mode == "empty") {}
  else Console.WriteLine("{\"completed\":false,\"dryRun\":false,\"category\":\"" + mode + "\",\"durationMs\":1}");
  return mode == "nonzero" || mode == "authentication" || mode == "timeout" || mode == "cli_start" ||
      mode == "session_failed" || mode == "invalid_configuration" ? 1 : 0;
 }
}
"@
    Add-Type -TypeDefinition $fixtureSource -OutputAssembly $fixture -OutputType ConsoleApplication
    Add-Type -Path (Join-Path $PSScriptRoot 'CodexPingTransport.cs')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'CodexPetQuota.ps1'), [ref]$tokens, [ref]$errors)
    $assignment = $ast.Find({ param($n)
        $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.VariablePath.UserPath -eq 'nativeSource'
    }, $true)
    Add-Type -TypeDefinition $assignment.Right.Expression.Value

    # 强制带 BOM 的父进程输入编码，覆盖本机实际发现的 JSONRPC 首字节回归。
    [Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
    $client = [CodexAppServerClient]::new()
    $client.StartWithHome($fixture, $root, $root)
    $client.SendLine('{"id":1}')
    $line = $null; $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not $client.TryDequeue([ref]$line) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
    if ($line -ne '123,34') { throw "JSONL 首字节不是无 BOM 的 JSON：$line" }
    if ([Console]::InputEncoding.GetPreamble().Length -ne 3) { throw '未恢复父进程编码' }
    $client.Dispose(); $client = $null
    Write-Output 'PASS app-server JSONL 无 BOM 与父进程编码恢复'

    $env:CODEX_SESSION_ID = 'fixture-parent'; $env:CODEX_THREAD_ID = 'fixture-thread'
    $cases = @(
        @{ Mode = 'success "quoted" ending\'; Completed = $true; Category = 'completed' },
        @{ Mode = 'reordered'; Completed = $true; Category = 'completed' },
        @{ Mode = 'nonzero'; Completed = $false; Category = 'session_failed' },
        @{ Mode = 'dry'; Completed = $false; Category = 'session_failed' },
        @{ Mode = 'duplicate'; Completed = $false; Category = 'protocol_error' },
        @{ Mode = 'oversize'; Completed = $false; Category = 'protocol_error' },
        @{ Mode = 'malformed'; Completed = $false; Category = 'protocol_error' },
        @{ Mode = 'duplicate_field'; Completed = $false; Category = 'protocol_error' },
        @{ Mode = 'quoted_bool'; Completed = $false; Category = 'protocol_error' },
        @{ Mode = 'empty'; Completed = $false; Category = 'protocol_error' }
    )
    foreach ($kind in @('authentication', 'timeout', 'cli_start', 'session_failed', 'invalid_configuration')) {
        $cases += @{ Mode = $kind; Completed = $false; Category = $kind }
    }
    foreach ($case in $cases) {
        $transport = [CodexPingTransport]::new()
        $transport.Start($fixture, $root, ($root + '\'), $case.Mode)
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while (-not $transport.ResultReady -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
        if (-not $transport.ResultReady -or $transport.Completed -ne $case.Completed -or
            $transport.ResultCategory -ne $case.Category -or $transport.IsRunning) { throw "helper 协议判定失败：$($case.Mode) ready=$($transport.ResultReady) completed=$($transport.Completed) category=$($transport.ResultCategory) exit=$($transport.ExitCode)" }
        $result = [IO.File]::ReadAllLines((Join-Path $root 'fixture-result.txt'))
        if ($result.Length -ne 5 -or @($result[0..3] | Where-Object { $_ -ne 'True' }).Count -gt 0 -or $result[4] -cne $case.Mode) {
            throw 'helper 路径/参数引用/环境继承失败'
        }
        $rejected = $false
        try { $transport.Start($fixture, $root, $root, 'success') } catch { $rejected = $true }
        if (-not $rejected) { throw '允许同一实例重复启动' }
        $transport.Dispose(); $transport = $null
        Write-Output "PASS helper 协议 $($case.Mode)"
    }
    $transport = [CodexPingTransport]::new()
    $transport.Start($fixture, $root, $root, 'cleanup')
    $pidsPath = Join-Path $root 'fixture-pids.txt'
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while (-not (Test-Path -LiteralPath $pidsPath) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 25 }
    $ids = [IO.File]::ReadAllLines($pidsPath)
    if (-not $transport.IsRunning) { throw '清理 fixture 未运行' }
    $transport.Stop()
    foreach ($processId in $ids) {
        if (Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue) { throw 'Job 未清理根进程或子进程' }
    }
    if ($transport.IsRunning -or $transport.Completed) { throw 'Stop 后状态不正确' }
    $transport.Dispose(); $transport = $null
    Write-Output 'PASS Job 根进程和子进程清理'
    foreach ($bad in @('relative.exe', (Join-Path $root 'missing.exe'), $root)) {
        $transport = [CodexPingTransport]::new(); $rejected = $false
        try { $transport.Start($bad, $root, $root, 'success') } catch { $rejected = $true }
        if (-not $rejected) { throw '错误 helper 路径未拒绝' }
        $transport.Dispose(); $transport = $null
    }
    foreach ($badDirectory in @('relative', (Join-Path $root 'missing'))) {
        foreach ($badHome in @($false, $true)) {
            $transport = [CodexPingTransport]::new(); $rejected = $false
            try {
                if ($badHome) { $transport.Start($fixture, $root, $badDirectory, 'success') }
                else { $transport.Start($fixture, $badDirectory, $root, 'success') }
            } catch { $rejected = $true }
            if (-not $rejected) { throw '错误工作目录或 home 未拒绝' }
            $transport.Dispose(); $transport = $null
        }
    }
    if ([Console]::InputEncoding.GetPreamble().Length -ne 3) { throw 'helper 未恢复父进程编码' }
    if ($env:CODEX_SESSION_ID -ne 'fixture-parent' -or $env:CODEX_THREAD_ID -ne 'fixture-thread') { throw 'helper 修改了父进程环境' }
    Write-Output 'PASS helper 路径校验与父进程编码/环境保持'
    Write-Output '包装层离线测试通过；未验证真实 CLI 登录、提交、回复或额度窗口激活。'
}
finally {
    if ($null -ne $transport) { $transport.Dispose() }
    if ($null -ne $client) { $client.Dispose() }
    $env:CODEX_SESSION_ID = $oldSession; $env:CODEX_THREAD_ID = $oldThread
    [Console]::InputEncoding = $oldEncoding
    $resolved = [IO.Path]::GetFullPath($root)
    if (-not $resolved.StartsWith($verification + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^transport-tests-[a-f0-9]{32} 空格$') { throw '测试清理路径越界' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}