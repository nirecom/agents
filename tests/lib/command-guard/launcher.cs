// tests/lib/command-guard/launcher.cs — the Windows command guard launcher (#2590).
// command-guard-build.js compiles it once with csc.exe and copies the exe to bin/<tool>.exe for
// git, gh, glab and codex. It needs no environment: the tool is its own file name and every
// setting comes from ../guard.conf. Node's shell-less spawn on Windows finds only .exe / .com,
// and a worker-dispatch child loses NODE_OPTIONS, so an exe is the one form every route resolves.
// Git reads and fast-path writes (FastWrite) go straight to the real git; everything else runs
// `node main.js <guard dir> <tool>`.
// The tail of the original command line is passed on verbatim, so quoting is never rebuilt.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class CommandGuardLauncher
{
    const int GuardExit = @GUARD_EXIT@;
    static readonly string[] ValueGlobals = { "-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix", "--attr-source", "--list-cmds" };

    static int Main()
    {
        // The entry assembly's path, not Process.MainModule: that one walks every loaded module.
        string exe = System.Reflection.Assembly.GetEntryAssembly().Location;
        string tool = Path.GetFileNameWithoutExtension(exe).ToLowerInvariant();
        string guardDir = Path.GetDirectoryName(Path.GetDirectoryName(exe));
        string tail = Tail(Environment.CommandLine);
        Dictionary<string, string> conf = ReadConf(Path.Combine(guardDir, "guard.conf"));
        if (conf == null || !conf.ContainsKey("node") || !conf.ContainsKey("main") || !conf.ContainsKey("realgit"))
            return Hit(guardDir, tool, tail, "guard.conf is unreadable");
        try { Console.CancelKeyPress += delegate(object s, ConsoleCancelEventArgs e) { e.Cancel = true; }; }
        catch (Exception) { }
        string[] argv = Environment.GetCommandLineArgs();
        if (tool == "git" && (IsRead(argv, Get(conf, "readverbs")) || FastWrite(argv, conf)))
            return Run(conf["realgit"], tail, null, guardDir, tool, tail);
        string args = QuoteArg(conf["main"]) + " " + QuoteArg(guardDir) + " " + tool + (tail.Length > 0 ? " " + tail : "");
        return Run(conf["node"], args, conf, guardDir, tool, tail);
    }

    static string Get(Dictionary<string, string> conf, string key)
    {
        string v;
        return conf.TryGetValue(key, out v) ? v : "";
    }

    // The command line after its first word (this exe), exactly as the caller wrote it.
    static string Tail(string line)
    {
        int i = 0;
        if (line.Length > 0 && line[0] == '"')
        {
            i = line.IndexOf('"', 1);
            i = i < 0 ? line.Length : i + 1;
        }
        else
        {
            while (i < line.Length && line[i] != ' ' && line[i] != '\t') i++;
        }
        while (i < line.Length && (line[i] == ' ' || line[i] == '\t')) i++;
        return line.Substring(i);
    }

    static Dictionary<string, string> ReadConf(string file)
    {
        try
        {
            var conf = new Dictionary<string, string>();
            foreach (string raw in File.ReadAllLines(file))
            {
                int eq = raw.IndexOf('=');
                if (eq <= 0) continue;
                string key = raw.Substring(0, eq);
                if (!conf.ContainsKey(key)) conf[key] = raw.Substring(eq + 1);
                else if (key == "allowed") conf[key] += "\n" + raw.Substring(eq + 1);
            }
            return conf;
        }
        catch (Exception) { return null; }
    }

    // The verb after the global options; no verb at all (`git --version`) is a read.
    // --output writes a file, so main.js judges it whatever the verb.
    static bool IsRead(string[] argv, string readVerbs)
    {
        for (int i = 1; i < argv.Length; i++)
            if (argv[i].StartsWith("--output")) return false;
        for (int i = 1; i < argv.Length; i++)
        {
            string a = argv[i];
            if (Array.IndexOf(ValueGlobals, a) >= 0) { i++; continue; }
            if (a.StartsWith("-")) continue;
            return Array.IndexOf(readVerbs.Split(' '), a) >= 0;
        }
        return true;
    }

    // The fast write path (classify.js FAST_WRITE_VERBS): the verb after nothing but `-C <dir>` /
    // `-c <name=value>` pairs, no denied argument or variable, and the git dir, common dir and work
    // tree the real git reports with those same pairs all under the run root.
    static bool FastWrite(string[] argv, Dictionary<string, string> conf)
    {
        int v = 1;
        var where = new StringBuilder();
        while (v + 1 < argv.Length && (argv[v] == "-C" || argv[v] == "-c"))
        {
            where.Append(argv[v]).Append(' ').Append(QuoteArg(argv[v + 1])).Append(' ');
            v += 2;
        }
        if (argv.Length <= v || argv[v].Length == 0) return false;
        if (Array.IndexOf(Get(conf, "fastverbs").Split(' '), argv[v]) < 0) return false;
        string[] deny = Get(conf, "fastdeny").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        for (int i = v; i < argv.Length; i++)
            foreach (string d in deny)
                if (argv[i].StartsWith(d, StringComparison.Ordinal)) return false;
        foreach (string e in Get(conf, "fastdenyenv").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries))
            if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable(e))) return false;
        string[] roots = Get(conf, "allowed").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
        var psi = new ProcessStartInfo(conf["realgit"], where + "rev-parse --path-format=absolute --git-dir --git-common-dir --show-toplevel");
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        try
        {
            using (Process p = Process.Start(psi))
            {
                KillWithMe(p);
                p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e) { };
                p.BeginErrorReadLine();
                string text = p.StandardOutput.ReadToEnd();
                p.WaitForExit();
                if (p.ExitCode != 0) return false;
                string[] lines = text.Replace("\r", "").Split(new[] { '\n' }, StringSplitOptions.RemoveEmptyEntries);
                if (lines.Length != 3) return false;
                foreach (string t in lines)
                    if (!Inside(t, roots)) return false;
                return true;
            }
        }
        catch (Exception) { return false; }
    }

    // t sits under one of roots by name, and nothing between that root and t is a link or junction.
    static bool Inside(string t, string[] roots)
    {
        t = t.Replace('\\', '/').TrimEnd('/');
        if (t.Length < 3 || t[1] != ':' || t[2] != '/') return false;
        foreach (string seg in t.Split('/'))
            if (seg == "." || seg == "..") return false;
        foreach (string r0 in roots)
        {
            string r = r0.Replace('\\', '/').TrimEnd('/');
            if (r.Length < 3 || r[1] != ':') continue;
            if (!string.Equals(t, r, StringComparison.OrdinalIgnoreCase) && !t.StartsWith(r + "/", StringComparison.OrdinalIgnoreCase)) continue;
            string p = t;
            bool plain = true;
            while (plain && p.Length > r.Length)
            {
                try { plain = (File.GetAttributes(p) & FileAttributes.ReparsePoint) == 0; }
                catch (Exception) { plain = false; }
                p = p.Substring(0, p.LastIndexOf('/'));
            }
            if (plain) return true;
        }
        return false;
    }

    static string Quote(string s)
    {
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }

    // One argument quoted so the C runtime parses it back unchanged, backslash runs included.
    static string QuoteArg(string s)
    {
        var o = new StringBuilder("\"");
        int bs = 0;
        foreach (char c in s)
        {
            if (c == '\\') { bs++; continue; }
            o.Append('\\', c == '"' ? bs * 2 + 1 : bs).Append(c);
            bs = 0;
        }
        return o.Append('\\', bs * 2).Append('"').ToString();
    }

    static int Run(string file, string args, Dictionary<string, string> conf, string guardDir, string tool, string tail)
    {
        var psi = new ProcessStartInfo(file, args);
        psi.UseShellExecute = false;
        if (conf != null)
        {
            // main.js must not load a test's NODE_OPTIONS preload; it restores the value for git.
            string opts = Environment.GetEnvironmentVariable("NODE_OPTIONS");
            psi.EnvironmentVariables.Remove("NODE_OPTIONS");
            if (opts != null)
            {
                psi.EnvironmentVariables["_CG_NODE_OPTIONS_SET"] = "1";
                psi.EnvironmentVariables["_CG_NODE_OPTIONS"] = opts;
            }
        }
        Process child;
        try { child = Process.Start(psi); }
        catch (Exception e) { return Hit(guardDir, tool, tail, "cannot start " + file + ": " + e.Message); }
        KillWithMe(child);
        child.WaitForExit();
        return child.ExitCode;
    }

    // Fail closed: the same hit record main.js writes, from the launcher itself.
    static int Hit(string guardDir, string tool, string argv, string reason)
    {
        try
        {
            string hits = Path.Combine(guardDir, "hits");
            Directory.CreateDirectory(hits);
            string name = Process.GetCurrentProcess().Id + "-" + Guid.NewGuid().ToString("N").Substring(0, 8) + ".hit";
            string flat = argv.Replace("\r", " ").Replace("\n", " ");
            if (flat.Length > 200) flat = flat.Substring(0, 200);
            var text = new StringBuilder();
            text.Append("stub=").Append(tool).Append('\n');
            text.Append("test_id=").Append((Environment.GetEnvironmentVariable("ROOT_DECOY_TEST_ID") ?? "").Replace("\r", " ").Replace("\n", " ")).Append('\n');
            text.Append("target=").Append(Environment.CurrentDirectory.Replace('\\', '/').Replace("\r", " ").Replace("\n", " ")).Append('\n');
            text.Append("argv=").Append(flat).Append('\n');
            File.WriteAllText(Path.Combine(hits, name), text.ToString());
        }
        catch (Exception) { }
        Console.Error.WriteLine("command guard: refused " + tool + " (" + reason + ")");
        return GuardExit;
    }

    // A job object closed with this process takes the child tree with it, so a timeout that
    // kills the launcher does not leave node or git running.
    [StructLayout(LayoutKind.Sequential)]
    struct BasicLimit
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct ExtendedLimit
    {
        public BasicLimit Basic;
        public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes;
        public UIntPtr ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr attributes, string name);
    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimit info, uint size);
    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    static IntPtr job = IntPtr.Zero;

    static void KillWithMe(Process child)
    {
        try
        {
            if (job == IntPtr.Zero)
            {
                IntPtr j = CreateJobObject(IntPtr.Zero, null);
                if (j == IntPtr.Zero) return;
                var info = new ExtendedLimit();
                info.Basic.LimitFlags = 0x2000;
                if (!SetInformationJobObject(j, 9, ref info, (uint)Marshal.SizeOf(typeof(ExtendedLimit)))) return;
                job = j;
            }
            AssignProcessToJobObject(job, child.Handle);
        }
        catch (Exception) { }
    }
}
