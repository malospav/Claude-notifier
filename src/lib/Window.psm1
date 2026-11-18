Set-StrictMode -Version 2.0

$script:MaxParentHops = 15
$script:GA_ROOTOWNER = 3
$script:SW_RESTORE = 9
$script:FLASHW_ALL_TIMERNOFG = 0x3 -bor 0xC

$script:Win32Source = @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
namespace ClaudeNotifier {
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
            try { using (Process p = Process.GetProcessById(pid)) { return p.ProcessName + ".exe"; } }
            catch { return null; }
        }
        public static long GetMainWindow(int pid) {
            try { using (Process p = Process.GetProcessById(pid)) { return p.MainWindowHandle.ToInt64(); } }
            catch { return 0; }
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

function Get-ParentProcessInfo([int]$ProcessId) {
    # @{ ParentId; Name } процесса или $null.
    $parent = [ClaudeNotifier.Win32]::GetParentPid($ProcessId)
    if ($parent -lt 0) { return $null }
    return @{ ParentId = $parent; Name = [ClaudeNotifier.Win32]::GetProcessName($ProcessId) }
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
            try { $path = [string]([System.Diagnostics.Process]::GetProcessById($current).Path) } catch { }
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
