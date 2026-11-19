// claude-notifier: быстрый мост хуков — маленький .exe вместо запуска PowerShell (~20–40 мс против ~450 мс).
//   claude-notifier-hook.exe <kind> --bridge <hook-bridge.ps1> --port <порт> --secret <секрет>
// * sessionstart: JSON хука из stdin → трею по HTTP на 127.0.0.1 (как curl у других хуков; окно сеанса трей найдёт
//   сам). Трей не отвечает — работу делает hook-bridge.ps1 (он и трей запустит).
// * permreq: если ждать решения не нужно (ответы из приложения выключены или в CLI ожидание 0 с — по умолчанию),
//   выходит сразу, без вывода: Claude показывает свой диалог без задержки. Иначе — hook-bridge.ps1 (он ждёт решения).
// * Остальное — hook-bridge.ps1 как есть (stdin, stdout, stderr и код выхода передаются насквозь).
// Никогда не мешает Claude Code: любая ошибка — тихий выход 0 (или код моста).
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

namespace ClaudeNotifier.Hook {
    public static class Program {
        public static int Main(string[] args) {
            try { return Run(args); } catch { return 0; }
        }

        static string Arg(string[] args, string name, string def) {
            for (int i = 0; i < args.Length - 1; i++) if (args[i] == name) return args[i + 1];
            return def;
        }

        static int Run(string[] args) {
            string kind = args.Length > 0 ? args[0] : "";
            if (kind == "--selftest") return 7;   // установщик проверяет, что Windows разрешает запуск
            string bridge = Arg(args, "--bridge", "");
            int port; if (!int.TryParse(Arg(args, "--port", "47611"), out port)) port = 47611;
            string secret = Arg(args, "--secret", "hook");
            byte[] input = ReadStdin();
            if (kind == "sessionstart") {
                // Трей не запущен (нет его канала) — сразу мост: он запустит трей (отказ соединения на localhost
                // в Windows ждёт ~2 с).
                if (TrayRunning() && Post(kind, input, port, secret)) return 0;
                return Delegate(bridge, kind, input);
            }
            if (kind == "permreq" && !NeedsWait(DataRoot(), Environment.GetEnvironmentVariable("CLAUDE_CODE_ENTRYPOINT"))) return 0;
            return Delegate(bridge, kind, input);
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern bool WaitNamedPipe(string name, int timeout);

        public static bool TrayRunning() {
            // Есть ли канал трея: WaitNamedPipe сразу отвечает «нет такого» (ERROR_FILE_NOT_FOUND), если трей не запущен.
            try {
                string name = @"\.\pipe\claude-notifier-" + (Environment.GetEnvironmentVariable("USERNAME") ?? Environment.UserName);
                bool ok = WaitNamedPipe(name, 1);
                return ok || System.Runtime.InteropServices.Marshal.GetLastWin32Error() != 2;
            } catch { return true; }
        }

        static byte[] ReadStdin() {
            try {
                using (Stream s = Console.OpenStandardInput())
                using (MemoryStream ms = new MemoryStream()) {
                    byte[] buf = new byte[16384]; int n;
                    while ((n = s.Read(buf, 0, buf.Length)) > 0) { ms.Write(buf, 0, n); if (ms.Length > 8 * 1024 * 1024) break; }
                    return ms.ToArray();
                }
            } catch { return new byte[0]; }
        }

        public static string DataRoot() {
            string home = Environment.GetEnvironmentVariable("CLAUDE_NOTIFIER_HOME");
            if (!string.IsNullOrEmpty(home)) return home;
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude-notifier");
        }

        // Как Invoke-NotifierPermissionHook: ответы выключены — не ждём; в приложении Claude ждём waitSeconds
        // (по умолчанию 600, 10–3600), в CLI — cliWaitSeconds (по умолчанию 0, 0–3600).
        public static bool NeedsWait(string dataRoot, string entry) {
            bool enabled = true; int wait = 600, cliWait = 0;
            try {
                string path = Path.Combine(dataRoot, "config.json");
                if (File.Exists(path)) {
                    object o = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8));
                    Dictionary<string, object> cfg = o as Dictionary<string, object>;
                    object ap;
                    if (cfg != null && cfg.TryGetValue("approvals", out ap)) {
                        Dictionary<string, object> a = ap as Dictionary<string, object>;
                        if (a != null) {
                            object v;
                            if (a.TryGetValue("enabled", out v) && v is bool) enabled = (bool)v;
                            if (a.TryGetValue("waitSeconds", out v) && v is int && (int)v >= 10 && (int)v <= 3600) wait = (int)v;
                            if (a.TryGetValue("cliWaitSeconds", out v) && v is int && (int)v >= 0 && (int)v <= 3600) cliWait = (int)v;
                        }
                    }
                }
            } catch { return true; }   // настройки не прочитать — пусть решает мост
            if (!enabled) return false;
            return (entry == "claude-desktop" ? wait : cliWait) > 0;
        }

        static bool Post(string kind, byte[] body, int port, string secret) {
            try {
                HttpWebRequest r = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/claude-notifier/hook/" + kind);
                r.Method = "POST";
                r.Proxy = null;
                r.Timeout = 3000; r.ReadWriteTimeout = 3000;
                r.KeepAlive = false;
                r.ContentType = "application/json";
                r.Headers["X-Claude-Notifier"] = secret;
                r.Headers["X-Claude-Entry"] = Environment.GetEnvironmentVariable("CLAUDE_CODE_ENTRYPOINT") ?? "";
                r.Headers["X-Claude-Host"] = Environment.GetEnvironmentVariable("CLAUDE_CODE_HOST_SESSION_ID") ?? "";
                r.ContentLength = body.Length;
                using (Stream s = r.GetRequestStream()) s.Write(body, 0, body.Length);
                using (HttpWebResponse resp = (HttpWebResponse)r.GetResponse()) return (int)resp.StatusCode >= 200 && (int)resp.StatusCode < 300;
            } catch { return false; }
        }

        // hook-bridge.ps1 с тем же stdin; его stdout и stderr — наши, код выхода — его.
        static int Delegate(string bridge, string kind, byte[] input) {
            if (string.IsNullOrEmpty(bridge) || !File.Exists(bridge)) return 0;
            string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), @"WindowsPowerShell\v1.0\powershell.exe");
            ProcessStartInfo psi = new ProcessStartInfo(ps, "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + bridge + "\" " + kind);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            using (Process p = Process.Start(psi)) {
                Stream outStream = Console.OpenStandardOutput(), errStream = Console.OpenStandardError();
                Thread to = new Thread(delegate () { Copy(p.StandardOutput.BaseStream, outStream); });
                Thread te = new Thread(delegate () { Copy(p.StandardError.BaseStream, errStream); });
                to.IsBackground = te.IsBackground = true;
                to.Start(); te.Start();
                try { p.StandardInput.BaseStream.Write(input, 0, input.Length); p.StandardInput.Close(); } catch { }
                p.WaitForExit();
                to.Join(2000); te.Join(2000);
                return p.ExitCode;
            }
        }

        static void Copy(Stream from, Stream to) {
            try {
                byte[] buf = new byte[8192]; int n;
                while ((n = from.Read(buf, 0, buf.Length)) > 0) { to.Write(buf, 0, n); to.Flush(); }
            } catch { }
        }
    }
}
