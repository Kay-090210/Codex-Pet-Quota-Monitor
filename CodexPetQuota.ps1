#requires -version 5.1

[CmdletBinding()]
param(
    [switch]$Stop,
    [switch]$SelfTest,
    [switch]$PositionSelfTest,
    [switch]$UiSelfTest,
    [string]$PreviewDirectory,
    [switch]$ProbeOnce
)

$ErrorActionPreference = 'Stop'

$script:MutexName = 'Local\CodexPetQuotaOverlay.SingleInstance'
$script:StopEventName = 'Local\CodexPetQuotaOverlay.Stop'
$script:PanelWidthDip = 96.0
$script:PanelHeightDip = 232.0
# 为比角色更宽的任务文字卡片预留横向空间，按桌宠所在屏幕的 DPI 缩放。
$script:PanelGapDip = 84.0

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

        _process = new Process { StartInfo = psi, EnableRaisingEvents = true };
        _process.OutputDataReceived += (sender, args) =>
        {
            if (!String.IsNullOrWhiteSpace(args.Data)) _stdout.Enqueue(args.Data);
        };
        // stderr 必须持续读取以避免管道阻塞；内容不落盘，也不进入 UI。
        _process.ErrorDataReceived += (sender, args) => { var ignored = args.Data; };

        if (!_process.Start()) throw new InvalidOperationException("Failed to start codex app-server.");
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

public sealed class PetWindowInfo
{
    public IntPtr Handle { get; set; }
    public NativeWindow.RECT Rect { get; set; }
    public NativeWindow.RECT VisualRect { get; set; }
    public NativeWindow.RECT WorkArea { get; set; }
    public uint Dpi { get; set; }
}

public sealed class PetAnchorTracker
{
    private bool initialized, dragging;
    private IntPtr handle;
    private uint dpi;
    private NativeWindow.RECT anchor, previousWindow, previousVisual;

    public NativeWindow.RECT Update(PetWindowInfo pet, bool mouseDown, int cursorX, int cursorY)
    {
        if (!initialized || pet.Handle != handle || pet.Dpi != dpi)
        {
            initialized = true; handle = pet.Handle; dpi = pet.Dpi;
            anchor = pet.VisualRect; previousWindow = pet.Rect; previousVisual = pet.VisualRect;
            dragging = false;
            return anchor;
        }
        if (mouseDown && !dragging)
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
    private static readonly IntPtr HWND_TOPMOST = new IntPtr(-1);
    private static IntPtr cachedVisualHandle = IntPtr.Zero;
    private static RECT cachedVisualRelative;
    private static long cachedVisualAt;
    private static bool hasCachedVisual;
    private static int cachedVisualWidth, cachedVisualHeight;
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
        if ((exStyle & WS_EX_TOOLWINDOW) == 0 || (exStyle & WS_EX_TOPMOST) == 0 || (exStyle & WS_EX_LAYERED) == 0) return false;

        RECT rect;
        if (!GetWindowRect(hWnd, out rect)) return false;
        int width = rect.Right - rect.Left;
        int height = rect.Bottom - rect.Top;

        uint dpi = 96;
        try { dpi = GetDpiForWindow(hWnd); } catch { }
        if (dpi == 0) dpi = 96;
        if (!IsSupportedPetSize(width, height, dpi)) return false;

        RECT visualRelative;
        if (!TryGetPetVisualRelative(hWnd, width, height, out visualRelative))
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

        IntPtr monitor = MonitorFromRect(ref visualRect, MONITOR_DEFAULTTONEAREST);
        var monitorInfo = new MONITORINFO { cbSize = Marshal.SizeOf(typeof(MONITORINFO)) };
        if (!GetMonitorInfo(monitor, ref monitorInfo)) return false;

        info = new PetWindowInfo
        {
            Handle = hWnd,
            Rect = rect,
            VisualRect = visualRect,
            WorkArea = monitorInfo.rcWork,
            Dpi = dpi
        };
        return true;
    }

    public static bool TryFindPetPixels(byte[] pixels, int width, int height, out RECT visual)
    {
        visual = new RECT();
        if (width <= 0 || height <= 0 || pixels == null || pixels.LongLength < (long)width * height * 4) return false;
        // 角色、按钮和任务卡片之间有透明行；卡片可能翻到角色上方。
        // 排除扁宽卡片与小按钮，在角色形状的像素带中选择最高者。
        // 扫描整窗，不能假定角色始终位于透明容器上方 34%。
        int minX = width, maxX = -1, top = -1, bottom = -1, count = 0;
        int bestHeight = 0;
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
                if (count >= 100 && bandHeight >= 40 && bandWidth >= 12 && bandWidth <= bandHeight * 2 && bandHeight > bestHeight)
                {
                    int padding = Math.Max(2, width / 150);
                    visual = new RECT { Left = Math.Max(0, minX - padding), Top = Math.Max(0, top - padding),
                        Right = Math.Min(width, maxX + padding + 1), Bottom = Math.Min(height, bottom + padding + 1) };
                    bestHeight = bandHeight;
                }
                minX = width; maxX = -1; top = -1; bottom = -1; count = 0;
            }
        }
        return bestHeight > 0;
    }

    private static bool TryGetPetVisualRelative(IntPtr hWnd, int width, int height, out RECT visual)
    {
        long now = Environment.TickCount;
        if (hasCachedVisual && cachedVisualHandle == hWnd && cachedVisualWidth == width && cachedVisualHeight == height && now - cachedVisualAt >= 0 && now - cachedVisualAt < 250)
        {
            visual = cachedVisualRelative;
            return true;
        }

        visual = new RECT();
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

            if (!TryFindPetPixels(pixels, width, height, out visual)) { hasCachedVisual = false; return false; }
            cachedVisualHandle = hWnd;
            cachedVisualRelative = visual;
            cachedVisualAt = now;
            hasCachedVisual = true;
            cachedVisualWidth = width;
            cachedVisualHeight = height;
            return true;
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
        exStyle |= WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE;
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
        double scale = pet.Dpi / 96.0;
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
        POINT cursor;
        bool cursorAvailable = GetCursorPos(out cursor);
        RECT stable = anchorTracker.Update(pet, cursorAvailable && (GetAsyncKeyState(1) & 0x8000) != 0, cursor.X, cursor.Y);
        var anchoredPet = new PetWindowInfo { Handle = pet.Handle, Rect = pet.Rect, VisualRect = stable, WorkArea = pet.WorkArea, Dpi = pet.Dpi };
        RECT target = CalculateOverlayRect(anchoredPet, width, height, gap);

        SetWindowPos(overlay, HWND_TOPMOST, target.Left, target.Top, width, height, SWP_NOACTIVATE | SWP_SHOWWINDOW);
    }

    public static RECT CalculateOverlayRect(PetWindowInfo pet, int width, int height, int gap)
    {
        int rightX = pet.VisualRect.Right + gap;
        int leftX = pet.VisualRect.Left - gap - width;
        int x;
        if (rightX + width <= pet.WorkArea.Right) x = rightX;
        else if (leftX >= pet.WorkArea.Left) x = leftX;
        else x = Math.Max(pet.WorkArea.Left, Math.Min(rightX, pet.WorkArea.Right - width));

        int visualHeight = pet.VisualRect.Bottom - pet.VisualRect.Top;
        int y = pet.VisualRect.Top + (visualHeight - height) / 2;
        y = Math.Max(pet.WorkArea.Top, Math.Min(y, pet.WorkArea.Bottom - height));
        return new RECT { Left = x, Top = y, Right = x + width, Bottom = y + height };
    }

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hWnd);
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
        Assert-Equal -Name "识别整窗 y=$petY 角色" -Actual ([NativeWindow]::TryFindPetPixels($pixels, 200, 600, [ref]$bounds)) -Expected $true
        Assert-Equal -Name "跟随 y=$petY 而非通知卡片" -Actual $bounds.Top -Expected ($petY - 2)
        Assert-Equal -Name "角色下边界 y=$petY" -Actual $bounds.Bottom -Expected ($petY + 102)
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
        $visual.Left = 740; $visual.Right = 780; $visual.Top = 520; $visual.Bottom = 590
        $pet.VisualRect = $visual
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, 4)
        Assert-Equal "双球 $scale 缩放不重叠角色" ($rect.Right -le ($visual.Left - 4)) $true
        Assert-Equal "双球 $scale 缩放限制底部" ($rect.Bottom -le $work.Bottom) $true
        Assert-Equal "双球 $scale 缩放高度" ($rect.Bottom - $rect.Top) $height
        $visual.Top = 0; $visual.Bottom = 60; $pet.VisualRect = $visual
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, 4)
        Assert-Equal "双球 $scale 缩放限制顶部" $rect.Top 0
    }
    # 使用实际配置验证横向留白；保留上面的 4px 用例覆盖底层定位函数。
    foreach ($scale in @(1.0, 1.25, 1.5, 2.0)) {
        $width = [int][math]::Round($script:PanelWidthDip * $scale)
        $height = [int][math]::Round($script:PanelHeightDip * $scale)
        $gap = [int][math]::Round($script:PanelGapDip * $scale)
        $work.Left = 0; $work.Top = 0
        $work.Right = [int](1200 * $scale); $work.Bottom = [int](800 * $scale)
        $visual.Left = [int](500 * $scale); $visual.Right = [int](560 * $scale)
        $visual.Top = [int](350 * $scale); $visual.Bottom = [int](450 * $scale)
        $pet.VisualRect = $visual; $pet.WorkArea = $work
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "任务卡片 $scale 缩放右侧间距" $rect.Left ($visual.Right + $gap)
        # 回归场景：任务卡片右缘比角色右缘宽 75 DIP，仍需至少 8 DIP 留白。
        $cardRight = $visual.Right + [int][math]::Round(75 * $scale)
        Assert-Equal "任务卡片 $scale 缩放文字安全间距" (($rect.Left - $cardRight) -ge [int][math]::Round(8 * $scale)) $true
        Assert-Equal "任务卡片 $scale 缩放纵向锚点不变" $rect.Top ($visual.Top + [int][math]::Truncate(($visual.Bottom - $visual.Top - $height) / 2.0))

        $visual.Right = $work.Right - [int](20 * $scale)
        $visual.Left = $visual.Right - [int](60 * $scale)
        $pet.VisualRect = $visual
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "任务卡片 $scale 缩放左翻间距" $rect.Right ($visual.Left - $gap)
        $cardLeft = $visual.Left - [int][math]::Round(75 * $scale)
        Assert-Equal "任务卡片 $scale 缩放左侧文字安全间距" (($cardLeft - $rect.Right) -ge [int][math]::Round(8 * $scale)) $true
        Assert-Equal "任务卡片 $scale 缩放左翻位于工作区" ($rect.Left -ge $work.Left -and $rect.Right -le $work.Right) $true

        # 两侧均不足时仍限制屏幕边界，不把额外偏移加到最终坐标上。
        $work.Right = [int](260 * $scale); $work.Bottom = [int](600 * $scale)
        $visual.Left = [int](110 * $scale); $visual.Right = [int](170 * $scale)
        $pet.VisualRect = $visual; $pet.WorkArea = $work
        $rect = [NativeWindow]::CalculateOverlayRect($pet, $width, $height, $gap)
        Assert-Equal "任务卡片 $scale 缩放窄屏横向约束" ($rect.Left -ge $work.Left -and $rect.Right -le $work.Right) $true
    }
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

if ($ProbeOnce) {
    exit (Invoke-RateLimitProbe)
}

function New-QuotaOverlayWindow {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
    # 两球共用结构；长余额自动缩放，球体尺寸保持不变。
    $orbTemplate = @'
            <Grid Grid.Row="__ROW__">
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
        ShowInTaskbar="False" ShowActivated="False" Focusable="False" Topmost="True"
        FontFamily="Segoe UI, Microsoft YaHei UI" UseLayoutRounding="True">
    <Grid Margin="4">
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
            if ($PreviewDirectory) {
                $scales = @(1.0)
                if ($mode -eq 'quota' -or $mode -eq 'credits' -or $mode -eq 'reconnecting') { $scales = @(1.0, 1.25, 1.5, 2.0) }
                foreach ($scale in $scales) {
                    $bitmap = [Windows.Media.Imaging.RenderTargetBitmap]::new(
                        [int]($size.Width * $scale), [int]($size.Height * $scale),
                        96.0 * $scale, 96.0 * $scale, [Windows.Media.PixelFormats]::Pbgra32)
                    $bitmap.Render($root)
                    $encoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
                    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
                    $output = Join-Path $PreviewDirectory ("$mode-" + [int]($scale * 100) + '.png')
                    $stream = [IO.File]::Create($output)
                    try { $encoder.Save($stream) } finally { $stream.Dispose() }
                }
            }
        }
        Write-Output '全部 WPF 渲染测试通过。'
    }
    finally { $testWindow.Close() }
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
    $codexExecutable = Resolve-CodexExecutable

    function Set-ReconnectingUi {
        $unavailable = [pscustomobject]@{ Available = $false; ResetText = '正在重连' }
        Set-QuotaRow -Metric $unavailable -Window $window -Prefix Five
        Set-QuotaRow -Metric $unavailable -Window $window -Prefix Week
    }

    function Start-AppServer {
        try {
            $client.Start($codexExecutable, $PSScriptRoot)
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
            [NativeWindow]::PositionOverlay(
                $script:OverlayHandle,
                $pet,
                $script:PanelWidthDip,
                $script:PanelHeightDip,
                $script:PanelGapDip,
                $overlayVisualScale
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
    try { $client.Dispose() } catch { }
    try { $stopEvent.Dispose() } catch { }
    try { $mutex.ReleaseMutex() } catch { }
    try { $mutex.Dispose() } catch { }
}
