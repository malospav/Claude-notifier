Set-StrictMode -Version 2.0

$script:MaxParentHops = 15
$script:GA_ROOTOWNER = 3
$script:SW_RESTORE = 9
$script:FLASHW_ALL_TIMERNOFG = 0x3 -bor 0xC

$script:Win32Source = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Management.Automation;
using System.Runtime.InteropServices;
using System.Text;
namespace ClaudeNotifier {
    // Лёгкий разбор JSON (мосту хуков): первый ConvertFrom-Json в Windows PowerShell 5.1 стоит ~70 мс на загрузку
    // сборки, а мост запускается на каждое событие. Результат — как у ConvertFrom-Json: объекты — PSCustomObject,
    // массивы — object[], числа — int / long / decimal, true/false, null. Ошибка разбора — FormatException.
    public static class JsonLite {
        public static object Parse(string text) { return Parse(text, false); }
        // hashtables = true: объекты — Hashtable без учёта регистра (как @{} в PowerShell), а не PSCustomObject.
        public static object Parse(string text, bool hashtables) {
            if (text == null) throw new FormatException("JSON: пусто");
            int i = 0;
            object v = Value(text, ref i, hashtables);
            Ws(text, ref i);
            if (i != text.Length) throw new FormatException("JSON: лишние символы на позиции " + i);
            return v;
        }
        static void Ws(string s, ref int i) { while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n' || s[i] == '\uFEFF')) i++; }
        static object Value(string s, ref int i, bool h) {
            Ws(s, ref i);
            if (i >= s.Length) throw new FormatException("JSON: неожиданный конец");
            char c = s[i];
            if (c == '{') return h ? (object)Table(s, ref i) : Obj(s, ref i);
            if (c == '[') return Arr(s, ref i, h);
            if (c == '"') return Str(s, ref i);
            if (c == 't' && string.CompareOrdinal(s, i, "true", 0, 4) == 0) { i += 4; return true; }
            if (c == 'f' && string.CompareOrdinal(s, i, "false", 0, 5) == 0) { i += 5; return false; }
            if (c == 'n' && string.CompareOrdinal(s, i, "null", 0, 4) == 0) { i += 4; return null; }
            return Num(s, ref i);
        }
        static PSObject Obj(string s, ref int i) {
            PSObject o = new PSObject();
            i++; Ws(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return o; }
            while (true) {
                Ws(s, ref i);
                if (i >= s.Length || s[i] != '"') throw new FormatException("JSON: ожидалось имя свойства на позиции " + i);
                string k = Str(s, ref i);
                Ws(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new FormatException("JSON: ожидалось «:» на позиции " + i);
                i++;
                object v = Value(s, ref i, false);
                if (o.Properties[k] != null) o.Properties.Remove(k);
                o.Properties.Add(new PSNoteProperty(k, v));
                Ws(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return o; }
                throw new FormatException("JSON: ожидалось «,» или «}» на позиции " + i);
            }
        }
        static System.Collections.Hashtable Table(string s, ref int i) {
            System.Collections.Hashtable o = new System.Collections.Hashtable(StringComparer.OrdinalIgnoreCase);
            i++; Ws(s, ref i);
            if (i < s.Length && s[i] == '}') { i++; return o; }
            while (true) {
                Ws(s, ref i);
                if (i >= s.Length || s[i] != '"') throw new FormatException("JSON: ожидалось имя свойства на позиции " + i);
                string k = Str(s, ref i);
                Ws(s, ref i);
                if (i >= s.Length || s[i] != ':') throw new FormatException("JSON: ожидалось «:» на позиции " + i);
                i++;
                o[k] = Value(s, ref i, true);
                Ws(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == '}') { i++; return o; }
                throw new FormatException("JSON: ожидалось «,» или «}» на позиции " + i);
            }
        }
        static object[] Arr(string s, ref int i, bool h) {
            List<object> l = new List<object>();
            i++; Ws(s, ref i);
            if (i < s.Length && s[i] == ']') { i++; return l.ToArray(); }
            while (true) {
                l.Add(Value(s, ref i, h));
                Ws(s, ref i);
                if (i < s.Length && s[i] == ',') { i++; continue; }
                if (i < s.Length && s[i] == ']') { i++; return l.ToArray(); }
                throw new FormatException("JSON: ожидалось «,» или «]» на позиции " + i);
            }
        }
        static string Str(string s, ref int i) {
            StringBuilder b = new StringBuilder();
            i++;
            while (i < s.Length) {
                char c = s[i++];
                if (c == '"') return b.ToString();
                if (c != '\\') { b.Append(c); continue; }
                if (i >= s.Length) break;
                char e = s[i++];
                switch (e) {
                    case '"': b.Append('"'); break;
                    case '\\': b.Append('\\'); break;
                    case '/': b.Append('/'); break;
                    case 'b': b.Append('\b'); break;
                    case 'f': b.Append('\f'); break;
                    case 'n': b.Append('\n'); break;
                    case 'r': b.Append('\r'); break;
                    case 't': b.Append('\t'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw new FormatException("JSON: неполный \\u");
                        b.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture)); i += 4; break;
                    default: throw new FormatException("JSON: неизвестная escape-последовательность");
                }
            }
            throw new FormatException("JSON: незакрытая строка");
        }
        static object Num(string s, ref int i) {
            int st = i;
            if (i < s.Length && (s[i] == '-' || s[i] == '+')) i++;
            bool frac = false;
            while (i < s.Length) {
                char c = s[i];
                if (c >= '0' && c <= '9') { i++; continue; }
                if (c == '.' || c == 'e' || c == 'E' || ((c == '-' || c == '+') && (s[i - 1] == 'e' || s[i - 1] == 'E'))) { frac = true; i++; continue; }
                break;
            }
            string t = s.Substring(st, i - st);
            if (t.Length == 0 || t == "-" || t == "+") throw new FormatException("JSON: ожидалось значение на позиции " + st);
            if (!frac) {
                int iv; if (int.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out iv)) return iv;
                long lv; if (long.TryParse(t, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out lv)) return lv;
            }
            decimal dv; if (decimal.TryParse(t, NumberStyles.Float, CultureInfo.InvariantCulture, out dv)) return dv;
            return double.Parse(t, NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        // Объект → JSON одной строкой (как ConvertTo-Json -Compress): PSCustomObject и словари — объекты,
        // списки — массивы, даты — ISO 8601. Первый ConvertTo-Json в PowerShell 5.1 стоит ~25 мс.
        public static string Write(object v) { StringBuilder b = new StringBuilder(256); W(b, v, 0); return b.ToString(); }
        static void W(StringBuilder b, object v, int depth) {
            if (v == null) { b.Append("null"); return; }
            PSObject po = v as PSObject;
            if (po != null) {
                if (po.BaseObject is PSCustomObject) {
                    if (depth > 12) { b.Append("null"); return; }
                    b.Append('{'); bool first = true;
                    foreach (PSPropertyInfo p in po.Properties) {
                        if (!first) b.Append(','); first = false;
                        WStr(b, p.Name); b.Append(':');
                        object pv; try { pv = p.Value; } catch { pv = null; }
                        W(b, pv, depth + 1);
                    }
                    b.Append('}'); return;
                }
                v = po.BaseObject;
            }
            if (v is string) { WStr(b, (string)v); return; }
            if (v is char) { WStr(b, v.ToString()); return; }
            if (v is bool) { b.Append((bool)v ? "true" : "false"); return; }
            if (v is DateTime) { WStr(b, ((DateTime)v).ToString("o", CultureInfo.InvariantCulture)); return; }
            if (v is Enum) { b.Append(Convert.ToInt64(v, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)); return; }
            if (v is double) { double d = (double)v; b.Append(double.IsNaN(d) || double.IsInfinity(d) ? "null" : d.ToString("R", CultureInfo.InvariantCulture)); return; }
            if (v is float) { float f = (float)v; b.Append(float.IsNaN(f) || float.IsInfinity(f) ? "null" : f.ToString("R", CultureInfo.InvariantCulture)); return; }
            if (v is int || v is long || v is short || v is byte || v is sbyte || v is uint || v is ulong || v is ushort || v is decimal) {
                b.Append(((IFormattable)v).ToString(null, CultureInfo.InvariantCulture)); return;
            }
            if (depth > 12) { b.Append("null"); return; }
            System.Collections.IDictionary dict = v as System.Collections.IDictionary;
            if (dict != null) {
                b.Append('{'); bool first = true;
                foreach (System.Collections.DictionaryEntry e in dict) {
                    if (!first) b.Append(','); first = false;
                    WStr(b, Convert.ToString(e.Key, CultureInfo.InvariantCulture)); b.Append(':');
                    W(b, e.Value, depth + 1);
                }
                b.Append('}'); return;
            }
            System.Collections.IEnumerable list = v as System.Collections.IEnumerable;
            if (list != null) {
                b.Append('['); bool first = true;
                foreach (object x in list) { if (!first) b.Append(','); first = false; W(b, x, depth + 1); }
                b.Append(']'); return;
            }
            WStr(b, Convert.ToString(v, CultureInfo.InvariantCulture));
        }
        static void WStr(StringBuilder b, string s) {
            b.Append('"');
            foreach (char c in s) {
                switch (c) {
                    case '"': b.Append("\\\""); break;
                    case '\\': b.Append("\\\\"); break;
                    case '\n': b.Append("\\n"); break;
                    case '\r': b.Append("\\r"); break;
                    case '\t': b.Append("\\t"); break;
                    default:
                        if (c < 0x20 || c == 0x2028 || c == 0x2029) b.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        else b.Append(c);
                        break;
                }
            }
            b.Append('"');
        }
    }

    public static class Win32 {
        [StructLayout(LayoutKind.Sequential)]
        public struct FLASHWINFO {
            public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct PROCESS_BASIC_INFORMATION {
            public IntPtr Reserved1; public IntPtr PebBaseAddress; public IntPtr Reserved2_0; public IntPtr Reserved2_1;
            public IntPtr UniqueProcessId; public IntPtr InheritedFromUniqueProcessId;
        }
        [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
        [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
        [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO info);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("ntdll.dll")] static extern int NtQueryInformationProcess(IntPtr h, int cls, ref PROCESS_BASIC_INFORMATION pbi, int size, out int len);

        public static bool Flash(IntPtr hwnd, uint flags) {
            FLASHWINFO f = new FLASHWINFO();
            f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
            f.hwnd = hwnd; f.dwFlags = flags; f.uCount = 5; f.dwTimeout = 0;
            return FlashWindowEx(ref f);
        }
        // PID родителя или -1. Без WMI: микросекунды вместо сотен миллисекунд.
        public static int GetParentPid(int pid) {
            IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (h == IntPtr.Zero) return -1;
            try {
                PROCESS_BASIC_INFORMATION pbi = new PROCESS_BASIC_INFORMATION();
                int len;
                if (NtQueryInformationProcess(h, 0, ref pbi, Marshal.SizeOf(pbi), out len) != 0) return -1;
                return pbi.InheritedFromUniqueProcessId.ToInt32();
            } finally { CloseHandle(h); }
        }
        // Имя образа вида "claude.exe" или null.
        public static string GetProcessName(int pid) {
            string path = GetImagePath(pid);
            if (!string.IsNullOrEmpty(path)) return System.IO.Path.GetFileName(path);
            try { using (Process p = Process.GetProcessById(pid)) { return p.ProcessName + ".exe"; } }
            catch { return null; }
        }
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
        // Можно ли беспокоить: 1 — нет экрана (заблокирован), 2 — полноэкранное приложение, 3 — Direct3D на весь экран,
        // 4 — презентация, 5 — можно, 6 — приложение из Магазина на весь экран, 7 — не беспокоить. -1 — неизвестно.
        public static int UserNotificationState() { int s; return SHQueryUserNotificationState(out s) == 0 ? s : -1; }
        [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public int dwFlags; }
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
        // Активное окно закрывает весь монитор (вместе с панелью задач) — игра, видео, презентация на весь экран.
        // Рабочий стол и панель задач не считаются.
        public static bool ForegroundFullscreen() {
            IntPtr h = GetForegroundWindow();
            if (h == IntPtr.Zero) return false;
            StringBuilder cls = new StringBuilder(64); GetClassName(h, cls, 64);
            string c = cls.ToString();
            if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
            RECT r; if (!GetWindowRect(h, out r)) return false;
            MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
            if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
            return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageNameW(IntPtr h, int flags, [Out] char[] name, ref int size);
        // Полный путь образа процесса или null — один быстрый системный вызов (Process.Path читает список модулей).
        public static string GetImagePath(int pid) {
            IntPtr h = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
            if (h == IntPtr.Zero) return null;
            try {
                char[] buf = new char[1024];
                int size = buf.Length;
                return QueryFullProcessImageNameW(h, 0, buf, ref size) ? new string(buf, 0, size) : null;
            } finally { CloseHandle(h); }
        }
        delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);
        [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int pid);
        [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hwnd, uint cmd);
        static Dictionary<int, long> mainWindows;
        // Главное окно процесса: первое видимое окно верхнего уровня без владельца (как MainWindowHandle).
        // Все окна перечисляются один раз за запуск моста — Process.GetProcessById на каждом шаге стоил дорого.
        public static long GetMainWindow(int pid) {
            if (mainWindows == null) {
                Dictionary<int, long> map = new Dictionary<int, long>();
                try {
                    EnumWindows(delegate (IntPtr hwnd, IntPtr lp) {
                        int wp; GetWindowThreadProcessId(hwnd, out wp);
                        if (!map.ContainsKey(wp) && IsWindowVisible(hwnd) && GetWindow(hwnd, 4) == IntPtr.Zero) map[wp] = hwnd.ToInt64();   // GW_OWNER
                        return true;
                    }, IntPtr.Zero);
                } catch { }
                mainWindows = map;
            }
            long h; return mainWindows.TryGetValue(pid, out h) ? h : 0;
        }
    }
}
'@

function Import-Win32Type {
    # Загружает ClaudeNotifier.Win32. Скомпилированная сборка кэшируется в
    # <каталог claude-notifier>\cache (имя содержит хэш исходника), чтобы не вызывать
    # компилятор C# при каждом запуске хука (≈ 100 мс). При любой ошибке кэша — обычный Add-Type.
    # Возвращает 'loaded' | 'cache' | 'compiled' | 'inline'.
    param([string]$CacheDir = (Join-Path $(if ($env:CLAUDE_NOTIFIER_HOME) { $env:CLAUDE_NOTIFIER_HOME } else { Join-Path $env:USERPROFILE '.claude-notifier' }) 'cache'))
    if ('ClaudeNotifier.Win32' -as [type]) { return 'loaded' }
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:Win32Source))
        $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
        $dll = Join-Path $CacheDir "ClaudeNotifier.Win32.$hash.dll"
        $result = 'cache'
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            $tmp = Join-Path $CacheDir "build.$PID.$([guid]::NewGuid().ToString('N')).dll"
            Add-Type -TypeDefinition $script:Win32Source -OutputAssembly $tmp -OutputType Library
            Move-Item -LiteralPath $tmp -Destination $dll -Force
            $result = 'compiled'
        }
        if (-not ('ClaudeNotifier.Win32' -as [type])) {
            # Загрузка из байтов: файл не блокируется и может быть перезаписан другим процессом.
            [void][System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($dll))
        }
        return $result
    }
    catch {
        if (-not ('ClaudeNotifier.Win32' -as [type])) { Add-Type -TypeDefinition $script:Win32Source }
        return 'inline'
    }
}

[void](Import-Win32Type)

# --- Тонкие обёртки над Win32 и процессами: точки подмены в тестах. ---

function Get-ConsoleRootWindow {
    $console = [ClaudeNotifier.Win32]::GetConsoleWindow()
    if ($console -eq [IntPtr]::Zero) { return [int64]0 }
    $root = [ClaudeNotifier.Win32]::GetAncestor($console, $script:GA_ROOTOWNER)
    if ($root -eq [IntPtr]::Zero) { return $console.ToInt64() }
    return $root.ToInt64()
}

$script:ProcInfoCache = @{}

function Get-ParentProcessInfo([int]$ProcessId) {
    # @{ ParentId; Name } процесса или $null. Запоминается: «вложенный Claude» и поиск окна идут по тем же предкам.
    if ($script:ProcInfoCache.ContainsKey($ProcessId)) { return $script:ProcInfoCache[$ProcessId] }
    $parent = [ClaudeNotifier.Win32]::GetParentPid($ProcessId)
    $info = $null
    if ($parent -ge 0) { $info = @{ ParentId = $parent; Name = [ClaudeNotifier.Win32]::GetProcessName($ProcessId) } }
    $script:ProcInfoCache[$ProcessId] = $info
    return $info
}

function Get-ProcessMainWindow([int]$ProcessId) {
    return [int64][ClaudeNotifier.Win32]::GetMainWindow($ProcessId)
}

function Test-Win32Window([int64]$Hwnd) { return [ClaudeNotifier.Win32]::IsWindow([IntPtr]$Hwnd) }
function Test-Win32Iconic([int64]$Hwnd) { return [ClaudeNotifier.Win32]::IsIconic([IntPtr]$Hwnd) }
function Invoke-Win32Restore([int64]$Hwnd) { [void][ClaudeNotifier.Win32]::ShowWindow([IntPtr]$Hwnd, $script:SW_RESTORE) }
function Invoke-Win32Foreground([int64]$Hwnd) { return [ClaudeNotifier.Win32]::SetForegroundWindow([IntPtr]$Hwnd) }
function Invoke-Win32Flash([int64]$Hwnd) { [void][ClaudeNotifier.Win32]::Flash([IntPtr]$Hwnd, $script:FLASHW_ALL_TIMERNOFG) }

function Find-AncestorWindow([int]$StartPid) {
    # Обходит родителей от StartPid (не включая его) до первого процесса с главным окном.
    # Возвращает @{ hwnd; claudePid }; claudePid — первый предок с именем claude.exe.
    $claudePid = 0
    $current = $StartPid
    $seen = @{}
    for ($i = 0; $i -lt $script:MaxParentHops; $i++) {
        $info = Get-ParentProcessInfo $current
        if ($null -eq $info -or $info.ParentId -le 0 -or $seen.ContainsKey($info.ParentId)) { break }
        $seen[$current] = $true
        $current = $info.ParentId
        $parent = Get-ParentProcessInfo $current
        if ($parent -and $claudePid -eq 0 -and $parent.Name -ieq 'claude.exe') { $claudePid = $current }
        $hwnd = Get-ProcessMainWindow $current
        if ($hwnd -ne 0) { return @{ hwnd = $hwnd; claudePid = $claudePid } }
    }
    return @{ hwnd = [int64]0; claudePid = $claudePid }
}

function Test-NotifierClaudeCodePath([AllowEmptyString()][string]$Path) {
    # claude.exe — Claude Code (CLI), а не само приложение Claude (…\WindowsApps\Claude_…\app\ или …\AnthropicClaude\app-…).
    if ([string]::IsNullOrEmpty($Path) -or $Path -notmatch '\\claude\.exe$') { return $false }
    return ($Path -notmatch '\\WindowsApps\\Claude' -and $Path -notmatch '\\AnthropicClaude\\')
}

function Test-NotifierNestedClaude {
    <#
    .SYNOPSIS
    Хук вызван из служебного Claude, запущенного внутри другого сеанса (например, хук плагина делает сводку через
    «claude -p»): среди предков два Claude Code. Такой запуск — не отдельный сеанс: мост его не показывает
    и ни ответа, ни решения не ждёт. Путь процесса не прочитать — не считаем Claude Code (не прячем настоящий сеанс).
    #>
    param([int]$ProcessId = $PID)
    # Сводка ECC запускает «claude -p» с этими переменными, хуки вложенного Claude их наследуют — надёжнее дерева
    # процессов (сводка идёт при завершении сеанса, и родитель к хуку может уже выйти).
    if ($env:ECC_LLM_SUMMARY_SUBPROCESS -or $env:ECC_SKIP_LLM_SUMMARY) { return $true }
    try {
        $codes = 0
        $current = $ProcessId
        $seen = @{}
        for ($i = 0; $i -lt $script:MaxParentHops; $i++) {
            $info = Get-ParentProcessInfo $current
            if ($null -eq $info -or $info.ParentId -le 0 -or $seen.ContainsKey($info.ParentId)) { break }
            $seen[$current] = $true
            $current = $info.ParentId
            $path = ''
            try { $path = [string][ClaudeNotifier.Win32]::GetImagePath($current) } catch { }
            if (Test-NotifierClaudeCodePath $path) { $codes++; if ($codes -ge 2) { return $true } }
        }
    }
    catch { }
    return $false
}

function Get-SessionWindow {
    <#
    .SYNOPSIS
    Находит окно сессии Claude, из которой вызван хук.

    .DESCRIPTION
    cli: окно консоли процесса → корневой владелец (для Windows Terminal — окно WT).
    desktop, а также cli без консоли: обход родительских процессов до первого с MainWindowHandle.
    Исключений не выбрасывает.

    .OUTPUTS
    Hashtable @{ hwnd = <int64>; pid = <pid claude.exe или 0> }; hwnd = 0, если окно не найдено.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('cli', 'desktop')][string]$Origin,
        [int]$ProcessId = $PID
    )
    try {
        $walk = Find-AncestorWindow $ProcessId
        $hwnd = [int64]0
        if ($Origin -eq 'cli') { $hwnd = [int64](Get-ConsoleRootWindow) }
        if ($hwnd -eq 0) { $hwnd = [int64]$walk.hwnd }
        return @{ hwnd = $hwnd; pid = [int]$walk.claudePid }
    }
    catch {
        return @{ hwnd = [int64]0; pid = 0 }
    }
}

function Set-SessionWindowFocus {
    <#
    .SYNOPSIS
    Выводит окно на передний план.

    .OUTPUTS
    'closed' — окна нет; 'focused' — окно активировано; 'flashed' — Windows не дала активировать, кнопка мигает.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int64]$Hwnd)
    if ($Hwnd -eq 0 -or -not (Test-Win32Window $Hwnd)) { return 'closed' }
    if (Test-Win32Iconic $Hwnd) { Invoke-Win32Restore $Hwnd }
    if (Invoke-Win32Foreground $Hwnd) { return 'focused' }
    Invoke-Win32Flash $Hwnd
    return 'flashed'
}

function Test-SessionWindow {
    <# .SYNOPSIS $true, если окно с таким hwnd существует. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int64]$Hwnd)
    if ($Hwnd -eq 0) { return $false }
    try { return [bool](Test-Win32Window $Hwnd) } catch { return $false }
}

Export-ModuleMember -Function Get-SessionWindow, Set-SessionWindowFocus, Test-SessionWindow, Test-NotifierNestedClaude, Test-NotifierClaudeCodePath
