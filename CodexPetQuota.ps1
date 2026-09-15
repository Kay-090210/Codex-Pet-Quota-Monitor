#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$SelfTest,
    [switch]$PositionSelfTest,
    [switch]$UiSelfTest,
    [string]$PreviewDirectory,
    [switch]$ProbeOnce,
    [switch]$PingSettings,
    [switch]$CheckPingLogin
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'CodexQuotaPing.ps1')

$script:MutexName = 'Local\CodexPetQuotaOverlay.SingleInstance'
$script:StopEventName = 'Local\CodexPetQuotaOverlay.Stop'
$script:PanelWidthDip = 96.0
$script:PanelHeightDip = 232.0
$script:HorizontalPanelWidthDip = 192.0
$script:HorizontalPanelHeightDip = 116.0
# 常态只和角色保留轻微间距；任务卡片出现后改为上下避让。
$script:PanelGapDip = 8.0

function Send-StopSignal {
    try {
        $event = [Threading.EventWaitHandle]::OpenExisting($script:StopEventName)
        try {
            [void]$event.Set()
            Write-Output '已发送停止信号。'
        }
        finally {
            $event.Dispose()
        }
        return 0
    }
    catch [Threading.WaitHandleCannotBeOpenedException] {
        Write-Output '悬浮窗当前未运行。'
        return 0
    }
}

if ($Stop) {
    exit (Send-StopSignal)
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory = $false)]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-RateLimitSnapshot {
    param([Parameter(Mandatory = $true)]$Response)

    $result = Get-ObjectPropertyValue -InputObject $Response -Name 'result'
    if ($null -eq $result) {
        $result = $Response
    }

    $byLimitId = Get-ObjectPropertyValue -InputObject $result -Name 'rateLimitsByLimitId'
    if ($null -ne $byLimitId) {
        $codex = Get-ObjectPropertyValue -InputObject $byLimitId -Name 'codex'
        if ($null -ne $codex) {
            return $codex
        }
    }

    return (Get-ObjectPropertyValue -InputObject $result -Name 'rateLimits')
}

function Select-RateLimitWindow {
    param(
        [Parameter(Mandatory = $false)]$Snapshot,
        [Parameter(Mandatory = $true)][double]$TargetMinutes
    )

    if ($null -eq $Snapshot) {
        return $null
    }

    $candidates = @(
        Get-ObjectPropertyValue -InputObject $Snapshot -Name 'primary'
        Get-ObjectPropertyValue -InputObject $Snapshot -Name 'secondary'
    ) | Where-Object { $null -ne $_ }

    $best = $null
    $bestDistance = [double]::PositiveInfinity
    $tolerance = $TargetMinutes * 0.05

    foreach ($candidate in $candidates) {
        $durationValue = Get-ObjectPropertyValue -InputObject $candidate -Name 'windowDurationMins'
        if ($null -eq $durationValue) {
            continue
        }

        $duration = [double]$durationValue
        if ([double]::IsNaN($duration) -or [double]::IsInfinity($duration) -or $duration -le 0) {
            continue
        }

        $distance = [math]::Abs($duration - $TargetMinutes)
        if ($distance -le $tolerance -and $distance -lt $bestDistance) {
            $best = $candidate
            $bestDistance = $distance
        }
    }

    return $best
}

function ConvertTo-QuotaMetric {
    param(
        [Parameter(Mandatory = $false)]$Window,
        [Parameter(Mandatory = $true)][ValidateSet('FiveHour', 'Weekly')][string]$Kind
    )

    if ($null -eq $Window) {
        return [pscustomobject]@{
            Kind = $Kind
            Available = $false
            RemainingPercent = $null
            ResetText = '正在重连'
            WindowDurationMins = $null
        }
    }

    $usedValue = Get-ObjectPropertyValue -InputObject $Window -Name 'usedPercent'
    if ($null -eq $usedValue) {
        return [pscustomobject]@{
            Kind = $Kind
            Available = $false
            RemainingPercent = $null
            ResetText = '正在重连'
            WindowDurationMins = Get-ObjectPropertyValue -InputObject $Window -Name 'windowDurationMins'
        }
    }

    $usedPercent = 0.0
    if (-not [double]::TryParse([string]$usedValue, [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture, [ref]$usedPercent) -or
        [double]::IsNaN($usedPercent) -or [double]::IsInfinity($usedPercent)) {
        return (ConvertTo-QuotaMetric -Window $null -Kind $Kind)
    }

    $remaining = [math]::Round(100.0 - $usedPercent, 0, [MidpointRounding]::AwayFromZero)
    $remaining = [int][math]::Max(0, [math]::Min(100, $remaining))

    $resetText = '重置时间未知'
    $resetValue = Get-ObjectPropertyValue -InputObject $Window -Name 'resetsAt'
    if ($null -ne $resetValue) {
        try {
            $localReset = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetValue).ToLocalTime()
            if ($Kind -eq 'FiveHour') {
                $resetText = '重置 ' + $localReset.ToString('HH:mm')
            }
            else {
                $resetText = '重置 ' + $localReset.ToString('M/d HH:mm')
            }
        }
        catch {
            $resetText = '重置时间未知'
        }
    }

    return [pscustomobject]@{
        Kind = $Kind
        Available = $true
        RemainingPercent = $remaining
        # 依据实际值判定耗尽，避免 99.6% 已用量被四舍五入后提前切换积分。
        Exhausted = ($usedPercent -ge 100.0)
        DisplayText = $(if ($remaining -eq 0 -and $usedPercent -lt 100) { '<1%' } else { "$remaining%" })
        ResetText = $resetText
        WindowDurationMins = Get-ObjectPropertyValue -InputObject $Window -Name 'windowDurationMins'
    }
}

function ConvertTo-CreditMetric {
    param([Parameter(Mandatory = $false)]$Credits)

    $metric = [pscustomobject]@{
        Kind = 'Credits'
        Available = $false
        Unlimited = $false
        Balance = $null
        DisplayText = '—'
        ResetText = '5H 重置时间未知'
    }
    if ($null -eq $Credits) { return $metric }
    if ((Get-ObjectPropertyValue -InputObject $Credits -Name 'unlimited') -eq $true) {
        $metric.Available = $true
        $metric.Unlimited = $true
        $metric.DisplayText = '∞'
        return $metric
    }

    $rawBalance = Get-ObjectPropertyValue -InputObject $Credits -Name 'balance'
    $balance = [decimal]0
    if ($null -eq $rawBalance -or -not [decimal]::TryParse([string]$rawBalance,
            [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture,
            [ref]$balance)) { return $metric }

    # hasCredits=false 仍可带有确切的 0 余额；只有余额缺失或非法才回退至 5H。
    $metric.Available = $true
    $metric.Balance = $balance
    $metric.DisplayText = $balance.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)
    if ($balance -gt 0 -and $balance -lt 0.01) { $metric.DisplayText = '<0.01' }
    if ($balance -lt 0 -and $balance -gt -0.01) { $metric.DisplayText = '>-0.01' }
    return $metric
}

function ConvertTo-QuotaViewModel {
    param([Parameter(Mandatory = $true)]$Response)

    $snapshot = Get-RateLimitSnapshot -Response $Response
    $fiveHourWindow = Select-RateLimitWindow -Snapshot $snapshot -TargetMinutes 300
    $weeklyWindow = Select-RateLimitWindow -Snapshot $snapshot -TargetMinutes 10080
    $fiveHour = ConvertTo-QuotaMetric -Window $fiveHourWindow -Kind FiveHour
    $credits = ConvertTo-CreditMetric -Credits (Get-ObjectPropertyValue -InputObject $snapshot -Name 'credits')
    $top = $fiveHour
    if ($fiveHour.Available -and $fiveHour.Exhausted -and $credits.Available) {
        # 球内显示积分时，球下方仍保留原 5H 窗口的重置时间。
        $credits.ResetText = '5H ' + $fiveHour.ResetText
        $top = $credits
    }

    return [pscustomobject]@{
        FiveHour = $fiveHour
        Weekly = ConvertTo-QuotaMetric -Window $weeklyWindow -Kind Weekly
        Credits = $credits
        Top = $top
    }
}

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $false)]$Actual,
        [Parameter(Mandatory = $false)]$Expected
    )

    if ($Actual -ne $Expected) {
        throw "断言失败 [$Name]：期望 '$Expected'，实际 '$Actual'。"
    }
    Write-Output "PASS $Name"
}

function Invoke-SelfTest {
    $reset = [DateTimeOffset]::Now.AddHours(2).ToUnixTimeSeconds()

    $normal = [pscustomobject]@{
        result = [pscustomobject]@{
            rateLimitsByLimitId = [pscustomobject]@{
                codex = [pscustomobject]@{
                    primary = [pscustomobject]@{ usedPercent = 16; windowDurationMins = 300; resetsAt = $reset }
                    secondary = [pscustomobject]@{ usedPercent = 43; windowDurationMins = 10080; resetsAt = $reset }
                }
            }
            rateLimits = [pscustomobject]@{
                primary = [pscustomobject]@{ usedPercent = 99; windowDurationMins = 300; resetsAt = $reset }
            }
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $normal
    Assert-Equal -Name '优先使用 rateLimitsByLimitId.codex' -Actual $view.FiveHour.RemainingPercent -Expected 84
    Assert-Equal -Name '周限额剩余百分比' -Actual $view.Weekly.RemainingPercent -Expected 57

    $swapped = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = 25; windowDurationMins = 10080; resetsAt = $reset }
            secondary = [pscustomobject]@{ usedPercent = 75; windowDurationMins = 300; resetsAt = $reset }
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $swapped
    Assert-Equal -Name '窗口顺序互换时识别 5H' -Actual $view.FiveHour.RemainingPercent -Expected 25
    Assert-Equal -Name '窗口顺序互换时识别周限额' -Actual $view.Weekly.RemainingPercent -Expected 75

    $missing = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = 50; windowDurationMins = 300; resetsAt = $reset }
            secondary = $null
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $missing
    Assert-Equal -Name '缺失周窗口时保持不可用状态' -Actual $view.Weekly.Available -Expected $false

    $bounds = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = -5; windowDurationMins = 300; resetsAt = $reset }
            secondary = [pscustomobject]@{ usedPercent = 120; windowDurationMins = 10080; resetsAt = $reset }
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $bounds
    Assert-Equal -Name '剩余百分比上界钳制' -Actual $view.FiveHour.RemainingPercent -Expected 100
    Assert-Equal -Name '剩余百分比下界钳制' -Actual $view.Weekly.RemainingPercent -Expected 0

    $exactBounds = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = 0; windowDurationMins = 300; resetsAt = $reset }
            secondary = [pscustomobject]@{ usedPercent = 100; windowDurationMins = 10080; resetsAt = $reset }
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $exactBounds
    Assert-Equal -Name 'usedPercent 为 0' -Actual $view.FiveHour.RemainingPercent -Expected 100
    Assert-Equal -Name 'usedPercent 为 100' -Actual $view.Weekly.RemainingPercent -Expected 0

    $nullUsed = ConvertTo-QuotaMetric -Window ([pscustomobject]@{
        usedPercent = $null
        windowDurationMins = 300
        resetsAt = $reset
    }) -Kind FiveHour
    Assert-Equal -Name 'usedPercent 为空时保持不可用状态' -Actual $nullUsed.Available -Expected $false

    $crossDayReset = [DateTimeOffset]::Now.AddDays(1)
    $crossDayMetric = ConvertTo-QuotaMetric -Window ([pscustomobject]@{
        usedPercent = 50
        windowDurationMins = 10080
        resetsAt = $crossDayReset.ToUnixTimeSeconds()
    }) -Kind Weekly
    Assert-Equal -Name 'Unix 重置时间跨日转换' -Actual $crossDayMetric.ResetText -Expected ('重置 ' + $crossDayReset.ToLocalTime().ToString('M/d HH:mm'))

    if ($view.FiveHour.ResetText -notmatch '^重置 \d{2}:\d{2}$') {
        throw "断言失败 [5H 重置时间格式]：$($view.FiveHour.ResetText)"
    }
    Write-Output 'PASS 5H 重置时间格式'

    if ($view.Weekly.ResetText -notmatch '^重置 \d{1,2}/\d{1,2} \d{2}:\d{2}$') {
        throw "断言失败 [周重置时间格式]：$($view.Weekly.ResetText)"
    }
    Write-Output 'PASS 周重置时间格式'

    $creditCase = [pscustomobject]@{
        rateLimits = [pscustomobject]@{
            primary = [pscustomobject]@{ usedPercent = 100; windowDurationMins = 300; resetsAt = $reset }
            secondary = [pscustomobject]@{ usedPercent = 30; windowDurationMins = 10080; resetsAt = $reset }
            credits = [pscustomobject]@{ hasCredits = $true; unlimited = $false; balance = '783.7973420000' }
        }
    }
    $view = ConvertTo-QuotaViewModel -Response $creditCase
    Assert-Equal '5H 耗尽时切换积分' $view.Top.Kind 'Credits'
    Assert-Equal '保留原始 5H 数据' $view.FiveHour.RemainingPercent 0
    Assert-Equal '积分小数格式' $view.Top.DisplayText '783.8'
    Assert-Equal '积分切换不影响周窗口' $view.Weekly.RemainingPercent 70
    Assert-Equal '积分模式保留 5H 重置时间' $view.Top.ResetText ('5H ' + $view.FiveHour.ResetText)
    $creditCase.rateLimits.primary.resetsAt = $reset + 3600
    $updatedResetView = ConvertTo-QuotaViewModel $creditCase
    Assert-Equal '积分模式持续更新 5H 重置时间' $updatedResetView.Top.ResetText ('5H 重置 ' + [DateTimeOffset]::FromUnixTimeSeconds($reset + 3600).ToLocalTime().ToString('HH:mm'))
    $creditCase.rateLimits.primary.resetsAt = $null
    Assert-Equal '积分模式重置时间缺失时明确标记' (ConvertTo-QuotaViewModel $creditCase).Top.ResetText '5H 重置时间未知'
    $creditCase.rateLimits.primary.resetsAt = 'invalid'
    Assert-Equal '积分模式重置时间非法时明确标记' (ConvertTo-QuotaViewModel $creditCase).Top.ResetText '5H 重置时间未知'
    $creditCase.rateLimits.primary.resetsAt = $reset
    $creditCase.rateLimits.primary.usedPercent = 99.6
    $view = ConvertTo-QuotaViewModel -Response $creditCase
    Assert-Equal '未实际耗尽不提前切换' $view.Top.Kind 'FiveHour'
    Assert-Equal '微量剩余额度不显示 0%' $view.Top.DisplayText '<1%'
    $creditCase.rateLimits.primary.usedPercent = 20
    Assert-Equal '恢复额度后回到 5H' (ConvertTo-QuotaViewModel $creditCase).Top.DisplayText '80%'
    foreach ($invalidUsed in @($null, 'invalid', 'NaN', 'Infinity')) {
        $creditCase.rateLimits.primary.usedPercent = $invalidUsed
        $view = ConvertTo-QuotaViewModel $creditCase
        Assert-Equal '未知或非法额度不切换积分' $view.Top.Kind 'FiveHour'
        Assert-Equal '未知或非法额度保持不可用' $view.Top.Available $false
    }
    $creditCase.rateLimits.primary.usedPercent = 100
    foreach ($invalidBalance in @($null, '', 'invalid', 'NaN', 'Infinity', '1,234')) {
        $creditCase.rateLimits.credits.balance = $invalidBalance
        $view = ConvertTo-QuotaViewModel $creditCase
        Assert-Equal '无有效积分余额时保留 5H' $view.Top.Kind 'FiveHour'
        Assert-Equal '回退时正确显示 0%' $view.Top.DisplayText '0%'
    }
    $creditCase.rateLimits.credits.balance = '0'
    $creditCase.rateLimits.credits.hasCredits = $false
    $view = ConvertTo-QuotaViewModel $creditCase
    Assert-Equal '0 积分不是缺失数据' $view.Top.Kind 'Credits'
    Assert-Equal '显示 0 积分' $view.Top.DisplayText '0'
    $creditCase.rateLimits.credits.balance = '0.001'
    Assert-Equal '极少积分不四舍五入为 0' (ConvertTo-QuotaViewModel $creditCase).Top.DisplayText '<0.01'
    $creditCase.rateLimits.credits.balance = '-1.25'
    Assert-Equal '负余额保留实际含义' (ConvertTo-QuotaViewModel $creditCase).Top.DisplayText '-1.25'
    $creditCase.rateLimits.credits.balance = $null
    $creditCase.rateLimits.credits.unlimited = $true
    Assert-Equal '无限积分无需数值余额' (ConvertTo-QuotaViewModel $creditCase).Top.DisplayText '∞'
    $creditCase.rateLimits.credits = $null
    Assert-Equal '缺失 credits 时回退 5H' (ConvertTo-QuotaViewModel $creditCase).Top.Kind 'FiveHour'
    $normal.result.rateLimits | Add-Member -NotePropertyName credits -NotePropertyValue ([pscustomobject]@{ balance = '999' })
    $normal.result.rateLimitsByLimitId.codex.primary.usedPercent = 100
    Assert-Equal '不跨额度桶借用旧积分' (ConvertTo-QuotaViewModel $normal).Top.Kind 'FiveHour'
    Write-Output '全部内置测试通过。'
}

if ($SelfTest) {
    Invoke-SelfTest
    exit 0
}

$nativeSource = @'
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

public sealed class CodexAppServerClient : IDisposable
{
    private readonly ConcurrentQueue<string> _stdout = new ConcurrentQueue<string>();
    private Process _process;
    private IntPtr _job = IntPtr.Zero;

    public bool IsRunning
    {
        get
        {
            try { return _process != null && !_process.HasExited; }
            catch { return false; }
        }
    }

    public void Start(string executablePath, string workingDirectory)
    {
        StartWithHome(executablePath, workingDirectory, null);
    }

    public void StartWithHome(string executablePath, string workingDirectory, string codexHome)
    {
        Stop();
        var psi = new ProcessStartInfo
        {
            FileName = executablePath,
            Arguments = "app-server --stdio",
            WorkingDirectory = workingDirectory,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };

        if (!String.IsNullOrEmpty(codexHome))
        {
            var keys = new System.Collections.Generic.List<string>();
            foreach (string key in psi.EnvironmentVariables.Keys)
                if (key.StartsWith("CODEX_", StringComparison.OrdinalIgnoreCase) || key.Equals("OPENAI_API_KEY", StringComparison.OrdinalIgnoreCase)) keys.Add(key);
            foreach (string key in keys) psi.EnvironmentVariables.Remove(key);
            psi.EnvironmentVariables["CODEX_HOME"] = codexHome;
        }
        psi.EnvironmentVariables.Remove("CODEX_SESSION_ID");
        psi.EnvironmentVariables.Remove("CODEX_THREAD_ID");
        _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        _process.OutputDataReceived += (sender, args) =>
        {
            if (!String.IsNullOrWhiteSpace(args.Data)) _stdout.Enqueue(args.Data);
        };
        // stderr 必须持续读取以避免管道阻塞；内容不落盘，也不进入 UI。
        _process.ErrorDataReceived += (sender, args) => { var ignored = args.Data; };

        // .NET Framework 在 Process.Start 内创建 AutoFlush writer 时就可能写出 BOM。
        // 必须在启动前设置无 BOM 编码；事后重包 BaseStream 已经太迟。
        Encoding previousInputEncoding = Console.InputEncoding;
        bool started;
        try
        {
            Console.InputEncoding = new UTF8Encoding(false);
            started = _process.Start();
        }
        finally { Console.InputEncoding = previousInputEncoding; }
        if (!started) throw new InvalidOperationException("Failed to start codex app-server.");
        AttachKillOnCloseJob(_process);
        _process.BeginOutputReadLine();
        _process.BeginErrorReadLine();
    }

    public void SendLine(string line)
    {
        if (!IsRunning) throw new InvalidOperationException("codex app-server is not running.");
        _process.StandardInput.WriteLine(line);
        _process.StandardInput.Flush();
    }

    public bool TryDequeue(out string line) { return _stdout.TryDequeue(out line); }

    public void Stop()
    {
        var process = _process;
        _process = null;
        if (process != null)
        {
            try
            {
                if (!process.HasExited)
                {
                    try { process.StandardInput.Close(); } catch { }
                    if (!process.WaitForExit(1200))
                    {
                        try { process.Kill(); } catch { }
                        try { process.WaitForExit(1200); } catch { }
                    }
                }
            }
            catch { }
            finally { process.Dispose(); }
        }

        if (_job != IntPtr.Zero)
        {
            CloseHandle(_job);
            _job = IntPtr.Zero;
        }

        string ignored;
        while (_stdout.TryDequeue(out ignored)) { }
    }

    private void AttachKillOnCloseJob(Process process)
    {
        _job = CreateJobObject(IntPtr.Zero, null);
        if (_job == IntPtr.Zero) return;

        var info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int length = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        IntPtr pointer = Marshal.AllocHGlobal(length);
        try
        {
            Marshal.StructureToPtr(info, pointer, false);
            if (!SetInformationJobObject(_job, JobObjectExtendedLimitInformation, pointer, (uint)length) ||
                !AssignProcessToJobObject(_job, process.Handle))
            {
                CloseHandle(_job);
                _job = IntPtr.Zero;
            }
        }
        finally { Marshal.FreeHGlobal(pointer); }
    }

    public void Dispose() { Stop(); }

    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
    private const int JobObjectExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS
    {
        public UInt64 ReadOperationCount, WriteOperationCount, OtherOperationCount;
        public UInt64 ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public Int64 PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public Int64 Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);
    [DllImport("kernel32.dll")]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
}

public enum OverlayLayout { Vertical, Horizontal }

public sealed class PetWindowInfo
{
    public IntPtr Handle { get; set; }
    public NativeWindow.RECT Rect { get; set; }
    public NativeWindow.RECT VisualRect { get; set; }
    // 当帧的实际内容边界（含任务卡片），独立于防动画抖动的角色锚点。
    public NativeWindow.RECT ContentRect { get; set; }
    // 单独保留扁宽任务卡片，供额度面板在角色旁上下避让。
    public NativeWindow.RECT TaskRect { get; set; }
    public NativeWindow.RECT WorkArea { get; set; }
    public uint Dpi { get; set; }
}

public sealed class PetAnchorTracker
{
    private bool initialized, dragging, previousMouseDown;
    private IntPtr handle;
    private uint dpi;
    private NativeWindow.RECT anchor, previousWindow, previousVisual;

    public NativeWindow.RECT Update(PetWindowInfo pet, bool mouseDown, int cursorX, int cursorY)
    {
        if (!initialized || pet.Handle != handle || pet.Dpi != dpi)
        {
            initialized = true; handle = pet.Handle; dpi = pet.Dpi;
            anchor = pet.VisualRect; previousWindow = pet.Rect; previousVisual = pet.VisualRect;
            dragging = false; previousMouseDown = mouseDown;
            return anchor;
        }
        if (mouseDown && !previousMouseDown && !dragging)
        {
            // 只有从角色区域开始的按压才解锁锚点。
            var r = pet.VisualRect;
            dragging = cursorX >= r.Left - 8 && cursorX <= r.Right + 8 &&
                cursorY >= r.Top - 8 && cursorY <= r.Bottom + 8;
        }
        if (dragging)
        {
            // 始终以实际捕获的位置校准，禁止累计指针/容器位移造成漂移。
            anchor = pet.VisualRect;
            if (!mouseDown) dragging = false;
        }
        else
        {
            int dx = pet.Rect.Left - previousWindow.Left;
            int dy = pet.Rect.Top - previousWindow.Top;
            // 只跟随容器和角色共同的平移，不跟随通知造成的容器原点变化。
            if ((dx != 0 || dy != 0) &&
                Math.Abs(pet.VisualRect.Left - previousVisual.Left - dx) <= 8 &&
                Math.Abs(pet.VisualRect.Top - previousVisual.Top - dy) <= 8)
                anchor = pet.VisualRect;
            // 快速拖动可能完整发生在两次采样之间，显著位移必须重新捕获。
            double threshold = 64 * (pet.Dpi == 0 ? 1 : pet.Dpi / 96.0);
            double centerDelta = (pet.VisualRect.Left + pet.VisualRect.Right - anchor.Left - anchor.Right) / 2.0;
            if (Math.Abs(centerDelta) > threshold || Math.Abs(pet.VisualRect.Bottom - anchor.Bottom) > threshold)
                anchor = pet.VisualRect;
        }
        previousMouseDown = mouseDown;
        previousWindow = pet.Rect; previousVisual = pet.VisualRect;
        return anchor;
    }
}

public static class NativeWindow
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MONITORINFO
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER bmiHeader;
        public uint bmiColors;
    }

    private const int GWL_STYLE = -16;
    private const int GWL_EXSTYLE = -20;
    private const long WS_CAPTION = 0x00C00000L;
    private const long WS_EX_TOPMOST = 0x00000008L;
    private const long WS_EX_TRANSPARENT = 0x00000020L;
    private const long WS_EX_TOOLWINDOW = 0x00000080L;
    private const long WS_EX_LAYERED = 0x00080000L;
    private const long WS_EX_NOACTIVATE = 0x08000000L;
    private const uint MONITOR_DEFAULTTONEAREST = 2;
    private const uint DIB_RGB_COLORS = 0;
    private const uint BI_RGB = 0;
    private const uint PW_RENDERFULLCONTENT = 2;
    private const uint SWP_NOACTIVATE = 0x0010;
    private const uint SWP_SHOWWINDOW = 0x0040;
    private const uint SWP_NOOWNERZORDER = 0x0200;
    private static readonly PetAnchorTracker anchorTracker = new PetAnchorTracker();

    public static void EnablePerMonitorDpiAwareness()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }
    }

    public static PetWindowInfo FindPetWindow(IntPtr previous)
    {
        if (previous != IntPtr.Zero)
        {
            PetWindowInfo existing;
            if (TryReadPetWindow(previous, false, out existing)) return existing;
        }

        var candidates = new List<PetWindowInfo>();
        EnumWindows((hWnd, lParam) =>
        {
            PetWindowInfo info;
            if (TryReadPetWindow(hWnd, true, out info)) candidates.Add(info);
            return true;
        }, IntPtr.Zero);

        PetWindowInfo best = null;
        long bestArea = Int64.MaxValue;
        foreach (var item in candidates)
        {
            long width = item.Rect.Right - item.Rect.Left;
            long height = item.Rect.Bottom - item.Rect.Top;
            long area = width * height;
            if (area < bestArea) { best = item; bestArea = area; }
        }
        return best;
    }

    public static bool IsSupportedPetSize(int width, int height, uint dpi)
    {
        // 新版透明桌宠容器可高于 1000 像素；按逻辑尺寸限制并保留捕获上限。
        double scale = (dpi == 0 ? 96 : dpi) / 96.0;
        return width >= 100 * scale && height >= 100 * scale &&
            width <= 1600 * scale && height <= 1600 * scale &&
            width <= 4096 && height <= 4096;
    }

    private static bool TryReadPetWindow(IntPtr hWnd, bool validateProcess, out PetWindowInfo info)
    {
        info = null;
        if (!IsWindowVisible(hWnd)) return false;

        var className = new StringBuilder(128);
        GetClassName(hWnd, className, className.Capacity);
        if (!String.Equals(className.ToString(), "Chrome_WidgetWin_1", StringComparison.Ordinal)) return false;

        if (validateProcess)
        {
            uint processId;
            GetWindowThreadProcessId(hWnd, out processId);
            try
            {
                using (var process = Process.GetProcessById((int)processId))
                {
                    if (!String.Equals(process.ProcessName, "ChatGPT", StringComparison.OrdinalIgnoreCase)) return false;
                    string path;
                    try { path = process.MainModule.FileName; }
                    catch { return false; }
                    if (path.IndexOf("OpenAI.Codex_", StringComparison.OrdinalIgnoreCase) < 0) return false;
                }
            }
            catch { return false; }
        }

        long style = GetWindowLongPtr(hWnd, GWL_STYLE).ToInt64();
        long exStyle = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
        if ((style & WS_CAPTION) != 0) return false;
        if ((exStyle & WS_EX_TOOLWINDOW) == 0 || (exStyle & WS_EX_LAYERED) == 0) return false;

        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return false;
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;

        uint dpi = 96;
        try { dpi = GetDpiForWindow(hWnd); } catch { }
        if (dpi == 0) dpi = 96;
        if (!IsSupportedPetSize(width, height, dpi)) return false;

        RECT visualRelative, contentRelative, taskRelative;
        if (!TryGetPetVisualRelative(hWnd, width, height, out visualRelative, out contentRelative, out taskRelative))
        {
            // 新版角色在容器内可自由移动，顶部/中心回退位置并不可靠。
            return false;
        }

        var visualRect = new RECT
        {
            Left = rect.Left + visualRelative.Left,
            Top = rect.Top + visualRelative.Top,
            Right = rect.Left + visualRelative.Right,
            Bottom = rect.Top + visualRelative.Bottom
        };
        var contentRect = new RECT
        {
            Left = rect.Left + contentRelative.Left,
            Top = rect.Top + contentRelative.Top,
            Right = rect.Left + contentRelative.Right,
            Bottom = rect.Top + contentRelative.Bottom
        };
        var taskRect = taskRelative.Right > taskRelative.Left && taskRelative.Bottom > taskRelative.Top
            ? new RECT
            {
                Left = rect.Left + taskRelative.Left,
                Top = rect.Top + taskRelative.Top,
                Right = rect.Left + taskRelative.Right,
                Bottom = rect.Top + taskRelative.Bottom
            }
            : new RECT();

        IntPtr monitor = MonitorFromRect(ref visualRect, MONITOR_DEFAULTTONEAREST);
        var monitorInfo = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (!GetMonitorInfo(monitor, ref monitorInfo)) return false;

        info = new PetWindowInfo
        {
            Handle = hWnd,
            Rect = rect,
            VisualRect = visualRect,
            ContentRect = contentRect,
            TaskRect = taskRect,
            WorkArea = monitorInfo.rcWork,
            Dpi = dpi
        };
        return true;
    }

    public static bool TryFindPetPixels(byte[] pixels, int width, int height, out RECT visual)
    {
        RECT content, task;
        return TryFindPetPixels(pixels, width, height, out visual, out content, out task);
    }

    public static bool TryFindPetPixels(byte[] pixels, int width, int height, out RECT visual, out RECT content)
    {
        RECT task;
        return TryFindPetPixels(pixels, width, height, out visual, out content, out task);
    }

    public static bool TryFindPetPixels(byte[] pixels, int width, int height, out RECT visual, out RECT content, out RECT task)
    {
        visual = new RECT();
        content = new RECT();
        task = new RECT();
        if (width <= 0 || height <= 0 || pixels == null || pixels.LongLength < (long)width * height * 4) return false;
        // 角色、按钮和任务卡片之间有透明行；卡片可能翻到角色上方。
        // 排除扁宽卡片与小按钮，在角色形状的像素带中选择最高者。
        // 扫描整窗，不能假定角色始终位于透明容器上方 34%。
        int minX = width, maxX = -1, top = -1, bottom = -1, count = 0;
        int bestHeight = 0, bestTaskArea = 0;
        for (int y = 0; y <= height; y++)
        {
            bool occupied = false;
            if (y < height)
            {
                for (int x = 0; x < width; x++)
                {
                    int i = (y * width + x) * 4;
                    if (pixels[i] <= 12 && pixels[i + 1] <= 12 && pixels[i + 2] <= 12) continue;
                    occupied = true; count++;
                    minX = Math.Min(minX, x); maxX = Math.Max(maxX, x);
                }
            }
            if (occupied) { if (top < 0) top = y; bottom = y; }
            else if (top >= 0)
            {
                int bandHeight = bottom - top + 1;
                int bandWidth = maxX - minX + 1;
                int padding = Math.Max(2, width / 150);
                var band = new RECT { Left = Math.Max(0, minX - padding), Top = Math.Max(0, top - padding),
                    Right = Math.Min(width, maxX + padding + 1), Bottom = Math.Min(height, bottom + padding + 1) };
                // 角色筛选仍忽略卡片，但避让边界保留所有有效像素带及其实际横向偏移。
                // 沿用有效像素数量下限，避免孤立噪点把悬浮窗推到远处。
                if (count >= 100)
                {
                    if (content.Right <= content.Left) content = band;
                    else content = new RECT { Left = Math.Min(content.Left, band.Left), Top = Math.Min(content.Top, band.Top),
                        Right = Math.Max(content.Right, band.Right), Bottom = Math.Max(content.Bottom, band.Bottom) };
                }
                int taskArea = bandWidth * bandHeight;
                int minimumTaskWidth = Math.Max(80, width / 4);
                if (count >= 100 && bandHeight >= 18 && bandWidth >= minimumTaskWidth &&
                    bandWidth >= bandHeight * 2 && taskArea > bestTaskArea)
                {
                    task = band;
                    bestTaskArea = taskArea;
                }
                if (count >= 100 && bandHeight >= 40 && bandWidth >= 12 && bandWidth <= bandHeight * 2 && bandHeight > bestHeight)
                {
                    visual = band;
                    bestHeight = bandHeight;
                }
                minX = width; maxX = -1; top = -1; bottom = -1; count = 0;
            }
        }
        return bestHeight > 0;
    }

    private static bool TryGetPetVisualRelative(IntPtr hWnd, int width, int height, out RECT visual, out RECT content, out RECT task)
    {
        // 调用方已有 250ms 轮询节流；每轮捕获当前卡片布局，避免同尺寸内移时复用旧边界。
        visual = new RECT();
        content = new RECT();
        task = new RECT();
        IntPtr windowDc = IntPtr.Zero;
        IntPtr memoryDc = IntPtr.Zero;
        IntPtr bitmap = IntPtr.Zero;
        IntPtr previousBitmap = IntPtr.Zero;
        try
        {
            windowDc = GetWindowDC(hWnd);
            if (windowDc == IntPtr.Zero) return false;
            memoryDc = CreateCompatibleDC(windowDc);
            if (memoryDc == IntPtr.Zero) return false;

            var bitmapInfo = new BITMAPINFO();
            bitmapInfo.bmiHeader.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            bitmapInfo.bmiHeader.biWidth = width;
            bitmapInfo.bmiHeader.biHeight = -height;
            bitmapInfo.bmiHeader.biPlanes = 1;
            bitmapInfo.bmiHeader.biBitCount = 32;
            bitmapInfo.bmiHeader.biCompression = BI_RGB;
            bitmapInfo.bmiHeader.biSizeImage = (uint)(width * height * 4);

            IntPtr bits;
            bitmap = CreateDIBSection(windowDc, ref bitmapInfo, DIB_RGB_COLORS, out bits, IntPtr.Zero, 0);
            if (bitmap == IntPtr.Zero || bits == IntPtr.Zero) return false;
            previousBitmap = SelectObject(memoryDc, bitmap);
            if (!PrintWindow(hWnd, memoryDc, PW_RENDERFULLCONTENT)) return false;

            int byteCount = width * height * 4;
            var pixels = new byte[byteCount];
            Marshal.Copy(bits, pixels, 0, byteCount);

            return TryFindPetPixels(pixels, width, height, out visual, out content, out task);
        }
        catch { return false; }
        finally
        {
            if (previousBitmap != IntPtr.Zero && memoryDc != IntPtr.Zero) SelectObject(memoryDc, previousBitmap);
            if (bitmap != IntPtr.Zero) DeleteObject(bitmap);
            if (memoryDc != IntPtr.Zero) DeleteDC(memoryDc);
            if (windowDc != IntPtr.Zero) ReleaseDC(hWnd, windowDc);
        }
    }

    public static void MakeOverlayClickThrough(IntPtr hWnd)
    {
        long exStyle = GetWindowLongPtr(hWnd, GWL_EXSTYLE).ToInt64();
        exStyle |= WS_EX_TOOLWINDOW | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
        SetWindowLongPtr(hWnd, GWL_EXSTYLE, new IntPtr(exStyle));
    }

    public static void PositionOverlay(
        IntPtr overlay,
        PetWindowInfo pet,
        double widthDip,
        double heightDip,
        double gapDip,
        double overlayVisualScale)
    {
        PositionOverlay(overlay, pet, widthDip, heightDip, gapDip, overlayVisualScale, OverlayLayout.Vertical);
    }

    public static PetWindowInfo GetAnchoredPet(PetWindowInfo pet)
    {
        POINT cursor;
        bool cursorAvailable = GetCursorPos(out cursor);
        RECT stable = anchorTracker.Update(pet, cursorAvailable && (GetAsyncKeyState(1) & 0x8000) != 0, cursor.X, cursor.Y);
        return new PetWindowInfo { Handle = pet.Handle, Rect = pet.Rect, VisualRect = stable,
            ContentRect = pet.ContentRect, TaskRect = pet.TaskRect, WorkArea = pet.WorkArea, Dpi = pet.Dpi };
    }

    public static OverlayLayout GetOverlayLayout(PetWindowInfo pet, int verticalWidth, int verticalHeight, int gap)
    {
        RECT vertical = CalculateOverlayRect(pet, verticalWidth, verticalHeight, gap, OverlayLayout.Vertical);
        return vertical.Right > vertical.Left && vertical.Bottom > vertical.Top
            ? OverlayLayout.Vertical
            : OverlayLayout.Horizontal;
    }

    public static void PositionOverlay(
        IntPtr overlay,
        PetWindowInfo pet,
        double widthDip,
        double heightDip,
        double gapDip,
        double overlayVisualScale,
        OverlayLayout layout)
    {
        double scale = (pet.Dpi == 0 ? 96 : pet.Dpi) / 96.0;
        double overlayScale = overlayVisualScale;
        if (overlayScale <= 0)
        {
            uint overlayDpi = 96;
            try { overlayDpi = GetDpiForWindow(overlay); } catch { }
            if (overlayDpi == 0) overlayDpi = 96;
            overlayScale = overlayDpi / 96.0;
        }
        int width = Math.Max(1, (int)Math.Round(widthDip * overlayScale));
        int height = Math.Max(1, (int)Math.Round(heightDip * overlayScale));
        int gap = Math.Max(1, (int)Math.Round(gapDip * scale));
        RECT target = CalculateOverlayRect(pet, width, height, gap, layout);
        if (target.Right <= target.Left || target.Bottom <= target.Top)
        {
            // 工作区没有完整的避让位置时临时隐藏，下次采样有空间即恢复。
            ShowWindow(overlay, 0);
            return;
        }
        // 紧随桌宠实际 Z 序，随其切换置顶分组，不提升桌宠或抢占焦点。
        if (pet.Handle == IntPtr.Zero || pet.Handle == overlay || !IsWindowVisible(pet.Handle) ||
            !SetWindowPos(overlay, pet.Handle, target.Left, target.Top, width, height,
                SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW))
        {
            ShowWindow(overlay, 0);
        }
    }

    private static RECT UnionRect(RECT a, RECT b)
    {
        if (a.Right <= a.Left || a.Bottom <= a.Top) return b;
        if (b.Right <= b.Left || b.Bottom <= b.Top) return a;
        return new RECT { Left = Math.Min(a.Left, b.Left), Top = Math.Min(a.Top, b.Top),
            Right = Math.Max(a.Right, b.Right), Bottom = Math.Max(a.Bottom, b.Bottom) };
    }

    public static RECT CalculateOverlayRect(PetWindowInfo pet, int width, int height, int gap)
    {
        return CalculateOverlayRect(pet, width, height, gap, OverlayLayout.Vertical);
    }

    public static RECT CalculateOverlayRect(PetWindowInfo pet, int width, int height, int gap, OverlayLayout layout)
    {
        if (width <= 0 || height <= 0 || width > pet.WorkArea.Right - pet.WorkArea.Left ||
            height > pet.WorkArea.Bottom - pet.WorkArea.Top) return new RECT();

        int visualHeight = pet.VisualRect.Bottom - pet.VisualRect.Top;
        int y = pet.VisualRect.Top + (visualHeight - height) / 2;
        int clearance = Math.Max(1, (int)Math.Round(8 * (pet.Dpi == 0 ? 1 : pet.Dpi / 96.0)));
        RECT content = pet.ContentRect;
        RECT task = pet.TaskRect;
        bool hasTaskCard = task.Right > task.Left && task.Bottom > task.Top;
        // 使用中心判侧，容忍像素 padding 或稳定角色锚点带来的少量纵向相交。
        bool taskIsAbove = hasTaskCard &&
            (long)task.Top + task.Bottom <= (long)pet.VisualRect.Top + pet.VisualRect.Bottom;
        if (layout == OverlayLayout.Horizontal)
        {
            // 竖排没有完整安全位置时才会进入这里。任务卡存在时，横排固定放在
            // 卡片同侧：上方卡片配上方横排，下方卡片配下方横排。
            RECT obstacle = UnionRect(UnionRect(content, pet.VisualRect), task);
            int centeredX = obstacle.Left + (obstacle.Right - obstacle.Left - width) / 2;
            centeredX = Math.Max(pet.WorkArea.Left, Math.Min(centeredX, pet.WorkArea.Right - width));
            int aboveY = obstacle.Top - clearance - height;
            int belowY = obstacle.Bottom + clearance;
            bool aboveFits = aboveY >= pet.WorkArea.Top && aboveY + height <= pet.WorkArea.Bottom;
            bool belowFits = belowY >= pet.WorkArea.Top && belowY + height <= pet.WorkArea.Bottom;
            if (hasTaskCard)
            {
                if (taskIsAbove)
                {
                    if (!aboveFits) return new RECT();
                    y = aboveY;
                }
                else
                {
                    if (!belowFits) return new RECT();
                    y = belowY;
                }
            }
            else
            {
                if (!aboveFits && !belowFits) return new RECT();
                // 无任务卡时，下方能完整容纳便优先放下方，否则对称地尝试上方。
                y = belowFits ? belowY : aboveY;
            }
            return new RECT { Left = centeredX, Top = y, Right = centeredX + width, Bottom = y + height };
        }

        // 常态贴近角色左右放置。任务卡出现后仍保持横坐标，但竖排只能放到卡片反侧：
        // 上方卡片配下方竖排，下方卡片配上方竖排，避免形成同方向的长纵列。
        int rightX = pet.VisualRect.Right + gap;
        int leftX = pet.VisualRect.Left - gap - width;
        int x;
        if (rightX >= pet.WorkArea.Left && rightX + width <= pet.WorkArea.Right) x = rightX;
        else if (leftX >= pet.WorkArea.Left && leftX + width <= pet.WorkArea.Right) x = leftX;
        else return new RECT(); // 两侧都放不下时切换横排，禁止钳位后覆盖角色。

        if (hasTaskCard)
        {
            // 只按任务卡边缘做最小位移；ContentRect 含角色和按钮，按它避让会
            // 把整个竖排推到角色上/下方。保留卡片反侧规则及角色旁的横坐标。
            y = taskIsAbove ? Math.Max(y, task.Bottom + clearance)
                : Math.Min(y, task.Top - clearance - height);
        }
        if (y < pet.WorkArea.Top || y + height > pet.WorkArea.Bottom)
        {
            // 不钳位纵坐标或退回卡片同侧；自然/最小避让位置放不下才切换横排。
            return new RECT();
        }
        return new RECT { Left = x, Top = y, Right = x + width, Bottom = y + height };
    }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr hWnd, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool ShowWindow(IntPtr hWnd, int command);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);
    [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromRect(ref RECT rect, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr hWnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern IntPtr GetWindowDC(IntPtr hWnd);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr hWnd, IntPtr hDc);
    [DllImport("user32.dll")] private static extern bool PrintWindow(IntPtr hWnd, IntPtr hDc, uint flags);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr hDc);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr hDc);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateDIBSection(IntPtr hDc, ref BITMAPINFO bitmapInfo, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr hDc, IntPtr value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr value);
}
'@

Add-Type -TypeDefinition $nativeSource -Language CSharp

if ($PositionSelfTest) {
    $tracker = [PetAnchorTracker]::new()
    $tracked = [PetWindowInfo]::new()
    $tracked.Handle = [IntPtr]123; $tracked.Dpi = 96
    $frame = [NativeWindow+RECT]::new()
    $frame.Left = 100; $frame.Top = 200; $frame.Right = 160; $frame.Bottom = 320
    $tracked.VisualRect = $frame
    $anchor = $tracker.Update($tracked, $false, 130, 260)
    for ($i = 0; $i -lt 30; $i++) {
        $frame.Left = 80 + ($i % 7) * 5; $frame.Right = 170 + ($i % 5) * 8
        $frame.Top = 175 + ($i % 6) * 7; $frame.Bottom = 330 - ($i % 4) * 6
        $tracked.VisualRect = $frame
        $anchor = $tracker.Update($tracked, $false, 130, 260)
        if ($anchor.Left -ne 100 -or $anchor.Top -ne 200 -or $anchor.Right -ne 160 -or $anchor.Bottom -ne 320) { throw '动画帧造成锚点变化' }
    }
    Write-Output 'PASS 30 帧伸缩/转身动画不移动锚点'
    $frame.Left = 100; $frame.Top = 200; $frame.Right = 160; $frame.Bottom = 320; $tracked.VisualRect = $frame
    [void]$tracker.Update($tracked, $true, 130, 260)
    $frame.Left += 100; $frame.Right += 100; $frame.Top += 200; $frame.Bottom += 200; $tracked.VisualRect = $frame
    $anchor = $tracker.Update($tracked, $true, 230, 460)
    Assert-Equal -Name '拖动水平位移' -Actual $anchor.Left -Expected 200
    Assert-Equal -Name '拖动垂直位移' -Actual $anchor.Top -Expected 400
    $anchor = $tracker.Update($tracked, $false, 230, 460)
    $frame.Top = 450; $frame.Bottom = 570; $tracked.VisualRect = $frame
    $anchor = $tracker.Update($tracked, $false, 230, 460)
    Assert-Equal -Name '松手后动作不拉动锚点' -Actual $anchor.Top -Expected 400
    [void]$tracker.Update($tracked, $true, 2000, 2000)
    $anchor = $tracker.Update($tracked, $true, 2200, 2100)
    Assert-Equal -Name '其他窗口鼠标操作不移动锚点' -Actual $anchor.Left -Expected 200
    $anchor = $tracker.Update($tracked, $true, 230, 500)
    Assert-Equal -Name '从其他窗口按住经过角色不解锁锚点' -Actual $anchor.Top -Expected 400
    [void]$tracker.Update($tracked, $false, 2200, 2100)
    $container = [NativeWindow+RECT]::new(); $container.Left = 50; $container.Right = 850
    $frame.Left += 50; $frame.Right += 50; $tracked.Rect = $container; $tracked.VisualRect = $frame
    $anchor = $tracker.Update($tracked, $false, 2200, 2100)
    Assert-Equal -Name '窗口整体移动继续跟随' -Actual $anchor.Left -Expected 250
    $container.Left += 100; $tracked.Rect = $container
    $anchor = $tracker.Update($tracked, $false, 2200, 2100)
    Assert-Equal -Name '通知改变容器但角色未移动时保持锚点' -Actual $anchor.Left -Expected 250
    $tracked.Handle = [IntPtr]124
    $anchor = $tracker.Update($tracked, $false, 0, 0)
    Assert-Equal -Name '桌宠新窗口重新定位' -Actual $anchor.Left -Expected $frame.Left
    $frame.Left += 500; $frame.Right += 500; $frame.Top -= 300; $frame.Bottom -= 300; $tracked.VisualRect = $frame
    $anchor = $tracker.Update($tracked, $false, 0, 0)
    Assert-Equal -Name '漏采按压的快速拖动仍重新捕获' -Actual $anchor.Left -Expected $frame.Left
    Assert-Equal -Name '快速拖动无累计垂直漂移' -Actual $anchor.Top -Expected $frame.Top
    foreach ($petY in @(30, 250, 430)) {
        $pixels = New-Object byte[] (200 * 600 * 4)
        for ($y = $petY; $y -lt $petY + 100; $y++) {
            for ($x = 80; $x -lt 140; $x++) { $pixels[($y * 200 + $x) * 4] = 255 }
        }
        # 下方卡片不应拉偏角色锚点；顶部少量噪点也应被忽略。
        $pixels[(3 * 200 + 2) * 4] = 255
        if ($petY -gt 200) {
            for ($y = 100; $y -lt 145; $y++) {
                for ($x = 10; $x -lt 190; $x++) { $pixels[($y * 200 + $x) * 4] = 255 }
            }
        }
        for ($y = 550; $y -lt 590; $y++) {
            for ($x = 20; $x -lt 180; $x++) { $pixels[($y * 200 + $x) * 4] = 255 }
        }
        $bounds = [NativeWindow+RECT]::new()
        $contentBounds = [NativeWindow+RECT]::new()
        $taskBounds = [NativeWindow+RECT]::new()
        Assert-Equal -Name "识别整窗 y=$petY 角色" -Actual ([NativeWindow]::TryFindPetPixels($pixels, 200, 600, [ref]$bounds, [ref]$contentBounds, [ref]$taskBounds)) -Expected $true
        Assert-Equal -Name "跟随 y=$petY 而非通知卡片" -Actual $bounds.Top -Expected ($petY - 2)
        Assert-Equal -Name "角色下边界 y=$petY" -Actual $bounds.Bottom -Expected ($petY + 102)
        Assert-Equal -Name "内容包含 y=$petY 下方任务卡片" -Actual $contentBounds.Bottom -Expected 592
        Assert-Equal -Name "内容包含 y=$petY 偏移卡片左缘" -Actual $contentBounds.Left -Expected $(if ($petY -gt 200) { 8 } else { 18 })
        Assert-Equal -Name "内容包含 y=$petY 偏移卡片右缘" -Actual $contentBounds.Right -Expected $(if ($petY -gt 200) { 192 } else { 182 })
        Assert-Equal -Name "内容忽略 y=$petY 顶部孤立噪点" -Actual $contentBounds.Top -Expected $(if ($petY -gt 200) { 98 } else { $petY - 2 })
        Assert-Equal -Name "单独识别 y=$petY 任务卡片上缘" -Actual $taskBounds.Top -Expected $(if ($petY -gt 200) { 98 } else { 548 })
        Assert-Equal -Name "单独识别 y=$petY 任务卡片下缘" -Actual $taskBounds.Bottom -Expected $(if ($petY -gt 200) { 147 } else { 592 })
        Assert-Equal -Name "单独识别 y=$petY 任务卡片左缘" -Actual $taskBounds.Left -Expected $(if ($petY -gt 200) { 8 } else { 18 })
        Assert-Equal -Name "单独识别 y=$petY 任务卡片右缘" -Actual $taskBounds.Right -Expected $(if ($petY -gt 200) { 192 } else { 182 })
        # 同一尺寸的新帧中卡片消失，避让边界应同步缩回角色而非保留旧值。
        [Array]::Clear($pixels, 0, $pixels.Length)
        for ($y = $petY; $y -lt $petY + 100; $y++) {
            for ($x = 80; $x -lt 140; $x++) { $pixels[($y * 200 + $x) * 4] = 255 }
        }
        Assert-Equal -Name "卡片消失后 y=$petY 角色仍可见" -Actual ([NativeWindow]::TryFindPetPixels($pixels, 200, 600, [ref]$bounds, [ref]$contentBounds, [ref]$taskBounds)) -Expected $true
        Assert-Equal -Name "卡片消失后 y=$petY 清除旧内容边界" -Actual $contentBounds.Equals($bounds) -Expected $true
        Assert-Equal -Name "卡片消失后 y=$petY 清除任务卡片边界" -Actual $taskBounds.Equals([NativeWindow+RECT]::new()) -Expected $true
    }
    $emptyBounds = [NativeWindow+RECT]::new()
    Assert-Equal -Name '空窗不生成猜测锚点' -Actual ([NativeWindow]::TryFindPetPixels((New-Object byte[] 1600), 20, 20, [ref]$emptyBounds)) -Expected $false
    Assert-Equal -Name '新版 638x1080 桌宠容器' -Actual ([NativeWindow]::IsSupportedPetSize(638, 1080, 96)) -Expected $true
    Assert-Equal -Name '125% 缩放桌宠容器' -Actual ([NativeWindow]::IsSupportedPetSize(798, 1350, 120)) -Expected $true
    Assert-Equal -Name '200% 缩放桌宠容器' -Actual ([NativeWindow]::IsSupportedPetSize(1276, 2160, 192)) -Expected $true
    Assert-Equal -Name '拒绝过小容器' -Actual ([NativeWindow]::IsSupportedPetSize(50, 50, 96)) -Expected $false
    Assert-Equal -Name '拒绝超大容器' -Actual ([NativeWindow]::IsSupportedPetSize(2000, 2000, 96)) -Expected $false
    Assert-Equal -Name '限制像素捕获大小' -Actual ([NativeWindow]::IsSupportedPetSize(5000, 5000, 384)) -Expected $false
    $pet = [PetWindowInfo]::new()
    $visual = [NativeWindow+RECT]::new()
    $visual.Left = 740; $visual.Top = 200; $visual.Right = 780; $visual.Bottom = 320
    $work = [NativeWindow+RECT]::new()
    $work.Left = 0; $work.Top = 0; $work.Right = 800; $work.Bottom = 600
    $pet.VisualRect = $visual
    $pet.WorkArea = $work

    $leftResult = [NativeWindow]::CalculateOverlayRect($pet, 120, 150, 4)
    Assert-Equal -Name '右侧空间不足时翻转到左侧' -Actual $leftResult.Left -Expected 616
    Assert-Equal -Name '翻转后不与角色重叠' -Actual $leftResult.Right -Expected 736

    $visual.Left = 100; $visual.Right = 140
    $pet.VisualRect = $visual
    $rightResult = [NativeWindow]::CalculateOverlayRect($pet, 120, 150, 4)
    Assert-Equal -Name '右侧空间足够时保持右侧' -Actual $rightResult.Left -Expected 144
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $width = [int]($script:PanelWidthDip * $scale)
        $height = [int]($script:PanelHeightDip * $scale)
        $horizontalWidth = [int]($script:HorizontalPanelWidthDip * $scale)
        $horizontalHeight = [int]($script:HorizontalPanelHeightDip * $scale)
        $visual.Left = 740; $visual.Right = 780; $visual.Top = 520; $visual.Bottom = 590
        $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, 4)
        Assert-Equal "双球 $scale 缩放底部竖排空间不足" $rect.Equals([NativeWindow+RECT]::new()) $true
        Assert-Equal "双球 $scale 缩放底部切为横排" ([NativeWindow]::GetOverlayLayout($pet, $width, $height, 4)) ([OverlayLayout]::Horizontal)
        $horizontalRect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, 4, [OverlayLayout]::Horizontal)
        Assert-Equal "双球 $scale 缩放底部横排放在上方" $horizontalRect.Bottom ($visual.Top - 8)
        $visual.Top = 0; $visual.Bottom = 60; $pet.VisualRect = $visual; $pet.ContentRect = $visual
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, 4)
        Assert-Equal "双球 $scale 缩放顶部竖排空间不足" $rect.Equals([NativeWindow+RECT]::new()) $true
        Assert-Equal "双球 $scale 缩放顶部切为横排" ([NativeWindow]::GetOverlayLayout($pet, $width, $height, 4)) ([OverlayLayout]::Horizontal)
        $horizontalRect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, 4, [OverlayLayout]::Horizontal)
        Assert-Equal "双球 $scale 缩放顶部横排放在下方" $horizontalRect.Top ($visual.Bottom + 8)
    }
    # 使用实际配置验证常态贴近角色；保留上面的 4px 用例覆盖底层定位函数。
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $width = [int][math]::Round($script:PanelWidthDip * $scale)
        $height = [int][math]::Round($script:PanelHeightDip * $scale)
        $gap = [int][math]::Round($script:PanelGapDip * $scale)
        $work.Left = 0; $work.Top = 0
        $work.Right = [int](1200 * $scale); $work.Bottom = [int](800 * $scale)
        $visual.Left = [int](500 * $scale); $visual.Right = [int](560 * $scale)
        $visual.Top = [int](350 * $scale); $visual.Bottom = [int](450 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new(); $pet.WorkArea = $work
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "常态 $scale 缩放贴近角色右侧" $rect.Left ($visual.Right + $gap)
        Assert-Equal "常态 $scale 缩放间距不超过 8 DIP" ($rect.Left - $visual.Right) $gap
        Assert-Equal "常态 $scale 缩放纵向居中" $rect.Top ($visual.Top + [int][math]::Truncate(($visual.Bottom - $visual.Top - $height) / 2.0))

        $visual.Right = $work.Right - [int](20 * $scale)
        $visual.Left = $visual.Right - [int](60 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "常态 $scale 缩放右侧不足时贴近左侧" $rect.Right ($visual.Left - $gap)
        Assert-Equal "常态 $scale 缩放左翻位于工作区" ($rect.Left -ge $work.Left -and $rect.Right -le $work.Right) $true

        # 两侧均不足时拒绝竖排，禁止横坐标钳位后压住角色。
        $work.Right = [int](180 * $scale); $work.Bottom = [int](600 * $scale)
        $visual.Left = [int](70 * $scale); $visual.Right = [int](110 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new(); $pet.WorkArea = $work
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "常态 $scale 缩放窄屏不覆盖角色" $rect.Equals([NativeWindow+RECT]::new()) $true
    }
    # 任务卡片出现后保持角色旁的横坐标，通过上下移动避让；卡片贴边平移或变宽不再横推面板。
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $width = [int][math]::Round($script:PanelWidthDip * $scale)
        $height = [int][math]::Round($script:PanelHeightDip * $scale)
        $gap = [int][math]::Round($script:PanelGapDip * $scale)
        $clearance = [int][math]::Round(8 * $scale)
        $pet.Dpi = [uint32](96 * $scale)
        foreach ($originX in @(0, -1200)) {
            $work.Left = [int]($originX * $scale); $work.Top = [int](-100 * $scale)
            $work.Right = $work.Left + [int](1200 * $scale); $work.Bottom = [int](700 * $scale)
            $pet.WorkArea = $work
            $visual.Top = [int](250 * $scale); $visual.Bottom = [int](350 * $scale)
            $content = [NativeWindow+RECT]::new()
            $content.Top = $visual.Top; $content.Bottom = [int](410 * $scale)
            foreach ($edge in @('Left', 'Right')) {
                if ($edge -eq 'Left') {
                    $visual.Left = $work.Left + [int](8 * $scale); $visual.Right = $work.Left + [int](68 * $scale)
                    $content.Left = $visual.Left; $content.Right = $work.Left + [int](228 * $scale)
                }
                else {
                    $visual.Left = $work.Right - [int](68 * $scale); $visual.Right = $work.Right - [int](8 * $scale)
                    $content.Left = $work.Right - [int](228 * $scale); $content.Right = $visual.Right
                }
                $task = [NativeWindow+RECT]@{
                    Left=$content.Left; Top=$visual.Bottom+[int](10*$scale)
                    Right=$content.Right; Bottom=$content.Bottom
                }
                $pet.VisualRect = $visual; $pet.ContentRect = $content; $pet.TaskRect = $task
                $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
                $expectedX = if ($edge -eq 'Left') { $visual.Right + $gap } else { $visual.Left - $gap - $width }
                Assert-Equal "贴 $edge 边 $scale 缩放 origin=$originX 不横向远离" $rect.Left $expectedX
                Assert-Equal "贴 $edge 边 $scale 缩放 origin=$originX 下方卡片向上避让" $rect.Bottom ($task.Top - $clearance)
                Assert-Equal "贴 $edge 边 $scale 缩放 origin=$originX 完整位于工作区" ($rect.Left -ge $work.Left -and $rect.Right -le $work.Right -and $rect.Top -ge $work.Top -and $rect.Bottom -le $work.Bottom) $true

                # 卡片翻到角色上方时，只移到卡片下缘，不移到角色下方。
                $content.Top = $visual.Top - [int](60 * $scale); $content.Bottom = $visual.Bottom
                $task.Top = $content.Top; $task.Bottom = $visual.Top - [int](10 * $scale)
                $pet.ContentRect = $content; $pet.TaskRect = $task
                $aboveRect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
                Assert-Equal "贴 $edge 边 $scale 缩放上方卡片向下避让" $aboveRect.Top ($task.Bottom + $clearance)
                Assert-Equal "贴 $edge 边 $scale 缩放上下避让保持横坐标" $aboveRect.Left $expectedX

                # 角色不移动，仅卡片横向继续变宽，不应改变面板横坐标或纵向避让位置。
                $widerContent = $content
                $widerTask = $task
                if ($edge -eq 'Left') {
                    $widerContent.Right += [int](40 * $scale); $widerTask.Right += [int](40 * $scale)
                }
                else {
                    $widerContent.Left -= [int](40 * $scale); $widerTask.Left -= [int](40 * $scale)
                }
                $pet.ContentRect = $widerContent; $pet.TaskRect = $widerTask
                $widerRect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
                Assert-Equal "贴 $edge 边 $scale 缩放卡片变宽不横推" $widerRect.Left $expectedX
                Assert-Equal "贴 $edge 边 $scale 缩放卡片变宽保持上下位置" $widerRect.Top $aboveRect.Top

                $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
                $clearedRect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
                Assert-Equal "贴 $edge 边 $scale 缩放卡片消失恢复常态横坐标" $clearedRect.Left $expectedX
                Assert-Equal "贴 $edge 边 $scale 缩放卡片消失恢复纵向居中" $clearedRect.Top ($visual.Top + [int][math]::Truncate(($visual.Bottom - $visual.Top - $height) / 2.0))

                # 还原到下方卡片，供下一轮边缘用例使用。
                $content.Top = $visual.Top; $content.Bottom = [int](410 * $scale)
                $task.Top = $visual.Bottom + [int](10 * $scale); $task.Bottom = $content.Bottom
            }
        }

        # 对侧竖排放不下时切为卡片同侧横排，不能退回卡片同侧的长竖排。
        $horizontalWidth = [int][math]::Round($script:HorizontalPanelWidthDip * $scale)
        $horizontalHeight = [int][math]::Round($script:HorizontalPanelHeightDip * $scale)
        $work.Left = 0; $work.Top = 0; $work.Right = [int](600 * $scale); $work.Bottom = [int](800 * $scale)
        $visual.Left = [int](250 * $scale); $visual.Right = [int](310 * $scale)
        $visual.Top = [int](40 * $scale); $visual.Bottom = [int](140 * $scale)
        $content.Left = [int](120 * $scale); $content.Right = [int](440 * $scale)
        $content.Top = $visual.Top; $content.Bottom = [int](200 * $scale)
        $task = [NativeWindow+RECT]@{
            Left=$content.Left; Top=[int](150*$scale); Right=$content.Right; Bottom=$content.Bottom
        }
        $pet.VisualRect = $visual; $pet.ContentRect = $content; $pet.TaskRect = $task; $pet.WorkArea = $work
        $verticalRect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "下方卡片的上方竖排不足时拒绝同侧竖排" $verticalRect.Equals([NativeWindow+RECT]::new()) $true
        $layout = [NativeWindow]::GetOverlayLayout($pet, $width, $height, $gap)
        Assert-Equal "下方卡片的对侧竖排不足时切横排" $layout ([OverlayLayout]::Horizontal)
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $layout)
        Assert-Equal "下方卡片切换后横排仍在下方" $rect.Top ($content.Bottom + $clearance)

        $visual.Top = [int](660 * $scale); $visual.Bottom = [int](760 * $scale)
        $content.Top = [int](600 * $scale); $content.Bottom = $visual.Bottom
        $task.Top = $content.Top; $task.Bottom = [int](650 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = $content; $pet.TaskRect = $task
        $verticalRect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "上方卡片的下方竖排不足时拒绝同侧竖排" $verticalRect.Equals([NativeWindow+RECT]::new()) $true
        $layout = [NativeWindow]::GetOverlayLayout($pet, $width, $height, $gap)
        Assert-Equal "上方卡片的对侧竖排不足时切横排" $layout ([OverlayLayout]::Horizontal)
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $layout)
        Assert-Equal "上方卡片切换后横排仍在上方" $rect.Bottom ($task.Top - $clearance)

        # 桌宠位于屏幕下侧时，Codex 会把任务卡片翻到角色上方；下方竖排能放下时仍沿用左翻规则。
        # TaskRect 使用真实的独立卡片边界，不把角色本身并入卡片。
        $visual.Left = [int](520 * $scale); $visual.Right = [int](580 * $scale)
        $visual.Top = [int](400 * $scale); $visual.Bottom = [int](500 * $scale)
        $task = [NativeWindow+RECT]@{
            Left=[int](260*$scale); Top=[int](300*$scale)
            Right=[int](580*$scale); Bottom=[int](360*$scale)
        }
        $pet.VisualRect = $visual; $pet.ContentRect = [NativeWindow+RECT]@{
            Left=$task.Left; Top=$task.Top; Right=$visual.Right; Bottom=$visual.Bottom
        }; $pet.TaskRect = $task
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "屏幕下侧卡片在角色上方时右侧不足仍翻到左侧" $rect.Right ($visual.Left - $gap)
        Assert-Equal "屏幕下侧卡片在角色上方时竖排贴近卡片下缘" $rect.Top ($task.Bottom + $clearance)
        Assert-Equal "屏幕下侧上方卡片避让后完整位于工作区" ($rect.Left -ge $work.Left -and $rect.Right -le $work.Right -and $rect.Top -ge $work.Top -and $rect.Bottom -le $work.Bottom) $true

        $visual.Top = [int](650 * $scale); $visual.Bottom = [int](750 * $scale)
        $task.Top = [int](40 * $scale); $task.Bottom = [int](100 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = [NativeWindow+RECT]@{
            Left=$task.Left; Top=$task.Top; Right=$visual.Right; Bottom=$visual.Bottom
        }; $pet.TaskRect = $task
        Assert-Equal "允许的对侧竖排无空间时返回横排布局" ([NativeWindow]::GetOverlayLayout($pet, $width, $height, $gap)) ([OverlayLayout]::Horizontal)
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, [OverlayLayout]::Horizontal)
        Assert-Equal "卡片同侧横排也无空间时返回隐藏标记" $rect.Equals([NativeWindow+RECT]::new()) $true
        $visual.Top = [int](350 * $scale); $visual.Bottom = [int](450 * $scale)
        $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "卡片消失后恢复显示" (($rect.Right - $rect.Left) -eq $width) $true
    }
    # 横竖布局只由当前帧是否存在完整竖排位置决定；上下侧使用同一套镜像规则。
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $pet.Dpi = [uint32](96 * $scale)
        $verticalWidth = [int][math]::Round($script:PanelWidthDip * $scale)
        $verticalHeight = [int][math]::Round($script:PanelHeightDip * $scale)
        $horizontalWidth = [int][math]::Round($script:HorizontalPanelWidthDip * $scale)
        $horizontalHeight = [int][math]::Round($script:HorizontalPanelHeightDip * $scale)
        $gap = [int][math]::Round($script:PanelGapDip * $scale)
        $clearance = [int][math]::Round(8 * $scale)
        foreach ($originX in @(0, -1200)) {
            $work = [NativeWindow+RECT]@{
                Left=[int]($originX*$scale); Top=[int](-100*$scale)
                Right=[int](($originX+1200)*$scale); Bottom=[int](700*$scale)
            }
            $pet.WorkArea = $work
            $visualWidth = [int][math]::Round(60*$scale)
            $visualHeight = [int][math]::Round(100*$scale)
            $visual.Left = $work.Left + [int][math]::Round(500*$scale)
            $visual.Right = $visual.Left + $visualWidth

            # 原 35% 分界附近仍有完整竖排空间，不能提前横排；上、下位置严格镜像。
            foreach ($ratio in @(0.35, 0.65)) {
                $centerY = $work.Top + [int][math]::Round(($work.Bottom-$work.Top)*$ratio)
                $visual.Top = $centerY - [int][math]::Truncate($visualHeight/2.0)
                $visual.Bottom = $visual.Top + $visualHeight
                $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
                $layout = [NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)
                Assert-Equal "工作区 $ratio 位置 $scale origin=$originX 有空间保持竖排" $layout ([OverlayLayout]::Vertical)
                $verticalRect = [NativeWindow]::CalculateOverlayRect($pet, $verticalWidth, $verticalHeight, $gap, $layout)
                Assert-Equal "工作区 $ratio 位置 $scale origin=$originX 竖排完整" ($verticalRect.Top -ge $work.Top -and $verticalRect.Bottom -le $work.Bottom) $true
            }

            # 靠顶时竖排自然居中位置越界，改用下方横排。
            $visual.Top = $work.Top + [int][math]::Round(8*$scale)
            $visual.Bottom = $visual.Top + $visualHeight
            $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
            $topLayout = [NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)
            Assert-Equal "顶部竖排空间不足 $scale origin=$originX 才切横排" $topLayout ([OverlayLayout]::Horizontal)
            $topRect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $topLayout)
            Assert-Equal "顶部横排 $scale origin=$originX 放在内容下方" $topRect.Top ($visual.Bottom + $clearance)
            Assert-Equal "顶部横排 $scale origin=$originX 尺寸完整" (($topRect.Right-$topRect.Left) -eq $horizontalWidth -and ($topRect.Bottom-$topRect.Top) -eq $horizontalHeight) $true

            # 靠底使用完全镜像的触发条件和上方横排位置。
            $visual.Bottom = $work.Bottom - [int][math]::Round(8*$scale)
            $visual.Top = $visual.Bottom - $visualHeight
            $pet.VisualRect = $visual; $pet.ContentRect = $visual
            $bottomLayout = [NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)
            Assert-Equal "底部竖排空间不足 $scale origin=$originX 才切横排" $bottomLayout ([OverlayLayout]::Horizontal)
            $bottomRect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $bottomLayout)
            Assert-Equal "底部横排 $scale origin=$originX 放在内容上方" $bottomRect.Bottom ($visual.Top - $clearance)
            Assert-Equal "上下横排 $scale origin=$originX 与边界距离对称" ($topRect.Top-$work.Top) ($work.Bottom-$bottomRect.Bottom)

            # 下方任务卡的对侧竖排不足时，只能切为同侧横排。
            $visual.Top = $work.Top + [int][math]::Round(80*$scale)
            $visual.Bottom = $visual.Top + $visualHeight
            $belowTask = [NativeWindow+RECT]@{
                Left=$visual.Left-[int][math]::Round(130*$scale); Top=$visual.Bottom+[int][math]::Round(10*$scale)
                Right=$visual.Right+[int][math]::Round(130*$scale); Bottom=$visual.Bottom+[int][math]::Round(70*$scale)
            }
            $belowContent = [NativeWindow+RECT]@{
                Left=$belowTask.Left; Top=$visual.Top; Right=$belowTask.Right; Bottom=$belowTask.Bottom
            }
            $pet.VisualRect = $visual; $pet.ContentRect = $belowContent; $pet.TaskRect = $belowTask
            Assert-Equal "下方任务卡 $scale origin=$originX 禁止同侧竖排" ([NativeWindow]::CalculateOverlayRect($pet, $verticalWidth, $verticalHeight, $gap).Equals([NativeWindow+RECT]::new())) $true
            $layout = [NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)
            Assert-Equal "下方任务卡 $scale origin=$originX 切换横排" $layout ([OverlayLayout]::Horizontal)
            $belowHorizontal = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $layout)
            Assert-Equal "下方任务卡 $scale origin=$originX 横排保持下方" $belowHorizontal.Top ($belowContent.Bottom + $clearance)

            # 上方任务卡使用镜像规则：下方竖排不足时，横排保持在上方。
            $visual.Bottom = $work.Bottom - [int][math]::Round(80*$scale)
            $visual.Top = $visual.Bottom - $visualHeight
            $aboveTask = [NativeWindow+RECT]@{
                Left=$visual.Left-[int][math]::Round(130*$scale); Top=$visual.Top-[int][math]::Round(70*$scale)
                Right=$visual.Right+[int][math]::Round(130*$scale); Bottom=$visual.Top-[int][math]::Round(10*$scale)
            }
            $aboveContent = [NativeWindow+RECT]@{
                Left=$aboveTask.Left; Top=$aboveTask.Top; Right=$aboveTask.Right; Bottom=$visual.Bottom
            }
            $pet.VisualRect = $visual; $pet.ContentRect = $aboveContent; $pet.TaskRect = $aboveTask
            Assert-Equal "上方任务卡 $scale origin=$originX 禁止同侧竖排" ([NativeWindow]::CalculateOverlayRect($pet, $verticalWidth, $verticalHeight, $gap).Equals([NativeWindow+RECT]::new())) $true
            $layout = [NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)
            Assert-Equal "上方任务卡 $scale origin=$originX 切换横排" $layout ([OverlayLayout]::Horizontal)
            $aboveHorizontal = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, $layout)
            Assert-Equal "上方任务卡 $scale origin=$originX 横排保持上方" $aboveHorizontal.Bottom ($aboveContent.Top - $clearance)

            # 允许的竖排与横排同侧都没有完整空间时返回空矩形。
            $visual.Top = $work.Bottom - [int][math]::Round(120*$scale)
            $visual.Bottom = $work.Bottom - [int][math]::Round(20*$scale)
            $blockedTask = [NativeWindow+RECT]@{
                Left=$visual.Left-[int][math]::Round(130*$scale); Top=$work.Top+[int][math]::Round(20*$scale)
                Right=$visual.Right+[int][math]::Round(130*$scale); Bottom=$work.Top+[int][math]::Round(80*$scale)
            }
            $pet.VisualRect = $visual; $pet.ContentRect = [NativeWindow+RECT]@{
                Left=$blockedTask.Left; Top=$blockedTask.Top; Right=$blockedTask.Right; Bottom=$visual.Bottom
            }; $pet.TaskRect = $blockedTask
            Assert-Equal "卡片配对方向都不足 $scale origin=$originX 返回横排布局" ([NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)) ([OverlayLayout]::Horizontal)
            $blockedRect = [NativeWindow]::CalculateOverlayRect($pet, $horizontalWidth, $horizontalHeight, $gap, [OverlayLayout]::Horizontal)
            Assert-Equal "卡片配对横排也不足 $scale origin=$originX 返回隐藏标记" $blockedRect.Equals([NativeWindow+RECT]::new()) $true

            # 清除卡片后当前帧立即恢复常态竖排。
            $visual.Top = $work.Top + [int][math]::Round(350*$scale)
            $visual.Bottom = $visual.Top + $visualHeight
            $pet.VisualRect = $visual; $pet.ContentRect = $visual; $pet.TaskRect = [NativeWindow+RECT]::new()
            Assert-Equal "卡片消失 $scale origin=$originX 当前帧恢复竖排" ([NativeWindow]::GetOverlayLayout($pet, $verticalWidth, $verticalHeight, $gap)) ([OverlayLayout]::Vertical)
        }
    }

    # 实机追踪位置约在工作区 64.6% 高度，竖排完整可见，不能再由固定百分比阈值误切横排。
    $tracePet = [PetWindowInfo]::new()
    $tracePet.Handle = [IntPtr]999; $tracePet.Dpi = 120
    $tracePet.WorkArea = [NativeWindow+RECT]@{ Left=2560; Top=511; Right=4480; Bottom=1543 }
    $tracePet.VisualRect = [NativeWindow+RECT]@{ Left=2934; Top=1115; Right=3066; Bottom=1235 }
    $tracePet.ContentRect = $tracePet.VisualRect; $tracePet.TaskRect = [NativeWindow+RECT]::new()
    $traceVerticalWidth = [int][math]::Round($script:PanelWidthDip*1.25)
    $traceVerticalHeight = [int][math]::Round($script:PanelHeightDip*1.25)
    Assert-Equal '实机 64.6% 高度仍有完整空间时保持竖排' ([NativeWindow]::GetOverlayLayout($tracePet, $traceVerticalWidth, $traceVerticalHeight, 10)) ([OverlayLayout]::Vertical)

    # 用户截图回归：卡片和竖排额度 UI 不得继续堆在同一方向。
    $screenshotPet = [PetWindowInfo]::new()
    $screenshotPet.Dpi = 96
    $screenshotPet.WorkArea = [NativeWindow+RECT]@{ Left=0; Top=0; Right=335; Bottom=574 }
    $screenshotPet.VisualRect = [NativeWindow+RECT]@{ Left=106; Top=50; Right=153; Bottom=140 }
    $screenshotPet.TaskRect = [NativeWindow+RECT]@{ Left=36; Top=190; Right=235; Bottom=243 }
    $screenshotPet.ContentRect = [NativeWindow+RECT]@{ Left=36; Top=50; Right=235; Bottom=243 }
    $screenshotLayout = [NativeWindow]::GetOverlayLayout($screenshotPet, 96, 232, 8)
    Assert-Equal '截图回归：下方卡片拒绝同侧竖排' $screenshotLayout ([OverlayLayout]::Horizontal)
    $screenshotRect = [NativeWindow]::CalculateOverlayRect($screenshotPet, 192, 116, 8, $screenshotLayout)
    Assert-Equal '截图回归：下方卡片改用下方横排' $screenshotRect.Top 251

    $screenshotPet.WorkArea = [NativeWindow+RECT]@{ Left=0; Top=0; Right=335; Bottom=604 }
    $screenshotPet.VisualRect = [NativeWindow+RECT]@{ Left=106; Top=425; Right=153; Bottom=535 }
    $screenshotPet.TaskRect = [NativeWindow+RECT]@{ Left=36; Top=354; Right=235; Bottom=414 }
    $screenshotPet.ContentRect = [NativeWindow+RECT]@{ Left=36; Top=354; Right=235; Bottom=560 }
    $screenshotLayout = [NativeWindow]::GetOverlayLayout($screenshotPet, 96, 232, 8)
    Assert-Equal '截图回归：上方卡片拒绝同侧竖排' $screenshotLayout ([OverlayLayout]::Horizontal)
    $screenshotRect = [NativeWindow]::CalculateOverlayRect($screenshotPet, 192, 116, 8, $screenshotLayout)
    Assert-Equal '截图回归：上方卡片改用上方横排' $screenshotRect.Bottom 346

    # 稳定角色锚点与当帧任务卡轻微相交时，仍须保持同一配对规则。
    $screenshotPet.WorkArea = [NativeWindow+RECT]@{ Left=0; Top=0; Right=335; Bottom=574 }
    $screenshotPet.VisualRect = [NativeWindow+RECT]@{ Left=106; Top=50; Right=153; Bottom=140 }
    $screenshotPet.TaskRect = [NativeWindow+RECT]@{ Left=36; Top=130; Right=235; Bottom=200 }
    $screenshotPet.ContentRect = [NativeWindow+RECT]@{ Left=36; Top=50; Right=235; Bottom=200 }
    $overlapLayout = [NativeWindow]::GetOverlayLayout($screenshotPet, 96, 232, 8)
    Assert-Equal '锚点相交回归：下方卡片仍拒绝同侧竖排' $overlapLayout ([OverlayLayout]::Horizontal)
    $overlapRect = [NativeWindow]::CalculateOverlayRect($screenshotPet, 192, 116, 8, $overlapLayout)
    Assert-Equal '锚点相交回归：下方卡片仍使用下方横排' $overlapRect.Top 208

    $screenshotPet.WorkArea = [NativeWindow+RECT]@{ Left=0; Top=0; Right=335; Bottom=604 }
    $screenshotPet.VisualRect = [NativeWindow+RECT]@{ Left=106; Top=425; Right=153; Bottom=535 }
    $screenshotPet.TaskRect = [NativeWindow+RECT]@{ Left=36; Top=354; Right=235; Bottom=435 }
    $screenshotPet.ContentRect = [NativeWindow+RECT]@{ Left=36; Top=354; Right=235; Bottom=560 }
    $overlapLayout = [NativeWindow]::GetOverlayLayout($screenshotPet, 96, 232, 8)
    Assert-Equal '锚点相交回归：上方卡片仍拒绝同侧竖排' $overlapLayout ([OverlayLayout]::Horizontal)
    $overlapRect = [NativeWindow]::CalculateOverlayRect($screenshotPet, 192, 116, 8, $overlapLayout)
    Assert-Equal '锚点相交回归：上方卡片仍使用上方横排' $overlapRect.Bottom 346
    # 本次截图的紧凑定位回归，坐标仅作为离线几何样本；不读取截图中的账户值。
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        foreach ($origin in @(0, -1200)) {
            $sample = [PetWindowInfo]::new()
            $sample.Dpi = [uint32](96 * $scale)
            $sample.WorkArea = [NativeWindow+RECT]@{ Left=$origin; Top=-100; Right=$origin+[int](600*$scale); Bottom=-100+[int](800*$scale) }
            $sample.VisualRect = [NativeWindow+RECT]@{ Left=$origin+[int](134*$scale); Top=-100+[int](130*$scale); Right=$origin+[int](194*$scale); Bottom=-100+[int](242*$scale) }
            $sample.TaskRect = [NativeWindow+RECT]@{ Left=$origin+[int](65*$scale); Top=-100+[int](48*$scale); Right=$origin+[int](265*$scale); Bottom=-100+[int](113*$scale) }
            # 按钮及装饰的下缘远于角色，不得将竖排推到它们的下方。
            $sample.ContentRect = [NativeWindow+RECT]@{ Left=$sample.TaskRect.Left; Top=$sample.TaskRect.Top; Right=$sample.TaskRect.Right; Bottom=-100+[int](285*$scale) }
            $w = [int][math]::Round(96*$scale); $h = [int][math]::Round(232*$scale); $g = [int][math]::Round(8*$scale)
            $r = [NativeWindow]::CalculateOverlayRect($sample, $w, $h, $g)
            Assert-Equal "截图紧凑回归 $scale origin=$origin 竖排贴角色右侧" $r.Left ($sample.VisualRect.Right+$g)
            Assert-Equal "截图紧凑回归 $scale origin=$origin 仅避开卡片下缘" $r.Top ($sample.TaskRect.Bottom+$g)
            Assert-Equal "截图紧凑回归 $scale origin=$origin 不掉到角色下方" ($r.Top -lt $sample.VisualRect.Bottom) $true
            Assert-Equal "截图紧凑回归 $scale origin=$origin 仍优先完整竖排" ([NativeWindow]::GetOverlayLayout($sample,$w,$h,$g)) ([OverlayLayout]::Vertical)
            # 沿工作区中线镜像，包括任务卡、角色与按钮；顶部/底部决策对称。
            $mirror = $sample.WorkArea.Top + $sample.WorkArea.Bottom
            foreach ($name in @('VisualRect','TaskRect','ContentRect')) {
                $v = $sample.$name; $t = $v.Top; $v.Top = $mirror-$v.Bottom; $v.Bottom = $mirror-$t; $sample.$name = $v
            }
            $mirrored = [NativeWindow]::CalculateOverlayRect($sample,$w,$h,$g)
            Assert-Equal "截图紧凑回归 $scale origin=$origin 上下镜像" $mirrored.Bottom ($mirror-$r.Top)
            Assert-Equal "截图紧凑回归 $scale origin=$origin 镜像横坐标不变" $mirrored.Left $r.Left
            # 最小避让后恰好能容纳竖排时不提前横排，缩小一像素才切换。
            $area = $sample.WorkArea; $area.Top = $mirrored.Top; $sample.WorkArea = $area
            Assert-Equal "竖排边界 $scale origin=$origin 刚好容纳" ([NativeWindow]::GetOverlayLayout($sample,$w,$h,$g)) ([OverlayLayout]::Vertical)
            $area.Top++; $sample.WorkArea = $area
            Assert-Equal "竖排边界 $scale origin=$origin 少一像素切换" ([NativeWindow]::GetOverlayLayout($sample,$w,$h,$g)) ([OverlayLayout]::Horizontal)
        }
    }
    # 左右都没有完整竖排宽度，但横排可在上下容纳：不得覆盖角色或直接消失。
    $sample = [PetWindowInfo]::new(); $sample.Dpi = 96
    $sample.WorkArea = [NativeWindow+RECT]@{ Left=-250; Top=-100; Right=0; Bottom=600 }
    $sample.VisualRect = [NativeWindow+RECT]@{ Left=-155; Top=200; Right=-95; Bottom=300 }
    $sample.ContentRect = $sample.VisualRect
    Assert-Equal '窄工作区两侧不足切横排' ([NativeWindow]::GetOverlayLayout($sample,96,232,8)) ([OverlayLayout]::Horizontal)
    $r = [NativeWindow]::CalculateOverlayRect($sample,192,116,8,[OverlayLayout]::Horizontal)
    Assert-Equal '窄工作区横排下方优先' $r.Top 308
    Assert-Equal '窄工作区横排完整保留' ($r.Left -ge -250 -and $r.Right -le 0 -and $r.Right-$r.Left -eq 192) $true
    # 横排不得只信任缺失/过时的 ContentRect，忽略独立任务卡或稳定角色锚点。
    $sample.TaskRect = [NativeWindow+RECT]@{ Left=-240; Top=310; Right=-10; Bottom=360 }
    $sample.ContentRect = [NativeWindow+RECT]::new()
    $r = [NativeWindow]::CalculateOverlayRect($sample,192,116,8,[OverlayLayout]::Horizontal)
    Assert-Equal '横排缺失内容边界仍包含角色和任务卡' $r.Top 368
    $sample.TaskRect = [NativeWindow+RECT]::new()
    $sample.ContentRect = [NativeWindow+RECT]@{ Left=-155; Top=220; Right=-95; Bottom=280 }
    $r = [NativeWindow]::CalculateOverlayRect($sample,192,116,8,[OverlayLayout]::Horizontal)
    Assert-Equal '横排内容小于稳定锚点仍不覆盖角色' $r.Top 308

    Write-Output '全部定位测试通过。'
    exit 0
}

function Resolve-CodexExecutable {
    $command = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($null -ne $command -and (Test-Path -LiteralPath $command.Source)) {
        return $command.Source
    }

    $binRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $binRoot) {
        $candidate = Get-ChildItem -LiteralPath $binRoot -Recurse -File -Filter codex.exe -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }

    throw '未找到 codex.exe。请先确认 Codex Desktop/CLI 已正确安装。'
}

function New-JsonLine {
    param(
        [Parameter(Mandatory = $true)][int]$Id,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $false)]$Params,
        [switch]$OmitParams
    )

    $request = [ordered]@{ id = $Id; method = $Method }
    if (-not $OmitParams) {
        $request.params = $Params
    }
    return ($request | ConvertTo-Json -Compress -Depth 8)
}

function Invoke-RateLimitProbe {
    $client = [CodexAppServerClient]::new()
    try {
        $codex = Resolve-CodexExecutable
        $client.Start($codex, $PSScriptRoot)
        $initialize = New-JsonLine -Id 1 -Method 'initialize' -Params ([ordered]@{
            clientInfo = [ordered]@{ name = 'codex-pet-quota'; version = '1.0.0' }
            capabilities = [ordered]@{ experimentalApi = $true }
        })
        $client.SendLine($initialize)

        $deadline = [DateTime]::UtcNow.AddSeconds(25)
        $sentRead = $false
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not $client.IsRunning) {
                throw 'codex app-server 在返回限额前退出。'
            }

            $line = $null
            while ($client.TryDequeue([ref]$line)) {
                try { $message = $line | ConvertFrom-Json -ErrorAction Stop }
                catch { continue }

                if ([int](Get-ObjectPropertyValue -InputObject $message -Name 'id') -eq 1 -and -not $sentRead) {
                    $client.SendLine((New-JsonLine -Id 2 -Method 'account/rateLimits/read' -OmitParams))
                    $sentRead = $true
                }
                elseif ([int](Get-ObjectPropertyValue -InputObject $message -Name 'id') -eq 2) {
                    $view = ConvertTo-QuotaViewModel -Response $message
                    $probeResult = [pscustomobject]@{
                        FiveHour = $view.FiveHour
                        Weekly = $view.Weekly
                        Credits = $view.Credits
                        Top = $view.Top
                    } | ConvertTo-Json -Depth 5
                    Write-Host $probeResult
                    if ($view.FiveHour.Available -and $view.Weekly.Available) { return 0 }
                    return 2
                }
            }
            Start-Sleep -Milliseconds 50
        }
        throw '读取 Codex 限额超时。'
    }
    finally {
        $client.Dispose()
    }
}

if ($PingSettings) { Show-PingSettings; exit 0 }
if ($CheckPingLogin) {
    $status = Invoke-PingLoginCheck (Get-PingConfiguration)
    Write-Output $status
    if ($status -eq '额度访问验证通过（未发送模型请求）') { exit 0 }
    exit 2
}

if ($ProbeOnce) {
    exit (Invoke-RateLimitProbe)
}

function New-QuotaOverlayWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    # 两球共用结构；长余额自动缩放，球体尺寸保持不变。
    $orbTemplate = @'
            <Grid x:Name="__PREFIX__Row" Grid.Row="__ROW__">
                <Grid.RowDefinitions>
                    <RowDefinition Height="88" />
                    <RowDefinition Height="4" />
                    <RowDefinition Height="16" />
                </Grid.RowDefinitions>
                <Grid x:Name="__PREFIX__Orb" Width="88" Height="88">
                    <Ellipse>
                        <Ellipse.Fill>
                            <RadialGradientBrush Center="0.5,0.6" GradientOrigin="0.3,0.18" RadiusX="0.8" RadiusY="0.8">
                                <GradientStop Color="#FF41546B" Offset="0" />
                                <GradientStop Color="#FF192735" Offset="0.55" />
                                <GradientStop Color="#FF0B111B" Offset="1" />
                            </RadialGradientBrush>
                        </Ellipse.Fill>
                    </Ellipse>
                    <Grid>
                        <Grid.Clip><EllipseGeometry Center="44,44" RadiusX="43" RadiusY="43" /></Grid.Clip>
                        <Border x:Name="__PREFIX__Fill" Height="0" Background="#FF64748B"
                                Opacity="0.40" VerticalAlignment="Bottom" />
                    </Grid>
                    <Ellipse x:Name="__PREFIX__Rim" Stroke="#FF64748B" StrokeThickness="1.5" Margin="1" />
                    <Ellipse Width="48" Height="20" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="12,7,0,0">
                        <Ellipse.Fill>
                            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                                <GradientStop Color="#38FFFFFF" Offset="0" />
                                <GradientStop Color="#00FFFFFF" Offset="1" />
                            </LinearGradientBrush>
                        </Ellipse.Fill>
                    </Ellipse>
                    <StackPanel VerticalAlignment="Center" Margin="6,0">
                        <TextBlock x:Name="__PREFIX__Label" Text="__LABEL__" Foreground="#FFE2E8F0"
                                   FontSize="12" FontWeight="SemiBold" HorizontalAlignment="Center" />
                        <Viewbox x:Name="__PREFIX__ValueBox" Height="36" MaxWidth="76" Stretch="Uniform" StretchDirection="DownOnly">
                            <TextBlock x:Name="__PREFIX__Percent" Text="—" Foreground="#FFF8FAFC"
                                       FontSize="30" FontWeight="Bold" TextAlignment="Center" />
                        </Viewbox>
                        <TextBlock x:Name="__PREFIX__Caption" Text="剩余" Foreground="#FFCBD5E1"
                                   FontSize="9" HorizontalAlignment="Center" />
                    </StackPanel>
                </Grid>
                <Border Grid.Row="2" Background="#DE111923" CornerRadius="5">
                    <Viewbox Stretch="Uniform" StretchDirection="DownOnly" Margin="3,0">
                        <TextBlock x:Name="__PREFIX__Reset" Text="正在重连" Foreground="#FFE2E8F0" FontSize="9" />
                    </Viewbox>
                </Border>
            </Grid>
'@
    $fiveXaml = $orbTemplate.Replace('__PREFIX__', 'Five').Replace('__ROW__', '0').Replace('__LABEL__', '5H')
    $weekXaml = $orbTemplate.Replace('__PREFIX__', 'Week').Replace('__ROW__', '2').Replace('__LABEL__', '周')
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Codex Pet Quota" Width="$script:PanelWidthDip" Height="$script:PanelHeightDip"
        WindowStyle="None" ResizeMode="NoResize" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" ShowActivated="False" Focusable="False" Topmost="False"
        FontFamily="Segoe UI, Microsoft YaHei UI" UseLayoutRounding="True">
    <Grid Margin="4" Tag="Vertical">
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="88" />
        </Grid.ColumnDefinitions>
        <Grid.RowDefinitions>
            <RowDefinition Height="108" />
            <RowDefinition Height="8" />
            <RowDefinition Height="108" />
        </Grid.RowDefinitions>
        $fiveXaml
        $weekXaml
    </Grid>
</Window>
"@
    $reader = [Xml.XmlNodeReader]::new($xaml)
    try { return [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Close() }
}

function Set-QuotaLayout {
    param($Window, [bool]$Horizontal)
    $layout = if ($Horizontal) { 'Horizontal' } else { 'Vertical' }
    $root = $Window.Content
    if ($root.Tag -eq $layout) { return }
    $root.RowDefinitions.Clear()
    $root.ColumnDefinitions.Clear()
    $rowHeights = if ($Horizontal) { @(108) } else { @(108, 8, 108) }
    $columnWidths = if ($Horizontal) { @(88, 8, 88) } else { @(88) }
    foreach ($height in $rowHeights) {
        $row = [Windows.Controls.RowDefinition]::new()
        $row.Height = [Windows.GridLength]::new($height)
        $root.RowDefinitions.Add($row)
    }
    foreach ($width in $columnWidths) {
        $column = [Windows.Controls.ColumnDefinition]::new()
        $column.Width = [Windows.GridLength]::new($width)
        $root.ColumnDefinitions.Add($column)
    }
    $week = $Window.FindName('WeekRow')
    [Windows.Controls.Grid]::SetRow($week, $(if ($Horizontal) { 0 } else { 2 }))
    [Windows.Controls.Grid]::SetColumn($week, $(if ($Horizontal) { 2 } else { 0 }))
    $Window.Width = if ($Horizontal) { $script:HorizontalPanelWidthDip } else { $script:PanelWidthDip }
    $Window.Height = if ($Horizontal) { $script:HorizontalPanelHeightDip } else { $script:PanelHeightDip }
    $root.Tag = $layout
}

function Get-MetricColor {
    param([Parameter(Mandatory = $true)][int]$Remaining)
    if ($Remaining -gt 50) { return '#FF2DD4BF' }
    if ($Remaining -ge 20) { return '#FFF59E0B' }
    return '#FFEF4444'
}

function Set-QuotaRow {
    param(
        [Parameter(Mandatory = $true)]$Metric,
        [Parameter(Mandatory = $true)]$Window,
        [Parameter(Mandatory = $true)][ValidateSet('Five', 'Week')][string]$Prefix
    )
    $value = $Window.FindName($Prefix + 'Percent')
    $fill = $Window.FindName($Prefix + 'Fill')
    $label = $Window.FindName($Prefix + 'Label')
    $caption = $Window.FindName($Prefix + 'Caption')
    $rim = $Window.FindName($Prefix + 'Rim')
    $resetText = $Window.FindName($Prefix + 'Reset')
    $label.Text = $(if ($Prefix -eq 'Five') { '5H' } else { '周' })
    $caption.Text = '剩余'
    $fill.Height = 0
    $value.Text = '—'
    $color = '#FF64748B'
    $resetText.Text = $Metric.ResetText
    if ($Metric.Available) {
        $value.Text = $Metric.DisplayText
        if ($Metric.Kind -eq 'Credits') {
            $label.Text = '积分'
            $caption.Text = $(if ($Metric.Unlimited) { '不限量' } else { '余额' })
            # 积分没有总额度分母，不将绝对余额伪装成百分比或水位。
            $color = '#FFA78BFA'
            if (-not $Metric.Unlimited -and $Metric.Balance -le 0) { $color = '#FFEF4444' }
        }
        else {
            $color = Get-MetricColor -Remaining $Metric.RemainingPercent
            $fill.Height = 88.0 * $Metric.RemainingPercent / 100.0
        }
    }
    $brush = [Windows.Media.BrushConverter]::new().ConvertFromString($color)
    $fill.Background = $brush
    $rim.Stroke = $brush
    $value.Foreground = [Windows.Media.BrushConverter]::new().ConvertFromString(
        $(if ($Metric.Available) { '#FFF8FAFC' } else { '#FF94A3B8' }))
}

function Set-QuotaView {
    param($Window, $View)
    Set-QuotaRow -Metric $View.Top -Window $Window -Prefix Five
    Set-QuotaRow -Metric $View.Weekly -Window $Window -Prefix Week
}

if ($UiSelfTest) {
    $testWindow = New-QuotaOverlayWindow
    try {
        $root = $testWindow.Content
        $size = [Windows.Size]::new($script:PanelWidthDip, $script:PanelHeightDip)
        $response = [pscustomobject]@{
            rateLimits = [pscustomobject]@{
                primary = [pscustomobject]@{ usedPercent = 16; windowDurationMins = 300; resetsAt = 1789000000 }
                secondary = [pscustomobject]@{ usedPercent = 30; windowDurationMins = 10080; resetsAt = 1789500000 }
                credits = [pscustomobject]@{ hasCredits = $true; unlimited = $false; balance = '783.7973420000' }
            }
        }
        if ($PreviewDirectory) { [void][IO.Directory]::CreateDirectory($PreviewDirectory) }
        foreach ($mode in @('quota', 'credits', 'empty', 'large', 'unlimited', 'reconnecting', 'restored')) {
            $response.rateLimits.primary.usedPercent = 100
            $response.rateLimits.credits.unlimited = $false
            $response.rateLimits.credits.balance = '783.7973420000'
            switch ($mode) {
                'quota' { $response.rateLimits.primary.usedPercent = 16 }
                'empty' { $response.rateLimits.credits.balance = '0' }
                'large' { $response.rateLimits.credits.balance = '12345678.99' }
                'unlimited' { $response.rateLimits.credits.unlimited = $true }
                'reconnecting' { $response.rateLimits.primary.usedPercent = $null; $response.rateLimits.secondary.usedPercent = $null }
                'restored' { $response.rateLimits.primary.usedPercent = 0; $response.rateLimits.secondary.usedPercent = 30 }
            }
            $testView = ConvertTo-QuotaViewModel $response
            Set-QuotaView -Window $testWindow -View $testView
            $root.Measure($size)
            $root.Arrange([Windows.Rect]::new($size))
            $root.UpdateLayout()
            $fiveOrb = $testWindow.FindName('FiveOrb')
            $weekOrb = $testWindow.FindName('WeekOrb')
            $origin = [Windows.Point]::new(0, 0)
            $fivePoint = $fiveOrb.TranslatePoint($origin, $root)
            $weekPoint = $weekOrb.TranslatePoint($origin, $root)
            Assert-Equal "$mode 双球纵向排列" ($weekPoint.Y -gt ($fivePoint.Y + $fiveOrb.ActualHeight)) $true
            Assert-Equal "$mode 双球水平居中" $fivePoint.X $weekPoint.X
            Assert-Equal "$mode 球体等宽等高" $fiveOrb.ActualWidth $fiveOrb.ActualHeight
            Assert-Equal "$mode 球内字号显著放大" $testWindow.FindName('FivePercent').FontSize 30
            Assert-Equal "$mode 长数字限定在球内" ($testWindow.FindName('FiveValueBox').ActualWidth -le 76) $true
            if ($testView.Top.Kind -eq 'Credits') {
                Assert-Equal "$mode 球下方保留 5H 重置时间" $testWindow.FindName('FiveReset').Text ('5H ' + $testView.FiveHour.ResetText)
            }
            switch ($mode) {
                'quota' {
                    Assert-Equal '正常额度标签' $testWindow.FindName('FiveLabel').Text '5H'
                    Assert-Equal '正常额度数值' $testWindow.FindName('FivePercent').Text '84%'
                    Assert-Equal '水位高度' $testWindow.FindName('FiveFill').Height (88.0 * 0.84)
                }
                'credits' {
                    Assert-Equal '积分标签' $testWindow.FindName('FiveLabel').Text '积分'
                    Assert-Equal '积分实际余额' $testWindow.FindName('FivePercent').Text '783.8'
                    Assert-Equal '积分不显示虚构水位' $testWindow.FindName('FiveFill').Height 0
                }
                'empty' { Assert-Equal '0 积分警示颜色' ($testWindow.FindName('FiveRim').Stroke.ToString()) '#FFEF4444' }
                'unlimited' { Assert-Equal '无限积分显示' $testWindow.FindName('FivePercent').Text '∞' }
                'reconnecting' {
                    Assert-Equal '断线后清除积分数值' $testWindow.FindName('FivePercent').Text '—'
                    Assert-Equal '断线后恢复 5H 标签' $testWindow.FindName('FiveLabel').Text '5H'
                }
                'restored' {
                    Assert-Equal '恢复后额度数值' $testWindow.FindName('FivePercent').Text '100%'
                    Assert-Equal '恢复后重置说明' ($testWindow.FindName('FiveReset').Text -match '^重置 ') $true
                }
            }
            foreach ($horizontal in @($true, $false)) {
                Set-QuotaLayout -Window $testWindow -Horizontal $horizontal
                $layoutSize = [Windows.Size]::new($testWindow.Width, $testWindow.Height)
                $root.Measure($layoutSize)
                $root.Arrange([Windows.Rect]::new($layoutSize))
                $root.UpdateLayout()
                $fivePoint = $fiveOrb.TranslatePoint($origin, $root)
                $weekPoint = $weekOrb.TranslatePoint($origin, $root)
                $layoutName = if ($horizontal) { '横排' } else { '恢复竖排' }
                if ($horizontal) {
                    Assert-Equal "$mode $layoutName 双球左右排列" ($weekPoint.X -gt ($fivePoint.X + $fiveOrb.ActualWidth) -and $weekPoint.Y -eq $fivePoint.Y) $true
                    Assert-Equal "$mode $layoutName 高度减半" $testWindow.Height $script:HorizontalPanelHeightDip
                }
                else {
                    Assert-Equal "$mode $layoutName 双球上下排列" ($weekPoint.Y -gt ($fivePoint.Y + $fiveOrb.ActualHeight) -and $weekPoint.X -eq $fivePoint.X) $true
                    Assert-Equal "$mode $layoutName 恢复宽度" $testWindow.Width $script:PanelWidthDip
                }
                Assert-Equal "$mode $layoutName 球体尺寸不变" $fiveOrb.ActualWidth 88.0
                $weekReset = $testWindow.FindName('WeekReset')
                $resetPoint = $weekReset.TranslatePoint($origin, $root)
                Assert-Equal "$mode $layoutName 重置文字仍在窗口内" ($resetPoint.X -ge 0 -and $resetPoint.Y -ge 0 -and $resetPoint.X+$weekReset.ActualWidth -le $layoutSize.Width -and $resetPoint.Y+$weekReset.ActualHeight -le $layoutSize.Height) $true
                if ($PreviewDirectory) {
                    $scales = @(1.0)
                    if ($mode -eq 'quota' -or $mode -eq 'credits' -or $mode -eq 'reconnecting') { $scales = @(1.0, 1.25, 1.5, 2.0) }
                    foreach ($scale in $scales) {
                        $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
                            [int]($layoutSize.Width * $scale), [int]($layoutSize.Height * $scale),
                            96.0 * $scale, 96.0 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
                        $bitmap.Render($root)
                        $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                        $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                        $prefix = if ($horizontal) { 'horizontal-' } else { '' }
                        $output = Join-Path $PreviewDirectory ($prefix + "$mode-" + [int]($scale * 100) + '.png')
                        $stream = [IO.File]::Create($output)
                        try { $encoder.Save($stream) } finally { $stream.Dispose() }
                    }
                }
            }
        }
        # 使用全透明测试窗验证原生定位链路，不移动桌宠、不读取账户。
        $testWindow.Opacity = 0
        $testWindow.Show()
        $testHandle = ([Windows.Interop.WindowInteropHelper]::new($testWindow)).Handle
        $testVisualScale = [Windows.PresentationSource]::FromVisual($testWindow).CompositionTarget.TransformToDevice.M11
        $flags = [Reflection.BindingFlags]'NonPublic, Static'
        $isVisible = [NativeWindow].GetMethod('IsWindowVisible', $flags)
        $getRect = [NativeWindow].GetMethod('GetWindowRect', $flags)
        $positionPet = [PetWindowInfo]::new()
        $zPetWindow = [Windows.Window]::new()
        $zPetWindow.WindowStyle = 'None'; $zPetWindow.AllowsTransparency = $true
        $zPetWindow.Opacity = 0; $zPetWindow.ShowActivated = $false
        $zPetWindow.ShowInTaskbar = $false
        $zPetWindow.Show()
        $positionPet.Handle = ([Windows.Interop.WindowInteropHelper]::new($zPetWindow)).Handle
        $positionPet.Dpi = 96
        $positionPet.VisualRect = [NativeWindow+RECT]@{ Left=8; Top=350; Right=68; Bottom=450 }
        $positionPet.ContentRect = [NativeWindow+RECT]@{ Left=8; Top=350; Right=228; Bottom=510 }
        $positionPet.TaskRect = [NativeWindow+RECT]@{ Left=8; Top=470; Right=228; Bottom=510 }
        $positionPet.WorkArea = [NativeWindow+RECT]@{ Left=0; Top=0; Right=1200; Bottom=800 }
        foreach ($state in @('visible', 'blocked', 'restored')) {
            $positionPet.ContentRect = if ($state -eq 'blocked') { $positionPet.WorkArea } else { [NativeWindow+RECT]@{ Left=8; Top=350; Right=228; Bottom=510 } }
            $positionPet.TaskRect = if ($state -eq 'blocked') { $positionPet.WorkArea } else { [NativeWindow+RECT]@{ Left=8; Top=470; Right=228; Bottom=510 } }
            [NativeWindow]::PositionOverlay($testHandle, $positionPet, $script:PanelWidthDip, $script:PanelHeightDip, $script:PanelGapDip, $testVisualScale)
            Assert-Equal "原生窗口 $state 可见状态" ($isVisible.Invoke($null, [object[]]@($testHandle))) ($state -ne 'blocked')
            if ($state -ne 'blocked') {
                $rectArgs = [object[]]@($testHandle, [NativeWindow+RECT]::new())
                Assert-Equal "原生窗口 $state 读取实际坐标" ($getRect.Invoke($null, $rectArgs)) $true
                $expected = [NativeWindow]::CalculateOverlayRect($positionPet, [int][math]::Round($script:PanelWidthDip*$testVisualScale), [int][math]::Round($script:PanelHeightDip*$testVisualScale), [int]$script:PanelGapDip)
                Assert-Equal "原生窗口 $state 保留信息框边界" ($rectArgs[1].Equals($expected)) $true
            }
        }
        # 横竖切换同时验证原生窗口大小，避免只换坐标却仍保留竖排尺寸。
        foreach ($layout in @([OverlayLayout]::Horizontal, [OverlayLayout]::Vertical)) {
            Set-QuotaLayout -Window $testWindow -Horizontal ($layout -eq [OverlayLayout]::Horizontal)
            $widthDip = $testWindow.Width; $heightDip = $testWindow.Height
            $expected = [NativeWindow]::CalculateOverlayRect($positionPet, [int][math]::Round($widthDip*$testVisualScale), [int][math]::Round($heightDip*$testVisualScale), [int]$script:PanelGapDip, $layout)
            [NativeWindow]::PositionOverlay($testHandle, $positionPet, $widthDip, $heightDip, $script:PanelGapDip, $testVisualScale, $layout)
            $rectArgs = [object[]]@($testHandle, [NativeWindow+RECT]::new())
            Assert-Equal "原生窗口 $layout 切换后可见" ($isVisible.Invoke($null, [object[]]@($testHandle))) $true
            Assert-Equal "原生窗口 $layout 读取切换坐标" ($getRect.Invoke($null, $rectArgs)) $true
            Assert-Equal "原生窗口 $layout 横竖切换尺寸与坐标" ($rectArgs[1].Equals($expected)) $true
            Assert-Equal "原生窗口 $layout 逻辑宽度不漂移" $testWindow.Width $widthDip
            Assert-Equal "原生窗口 $layout 逻辑高度不漂移" $testWindow.Height $heightDip
        }
        # 使用真实透明 HWND 测试分组切换，不移动用户窗口、不读取账户。
        [NativeWindow]::MakeOverlayClickThrough($testHandle)
        $getWindow = [NativeWindow].GetMethod('GetWindow', $flags)
        $getStyle = [NativeWindow].GetMethod('GetWindowLongPtr', $flags)
        $getForeground = [NativeWindow].GetMethod('GetForegroundWindow', $flags)
        foreach ($topmost in @($false, $true, $false, $true, $false)) {
            $zPetWindow.Topmost = $topmost
            $foreground = $getForeground.Invoke($null, @())
            [NativeWindow]::PositionOverlay($testHandle, $positionPet, $script:PanelWidthDip, $script:PanelHeightDip, $script:PanelGapDip, $testVisualScale)
            $style = $getStyle.Invoke($null, [object[]]@($testHandle, -20)).ToInt64()
            Assert-Equal "Z 序 topmost=$topmost 分组一致" (($style -band 8) -ne 0) $topmost
            Assert-Equal "Z 序 topmost=$topmost 紧随宠物" ($getWindow.Invoke($null, [object[]]@($testHandle, [uint32]3))) $positionPet.Handle
            Assert-Equal "Z 序 topmost=$topmost 不抢焦点" ($getForeground.Invoke($null, @())) $foreground
            Assert-Equal "Z 序 topmost=$topmost 保留穿透" (($style -band 0x08000020) -eq 0x08000020) $true
        }
        $zPetWindow.Hide()
        [NativeWindow]::PositionOverlay($testHandle, $positionPet, $script:PanelWidthDip, $script:PanelHeightDip, $script:PanelGapDip, $testVisualScale)
        Assert-Equal '宠物隐藏后球同步隐藏' ($isVisible.Invoke($null, [object[]]@($testHandle))) $false
        $zPetWindow.Show()
        [NativeWindow]::PositionOverlay($testHandle, $positionPet, $script:PanelWidthDip, $script:PanelHeightDip, $script:PanelGapDip, $testVisualScale)
        Assert-Equal '宠物恢复后球同步恢复' ($isVisible.Invoke($null, [object[]]@($testHandle))) $true
        Write-Output '全部 WPF 渲染测试通过。'
    }
    finally { if ($null -ne $zPetWindow) { $zPetWindow.Close() }; $testWindow.Close() }
    exit 0
}

$createdNew = $false
$mutex = [Threading.Mutex]::new($true, $script:MutexName, [ref]$createdNew)
if (-not $createdNew) {
    $mutex.Dispose()
    exit 0
}

$stopEvent = [Threading.EventWaitHandle]::new($false, [Threading.EventResetMode]::ManualReset, $script:StopEventName)
$client = [CodexAppServerClient]::new()

try {
    [NativeWindow]::EnablePerMonitorDpiAwareness()
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    $application = [Windows.Application]::new()
    $application.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown

    $window = New-QuotaOverlayWindow

    $script:OverlayHandle = [IntPtr]::Zero
    $script:LastPetHandle = [IntPtr]::Zero
    $script:OverlayVisible = $false
    $script:Initialized = $false
    $script:ReadPending = $false
    $script:ResponseDeadline = [DateTime]::MinValue
    $script:NextReadAt = [DateTime]::MinValue
    $script:NextRestartAt = [DateTime]::MinValue
    $script:RestartIndex = 0
    $script:RequestId = 1
    $restartDelays = @(5, 15, 30, 60)
    Initialize-QuotaPing
    $codexExecutable = if ($script:PingConfiguration.Enabled -and $script:PingConfiguration.Valid) { Resolve-PingCodexExecutable } else { Resolve-CodexExecutable }

    function Set-ReconnectingUi {
        $unavailable = [pscustomobject]@{ Available = $false; ResetText = '正在重连' }
        Set-QuotaRow -Metric $unavailable -Window $window -Prefix Five
        Set-QuotaRow -Metric $unavailable -Window $window -Prefix Week
    }

    function Start-AppServer {
        try {
            if ($script:PingConfiguration.Enabled -and $script:PingConfiguration.Valid) {
                $client.StartWithHome($codexExecutable, $PSScriptRoot, $script:PingConfiguration.CodexHome)
            }
            else { $client.Start($codexExecutable, $PSScriptRoot) }
            $script:Initialized = $false
            $script:ReadPending = $false
            $script:ResponseDeadline = [DateTime]::UtcNow.AddSeconds(25)
            $script:RequestId = 1
            $initialize = New-JsonLine -Id $script:RequestId -Method 'initialize' -Params ([ordered]@{
                clientInfo = [ordered]@{ name = 'codex-pet-quota'; version = '1.0.0' }
                capabilities = [ordered]@{ experimentalApi = $true }
            })
            $client.SendLine($initialize)
            $script:NextRestartAt = [DateTime]::MinValue
        }
        catch {
            $client.Stop()
            Set-ReconnectingUi
            $delay = $restartDelays[[math]::Min($script:RestartIndex, $restartDelays.Count - 1)]
            $script:RestartIndex = [math]::Min($script:RestartIndex + 1, $restartDelays.Count - 1)
            $script:NextRestartAt = [DateTime]::UtcNow.AddSeconds($delay)
        }
    }

    function Stop-AppServerForRetry {
        # 断线后重新积累候选证据；不跨连接保留短轮询锚点。
        $script:PingReadSchedule = New-PingReadSchedule
        $script:PingState.PreviousAt = 0L
        $script:PingState.PreviousReset = 0L
        $client.Stop()
        $script:Initialized = $false
        $script:ReadPending = $false
        $script:ResponseDeadline = [DateTime]::MinValue
        Set-ReconnectingUi
        $delay = $restartDelays[[math]::Min($script:RestartIndex, $restartDelays.Count - 1)]
        $script:RestartIndex = [math]::Min($script:RestartIndex + 1, $restartDelays.Count - 1)
        $script:NextRestartAt = [DateTime]::UtcNow.AddSeconds($delay)
    }

    function Send-RateLimitRead {
        if (-not $client.IsRunning -or -not $script:Initialized -or $script:ReadPending) {
            return
        }
        $script:RequestId++
        $client.SendLine((New-JsonLine -Id $script:RequestId -Method 'account/rateLimits/read' -OmitParams))
        $script:ReadPending = $true
        if ($script:PingRuntimeEnabled) { Write-PingEvent 'quota_read_started' ('rpc_' + $script:RequestId) }
        $script:ResponseDeadline = [DateTime]::UtcNow.AddSeconds(25)
    }

    $window.Add_SourceInitialized({
        $helper = [Windows.Interop.WindowInteropHelper]::new($window)
        $script:OverlayHandle = $helper.Handle
        [NativeWindow]::MakeOverlayClickThrough($script:OverlayHandle)
    })

    $timer = [Windows.Threading.DispatcherTimer]::new()
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $timer.Add_Tick({
        if ($stopEvent.WaitOne(0)) {
            $window.Close()
            return
        }

        Update-QuotaPingProcess

        $pet = [NativeWindow]::FindPetWindow($script:LastPetHandle)
        if ($null -eq $pet) {
            $script:LastPetHandle = [IntPtr]::Zero
            if ($script:OverlayVisible) {
                $window.Hide()
                $script:OverlayVisible = $false
            }
        }
        else {
            $script:LastPetHandle = $pet.Handle
            $positionPet = [NativeWindow]::GetAnchoredPet($pet)
            if (-not $script:OverlayVisible) {
                $window.Show()
                $script:OverlayVisible = $true
                if ($script:OverlayHandle -eq [IntPtr]::Zero) {
                    $script:OverlayHandle = ([Windows.Interop.WindowInteropHelper]::new($window)).Handle
                    [NativeWindow]::MakeOverlayClickThrough($script:OverlayHandle)
                }
            }
            $presentationSource = [Windows.PresentationSource]::FromVisual($window)
            $overlayVisualScale = 1.0
            if ($null -ne $presentationSource -and $null -ne $presentationSource.CompositionTarget) {
                $overlayVisualScale = $presentationSource.CompositionTarget.TransformToDevice.M11
            }
            # 每一帧先尝试完整竖排；只有当前几何确实放不下时才改为横排。
            # 不缓存上一次方向，因此回到有空间的位置会立即恢复竖排，上下侧使用同一判定。
            $verticalWidthPixels = [int][math]::Round($script:PanelWidthDip * $overlayVisualScale)
            $verticalHeightPixels = [int][math]::Round($script:PanelHeightDip * $overlayVisualScale)
            $gapPixels = [int][math]::Round($script:PanelGapDip * ($pet.Dpi / 96.0))
            $layout = [NativeWindow]::GetOverlayLayout($positionPet, $verticalWidthPixels, $verticalHeightPixels, $gapPixels)
            $horizontal = $layout -eq [OverlayLayout]::Horizontal
            Set-QuotaLayout -Window $window -Horizontal $horizontal
            $widthDip = if ($horizontal) { $script:HorizontalPanelWidthDip } else { $script:PanelWidthDip }
            $heightDip = if ($horizontal) { $script:HorizontalPanelHeightDip } else { $script:PanelHeightDip }
            [NativeWindow]::PositionOverlay(
                $script:OverlayHandle,
                $positionPet,
                $widthDip,
                $heightDip,
                $script:PanelGapDip,
                $overlayVisualScale,
                $layout
            )
        }

        if (-not $client.IsRunning) {
            if ($script:NextRestartAt -eq [DateTime]::MinValue) {
                Stop-AppServerForRetry
            }
            elseif ([DateTime]::UtcNow -ge $script:NextRestartAt) {
                Start-AppServer
            }
            return
        }

        $line = $null
        while ($client.TryDequeue([ref]$line)) {
            try { $message = $line | ConvertFrom-Json -ErrorAction Stop }
            catch { continue }

            $idValue = Get-ObjectPropertyValue -InputObject $message -Name 'id'
            if ($null -eq $idValue) {
                continue
            }

            $id = [int]$idValue
            $errorValue = Get-ObjectPropertyValue -InputObject $message -Name 'error'
            if ($null -ne $errorValue) {
                Stop-AppServerForRetry
                break
            }

            if ($id -eq 1 -and -not $script:Initialized) {
                $script:Initialized = $true
                $script:NextReadAt = [DateTime]::UtcNow
                $script:ResponseDeadline = [DateTime]::MinValue
                continue
            }

            if ($script:ReadPending -and $id -eq $script:RequestId) {
                if ($script:PingRuntimeEnabled) { Write-PingEvent 'quota_read_received' ('rpc_' + $id) }
                $script:ReadPending = $false
                $script:ResponseDeadline = [DateTime]::MinValue
                try {
                    $view = ConvertTo-QuotaViewModel -Response $message
                    Set-QuotaRow -Metric $view.Top -Window $window -Prefix Five
                    Set-QuotaRow -Metric $view.Weekly -Window $window -Prefix Week
                    if ($view.FiveHour.Available -or $view.Weekly.Available) {
                        $script:RestartIndex = 0
                    }
                    $script:NextReadAt = [DateTime]::UtcNow.AddSeconds(60)
                    Update-QuotaPingSnapshot $message
                }
                catch {
                    Stop-AppServerForRetry
                    break
                }
            }
        }

        if ($script:ResponseDeadline -ne [DateTime]::MinValue -and [DateTime]::UtcNow -ge $script:ResponseDeadline) {
            Stop-AppServerForRetry
            return
        }

        if ($client.IsRunning -and $script:Initialized -and -not $script:ReadPending -and [DateTime]::UtcNow -ge $script:NextReadAt) {
            try { Send-RateLimitRead }
            catch { Stop-AppServerForRetry }
        }
    })

    $window.Add_Closed({
        $timer.Stop()
        $client.Stop()
        $application.Shutdown()
    })

    Set-ReconnectingUi
    $helper = [Windows.Interop.WindowInteropHelper]::new($window)
    $script:OverlayHandle = $helper.EnsureHandle()
    [NativeWindow]::MakeOverlayClickThrough($script:OverlayHandle)
    $timer.Start()
    Start-AppServer

    [void]$application.Run()
}
finally {
    try { Stop-QuotaPing } catch { }
    try { if ($null -ne $script:PingTransport) { $script:PingTransport.Dispose() } } catch { }
    try { $client.Dispose() } catch { }
    try { $stopEvent.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
