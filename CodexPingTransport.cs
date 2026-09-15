using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

// 只包装项目自带 helper；CLI 参数、环境、终端与会话判断全部由复用的实现负责。
// stdout 仅接收有界结果协议，stderr 只排空；不记录或暴露原始终端及凭证内容。
public sealed class CodexPingTransport : IDisposable
{
    private Process process;
    private IntPtr job;
    private Task reader, errorReader;
    private readonly object gate = new object();
    private int started, stopped, exitCode = -1;
    private bool finalized, completed;
    private readonly Stopwatch exitDrain = new Stopwatch();
    private bool protocolValid, reportedCompleted, dryRun;
    private string category = "session_failed", reportedCategory = "session_failed";
    public bool Completed { get { lock (gate) { Refresh(); return finalized && completed; } } }
    public bool ResultReady { get { lock (gate) { Refresh(); return finalized; } } }
    public string ResultCategory { get { lock (gate) { Refresh(); return finalized ? category : String.Empty; } } }
    public string ErrorKind { get { return ResultCategory == "authentication" ? "authentication" : String.Empty; } }
    public int ExitCode { get { lock (gate) { Refresh(); return exitCode; } } }
    public bool IsRunning { get { lock (gate) { return Refresh(); } } }

    private bool Refresh()
    {
        if (process == null || finalized) return false;
        if (!process.HasExited) return true;
        exitCode = process.ExitCode;
        // IsRunning 包含有限的结果排空阶段：调用者一旦看到 false，结果必定已定稿。
        if (!exitDrain.IsRunning) exitDrain.Start();
        if (reader != null && !reader.IsCompleted && exitDrain.ElapsedMilliseconds < 2000) return true;
        bool drained = reader != null && reader.IsCompleted && !reader.IsFaulted;
        if (drained && protocolValid) category = reportedCategory;
        completed = drained && protocolValid && reportedCompleted && !dryRun && exitCode == 0 && category == "completed";
        if (!drained || !protocolValid) category = "protocol_error";
        else if ((reportedCompleted && !completed) || (!completed && category == "completed")) category = "session_failed";
        finalized = true;
        return false;
    }
    public void Start(string executable, string workingDirectory, string codexHome, string model)
    {
        lock (gate)
        {
            if (stopped != 0 || Interlocked.Exchange(ref started, 1) != 0)
                throw new InvalidOperationException("A transport instance can only be started once.");
            if (String.IsNullOrWhiteSpace(executable) || !Path.IsPathRooted(executable) ||
                !File.Exists(executable) || !String.Equals(Path.GetExtension(executable), ".exe", StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("An existing absolute helper executable path is required.", "executable");
            if (String.IsNullOrWhiteSpace(workingDirectory) || !Path.IsPathRooted(workingDirectory) || !Directory.Exists(workingDirectory))
                throw new ArgumentException("An existing absolute working directory is required.", "workingDirectory");
            if (String.IsNullOrWhiteSpace(codexHome) || !Path.IsPathRooted(codexHome) || !Directory.Exists(codexHome))
                throw new ArgumentException("An existing absolute Codex home is required.", "codexHome");
            if (String.IsNullOrWhiteSpace(model)) model = "gpt-5.6-luna";
            try
            {
                job = CreateJobObject(IntPtr.Zero, null);
                Check(job != IntPtr.Zero, "CreateJobObject");
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = 0x2000;
                Check(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION))), "SetInformationJobObject");
                var info = new ProcessStartInfo(executable) {
                    WorkingDirectory = workingDirectory, UseShellExecute = false, CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden, RedirectStandardInput = true,
                    RedirectStandardOutput = true, RedirectStandardError = true,
                    StandardOutputEncoding = new UTF8Encoding(false), StandardErrorEncoding = new UTF8Encoding(false),
                    Arguments = "--wait-for-parent --home " + QuoteArgument(codexHome) +
                        " --workdir " + QuoteArgument(workingDirectory) + " --model " + QuoteArgument(model)
                };
                process = new Process { StartInfo = info };
                // Framework 在 Start 内创建 stdin writer，父进程的 UTF-8 BOM 会提前写入握手。
                Encoding previousInputEncoding = Console.InputEncoding;
                bool launched;
                try { Console.InputEncoding = new UTF8Encoding(false); launched = process.Start(); }
                finally { Console.InputEncoding = previousInputEncoding; }
                if (!launched) throw new InvalidOperationException("Helper did not start.");
                // helper 在收到 go 前不启动 provider，避免 Job 分配前生成未托管后代。
                Check(AssignProcessToJobObject(job, process.Handle), "AssignProcessToJobObject");
                reader = Task.Factory.StartNew(delegate { ReadProtocol(process.StandardOutput); }, CancellationToken.None,
                    TaskCreationOptions.LongRunning, TaskScheduler.Default);
                errorReader = Task.Factory.StartNew(delegate {
                    try { char[] buffer = new char[2048]; while (process.StandardError.Read(buffer, 0, buffer.Length) != 0) { } }
                    catch (IOException) { }
                }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
                // 写原始 ASCII，避免继承父进程输入编码的 BOM。
                byte[] go = Encoding.ASCII.GetBytes("go\n");
                process.StandardInput.BaseStream.Write(go, 0, go.Length);
                process.StandardInput.BaseStream.Flush();
                process.StandardInput.Close();
            }
            catch
            {
                if (process != null) { try { if (!process.HasExited) process.Kill(); } catch (InvalidOperationException) { } catch (Win32Exception) { } }
                Stop();
                throw;
            }
        }
    }

    private void ReadProtocol(StreamReader stream)
    {
        try
        {
            char[] buffer = new char[1024];
            StringBuilder text = new StringBuilder();
            bool overflow = false;
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) != 0)
            {
                if (text.Length + count <= 4096 && !overflow) text.Append(buffer, 0, count);
                else overflow = true;
            }
            if (overflow) return;
            string value = text.ToString().Trim();
            if (value.Length < 2 || value[0] != '{' || value[value.Length - 1] != '}' ||
                value.IndexOf('\n') >= 0 || value.IndexOf('\r') >= 0) return;
            var fields = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (string field in value.Substring(1, value.Length - 2).Split(','))
            {
                Match match = Regex.Match(field, "^\\s*\\\"(completed|dryRun|category|durationMs)\\\"\\s*:\\s*(true|false|(?:0|[1-9][0-9]*)|\\\"[a-z_]+\\\")\\s*$");
                if (!match.Success || fields.ContainsKey(match.Groups[1].Value)) return;
                fields.Add(match.Groups[1].Value, match.Groups[2].Value);
            }
            bool result, dry;
            long duration;
            if (fields.Count != 4 || !Boolean.TryParse(fields["completed"], out result) ||
                !Boolean.TryParse(fields["dryRun"], out dry) || !Int64.TryParse(fields["durationMs"], out duration)) return;
            string kind = fields["category"];
            if (!Regex.IsMatch(kind, "^\\\"(completed|dry_run|authentication|timeout|cli_start|session_failed|invalid_configuration)\\\"$")) return;
            reportedCategory = kind.Trim('"');
            reportedCompleted = result; dryRun = dry; protocolValid = true;
        }
        catch (IOException) { }
        catch (KeyNotFoundException) { }
    }

    private static string QuoteArgument(string value)
    {
        StringBuilder b = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1); b.Append(c); }
            else { b.Append('\\', slashes); b.Append(c); }
            slashes = 0;
        }
        b.Append('\\', slashes * 2);
        return b.Append('"').ToString();
    }

    public void Stop()
    {
        lock (gate)
        {
            if (Interlocked.Exchange(ref stopped, 1) != 0) return;
            if (job != IntPtr.Zero) { CloseHandle(job); job = IntPtr.Zero; }
            if (process != null)
            {
                try { process.WaitForExit(2000); } catch (InvalidOperationException) { }
                if (reader != null) { try { reader.Wait(2000); } catch (AggregateException) { } }
                if (errorReader != null) { try { errorReader.Wait(2000); } catch (AggregateException) { } }
                try { Refresh(); } catch (InvalidOperationException) { }
                process.Dispose(); process = null;
            }
        }
    }
    public void Dispose() { Stop(); }
    private static void Check(bool ok, string operation)
    {
        if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed.");
    }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] private struct IO_COUNTERS
    {
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
    }
    [StructLayout(LayoutKind.Sequential)] private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
    {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetInformationJobObject(IntPtr job, int informationClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION information, uint length);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
}