using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace ClaudeNotifier.Ui {
    // Вызов хука Claude Code, принятый от curl: что за хук, его JSON и окно сеанса.
    public sealed class HookCall {
        public string Kind = "";
        public string Body = "";
        public string Entry = "";         // CLAUDE_CODE_ENTRYPOINT (claude-desktop — приложение Claude)
        public string HostSession = "";   // CLAUDE_CODE_HOST_SESSION_ID
        public int CallerPid;             // процесс curl
        public int ClaudePid;             // ближайший предок claude.exe
        public long ConsoleHwnd;          // окно консоли сеанса → корневой владелец (окно Windows Terminal)
        public long WalkHwnd;             // первый предок с главным окном
        public DateTime At = DateTime.UtcNow;
    }

    // Приём хуков без PowerShell: хук запускает встроенный в Windows curl.exe (подписан Microsoft, ~20 мс),
    // тот отправляет JSON хука сюда, на 127.0.0.1. Окно сеанса находим, пока curl ещё ждёт ответа:
    // по порту соединения — процесс curl, от него — предки до claude.exe и окна, и консоль процесса.
    // Запросы без заголовка X-Claude-Notifier отклоняются: страница в браузере не может его поставить
    // без разрешения CORS, поэтому подделать событие из браузера нельзя.
    public static class HookServer {
        public static readonly ConcurrentQueue<HookCall> Calls = new ConcurrentQueue<HookCall>();
        public static readonly string[] Kinds = { "stop", "notification", "stopfailure", "prompt", "sessionend", "sessionstart" };
        public const string PathPrefix = "/claude-notifier/hook/";
        public const int MaxBody = 8 * 1024 * 1024;
        static TcpListener listener;
        static Thread thread;
        public static int Port { get; private set; }
        public static string Error { get; private set; }
        public static long Accepted, Rejected;
        public static bool Running { get { return listener != null; } }

        public static bool Start(int port) {
            if (listener != null) return true;
            try {
                TcpListener l = new TcpListener(IPAddress.Loopback, port);
                l.ExclusiveAddressUse = true;
                l.Start(32);
                listener = l; Port = port; Error = null;
            } catch (Exception e) { Error = e.Message; return false; }
            thread = new Thread(Loop);
            thread.IsBackground = true;
            thread.Name = "Hooks";
            thread.Start();
            return true;
        }

        public static void Stop() {
            TcpListener l = listener; listener = null;
            if (l != null) try { l.Stop(); } catch { }
        }

        static void Loop() {
            while (true) {
                TcpListener l = listener;
                if (l == null) return;
                TcpClient c;
                try { c = l.AcceptTcpClient(); } catch { return; }
                ThreadPool.QueueUserWorkItem(delegate { Handle(c); });
            }
        }

        static int IndexOf(byte[] b, int n, byte[] pat) {
            for (int i = 0; i + pat.Length <= n; i++) {
                int k = 0;
                while (k < pat.Length && b[i + k] == pat[k]) k++;
                if (k == pat.Length) return i;
            }
            return -1;
        }

        static void Reply(NetworkStream s, string status) {
            byte[] r = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
            try { s.Write(r, 0, r.Length); } catch { }
        }

        static void Handle(TcpClient c) {
            using (c) {
                try {
                    c.ReceiveTimeout = 5000; c.SendTimeout = 5000;
                    NetworkStream s = c.GetStream();
                    byte[] buf = new byte[16 * 1024];
                    int n = 0, headEnd = -1;
                    byte[] crlf2 = { 13, 10, 13, 10 };
                    while (headEnd < 0) {
                        if (n == buf.Length) { if (buf.Length >= 64 * 1024) { Reply(s, "431 Too Large"); return; } Array.Resize(ref buf, buf.Length * 2); }
                        int r = s.Read(buf, n, buf.Length - n);
                        if (r <= 0) return;
                        n += r;
                        headEnd = IndexOf(buf, n, crlf2);
                    }
                    string[] lines = Encoding.ASCII.GetString(buf, 0, headEnd).Split(new[] { "\r\n" }, StringSplitOptions.None);
                    string[] rl = lines[0].Split(' ');
                    Dictionary<string, string> h = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                    for (int i = 1; i < lines.Length; i++) {
                        int p = lines[i].IndexOf(':');
                        if (p > 0) h[lines[i].Substring(0, p).Trim()] = lines[i].Substring(p + 1).Trim();
                    }
                    string v;
                    // Только наш curl: свой заголовок есть, Origin (браузер) — нет.
                    if (rl.Length < 2 || rl[0] != "POST" || !h.TryGetValue("X-Claude-Notifier", out v) || v != "hook" || h.ContainsKey("Origin")) {
                        Interlocked.Increment(ref Rejected); Reply(s, "403 Forbidden"); return;
                    }
                    string path = rl[1];
                    string kind = path.StartsWith(PathPrefix) ? path.Substring(PathPrefix.Length) : "";
                    if (Array.IndexOf(Kinds, kind) < 0) { Interlocked.Increment(ref Rejected); Reply(s, "404 Not Found"); return; }
                    int len = 0;
                    if (h.TryGetValue("Content-Length", out v)) int.TryParse(v, out len);
                    if (len < 0 || len > MaxBody) { Reply(s, "413 Too Large"); return; }
                    if (h.TryGetValue("Expect", out v) && v.IndexOf("100-continue", StringComparison.OrdinalIgnoreCase) >= 0) {
                        byte[] cont = Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n");
                        s.Write(cont, 0, cont.Length);
                    }
                    byte[] body = new byte[len];
                    int have = Math.Min(len, n - (headEnd + 4));
                    Buffer.BlockCopy(buf, headEnd + 4, body, 0, have);
                    while (have < len) {
                        int r = s.Read(body, have, len - have);
                        if (r <= 0) return;
                        have += r;
                    }
                    HookCall call = new HookCall();
                    call.Kind = kind;
                    call.Body = Encoding.UTF8.GetString(body);
                    if (h.TryGetValue("X-Claude-Entry", out v)) call.Entry = v;
                    if (h.TryGetValue("X-Claude-Host", out v)) call.HostSession = v;
                    // Окно — пока curl жив (он ждёт ответа).
                    try {
                        IPEndPoint remote = (IPEndPoint)c.Client.RemoteEndPoint;
                        call.CallerPid = ProcInfo.PidByLoopbackPort(remote.Port, Port);
                        if (call.CallerPid > 0) ProcInfo.Resolve(call);
                    } catch { }
                    Calls.Enqueue(call);
                    Interlocked.Increment(ref Accepted);
                    Reply(s, "204 No Content");
                } catch { }
            }
        }
    }

    // Процессы и окна: кто подключился, его предки, окно консоли.
    public static class ProcInfo {
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_BASIC_INFORMATION {
            public IntPtr Reserved1; public IntPtr PebBaseAddress; public IntPtr Reserved2_0; public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId; public IntPtr InheritedFromUniqueProcessId;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct MIB_TCPROW_OWNER_PID { public uint State, LocalAddr, LocalPort, RemoteAddr, RemotePort, OwningPid; }
        delegate bool EnumWindowsProc(IntPtr h, IntPtr p);

        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int size, out int len);
        [DllImport("ntdll.dll", EntryPoint = "NtQueryInformationProcess")] static extern int NtQueryPtr(IntPtr h, int cls, out IntPtr value, int size, out int len);
        [DllImport("iphlpapi.dll")] static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool sort, int af, int cls, uint reserved);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out int pid);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int max);
        [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);

        static int Port16(uint p) { return (int)(((p & 0xFF) << 8) | ((p >> 8) & 0xFF)); }

        // Процесс, подключившийся к нам с порта clientPort (127.0.0.1): владелец TCP-соединения.
        public static int PidByLoopbackPort(int clientPort, int serverPort) {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, false, 2, 4 /* OWNER_PID_CONNECTIONS */, 0);
            for (int attempt = 0; attempt < 3; attempt++) {
                IntPtr mem = Marshal.AllocHGlobal(size + 4096);
                try {
                    int sz = size + 4096;
                    if (GetExtendedTcpTable(mem, ref sz, false, 2, 4, 0) != 0) { size = sz; continue; }
                    int count = Marshal.ReadInt32(mem);
                    int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                    for (int i = 0; i < count; i++) {
                        MIB_TCPROW_OWNER_PID row = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(new IntPtr(mem.ToInt64() + 4 + i * rowSize), typeof(MIB_TCPROW_OWNER_PID));
                        if (Port16(row.LocalPort) == clientPort && Port16(row.RemotePort) == serverPort) return (int)row.OwningPid;
                    }
                    return 0;
                } finally { Marshal.FreeHGlobal(mem); }
            }
            return 0;
        }

        public static int ParentPid(int pid) {
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return -1;
            try {
                PROCESS_BASIC_INFORMATION pbi = new PROCESS_BASIC_INFORMATION();
                int len;
                if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out len) != 0) return -1;
                return pbi.InheritedFromUniqueProcessId.ToInt32();
            } finally { CloseHandle(h); }
        }

        // Процесс консоли (conhost / OpenConsole), к которой подключён процесс; 0 — нет консоли.
        public static int ConsoleHostPid(int pid) {
            IntPtr h = OpenProcess(0x1000, false, pid);
            if (h == IntPtr.Zero) return 0;
            try {
                IntPtr v; int len;
                if (NtQueryPtr(h, 49 /* ProcessConsoleHostProcess */, out v, IntPtr.Size, out len) != 0) return 0;
                return (int)(v.ToInt64() & ~3L);
            } finally { CloseHandle(h); }
        }

        static string ProcName(int pid) {
            try { using (Process p = Process.GetProcessById(pid)) return p.ProcessName + ".exe"; } catch { return null; }
        }
        static long MainWindow(int pid) {
            try { using (Process p = Process.GetProcessById(pid)) return p.MainWindowHandle.ToInt64(); } catch { return 0; }
        }

        // Окно консоли процесса → корневой владелец (для Windows Terminal — окно WT), как GetConsoleWindow в хуке.
        public static long ConsoleRootWindow(int pid) {
            int host = ConsoleHostPid(pid);
            if (host <= 0) return 0;
            IntPtr found = IntPtr.Zero;
            StringBuilder sb = new StringBuilder(64);
            EnumWindows(delegate (IntPtr w, IntPtr p) {
                int wp; GetWindowThreadProcessId(w, out wp);
                if (wp != host) return true;
                sb.Length = 0; GetClassName(w, sb, sb.Capacity);
                string cls = sb.ToString();
                if (cls == "ConsoleWindowClass" || cls == "PseudoConsoleWindow") { found = w; return false; }
                return true;
            }, IntPtr.Zero);
            if (found == IntPtr.Zero) return 0;
            IntPtr root = GetAncestor(found, 3 /* GA_ROOTOWNER */);
            return (root != IntPtr.Zero ? root : found).ToInt64();
        }

        // Как Find-AncestorWindow в хуке: предки curl до первого с главным окном; по пути — claude.exe.
        public static void Resolve(HookCall call) {
            int cur = call.CallerPid;
            HashSet<int> seen = new HashSet<int>();
            for (int i = 0; i < 15; i++) {
                int parent = ParentPid(cur);
                if (parent <= 0 || seen.Contains(parent)) break;
                seen.Add(cur);
                cur = parent;
                if (call.ClaudePid == 0 && string.Equals(ProcName(cur), "claude.exe", StringComparison.OrdinalIgnoreCase)) call.ClaudePid = cur;
                long hw = MainWindow(cur);
                if (hw != 0) { call.WalkHwnd = hw; break; }
            }
            call.ConsoleHwnd = ConsoleRootWindow(call.CallerPid);
        }
    }
}
