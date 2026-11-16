Set-StrictMode -Version 2.0

# Ярлыки «Claude Notifier» в меню «Пуск» и на рабочем столе. У ярлыка свой AppUserModelID: по нему Windows
# показывает имя и иконку приложения на панели задач и в уведомлениях вместо «Windows PowerShell».
$script:AppId = 'ClaudeNotifier.App'
$script:LinkName = 'Claude Notifier.lnk'

$script:ShellLinkSource = @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;
namespace ClaudeNotifier {
    public static class ShellLink {
        [ComImport, Guid("00021401-0000-0000-C000-000000000046")] class CShellLink { }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
        interface IShellLinkW {
            void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder file, int cch, IntPtr fd, int flags);
            void GetIDList(out IntPtr pidl);
            void SetIDList(IntPtr pidl);
            void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder name, int cch);
            void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string name);
            void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder dir, int cch);
            void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string dir);
            void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder args, int cch);
            void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string args);
            void GetHotkey(out short hotkey);
            void SetHotkey(short hotkey);
            void GetShowCmd(out int cmd);
            void SetShowCmd(int cmd);
            void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder path, int cch, out int index);
            void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string path, int index);
            void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string path, int reserved);
            void Resolve(IntPtr hwnd, int flags);
            void SetPath([MarshalAs(UnmanagedType.LPWStr)] string file);
        }

        [StructLayout(LayoutKind.Sequential)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }

        [StructLayout(LayoutKind.Sequential)]
        struct PROPVARIANT { public ushort vt; public ushort r1, r2, r3; public IntPtr p; public IntPtr p2; }

        [ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99")]
        interface IPropertyStore {
            void GetCount(out uint count);
            void GetAt(uint index, out PROPERTYKEY key);
            void GetValue(ref PROPERTYKEY key, out PROPVARIANT value);
            void SetValue(ref PROPERTYKEY key, ref PROPVARIANT value);
            void Commit();
        }

        [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT pv);

        static PROPERTYKEY AppIdKey() {
            PROPERTYKEY k = new PROPERTYKEY();
            k.fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"); k.pid = 5;   // PKEY_AppUserModel_ID
            return k;
        }

        public static void Create(string path, string target, string args, string workDir, string icon, string description, string appId) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            link.SetPath(target);
            link.SetArguments(args ?? "");
            link.SetWorkingDirectory(workDir ?? "");
            link.SetIconLocation(icon ?? "", 0);
            link.SetDescription(description ?? "");
            link.SetShowCmd(7);   // SW_SHOWMINNOACTIVE: консоль conhost --headless не мелькает
            if (!string.IsNullOrEmpty(appId)) {
                IPropertyStore store = (IPropertyStore)link;
                PROPERTYKEY key = AppIdKey();
                PROPVARIANT v = new PROPVARIANT();
                v.vt = 31;   // VT_LPWSTR
                v.p = Marshal.StringToCoTaskMemUni(appId);
                try { store.SetValue(ref key, ref v); store.Commit(); }
                finally { Marshal.FreeCoTaskMem(v.p); }
            }
            ((IPersistFile)link).Save(path, true);
            Marshal.ReleaseComObject(link);
        }

        // [target, arguments, icon, appId]
        public static string[] Read(string path) {
            IShellLinkW link = (IShellLinkW)new CShellLink();
            ((IPersistFile)link).Load(path, 0);
            StringBuilder target = new StringBuilder(1024), args = new StringBuilder(4096), icon = new StringBuilder(1024);
            link.GetPath(target, target.Capacity, IntPtr.Zero, 0x4);   // SLGP_RAWPATH
            link.GetArguments(args, args.Capacity);
            int index;
            link.GetIconLocation(icon, icon.Capacity, out index);
            string appId = "";
            IPropertyStore store = (IPropertyStore)link;
            PROPERTYKEY key = AppIdKey();
            PROPVARIANT v;
            store.GetValue(ref key, out v);
            if (v.vt == 31 && v.p != IntPtr.Zero) appId = Marshal.PtrToStringUni(v.p);
            PropVariantClear(ref v);
            Marshal.ReleaseComObject(link);
            return new string[] { target.ToString(), args.ToString(), icon.ToString(), appId };
        }
    }
}
'@

function Import-NotifierShellLink {
    if (-not ('ClaudeNotifier.ShellLink' -as [type])) { Add-Type -TypeDefinition $script:ShellLinkSource }
}

function Get-NotifierAppId { return $script:AppId }

function Get-NotifierLauncherCommand {
    <#
    .SYNOPSIS
    Что запускает ярлык: conhost --headless powershell … ClaudeNotifier.Tray.ps1 -Show. Окна консоли нет;
    если трей уже работает, он просто откроет окно «Сеансы».
    #>
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $tray = Join-Path $AppRoot 'ClaudeNotifier.Tray.ps1'
    return @{
        Target    = (Join-Path $env:SystemRoot 'System32\conhost.exe')
        Arguments = "--headless `"$ps`" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$tray`" -Show"
    }
}

function New-NotifierShortcut {
    <# .SYNOPSIS Создаёт ярлык Claude Notifier (иконка приложения, AppUserModelID) по пути Path. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$AppRoot)
    Import-NotifierShellLink
    $cmd = Get-NotifierLauncherCommand -AppRoot $AppRoot
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [ClaudeNotifier.ShellLink]::Create($Path, $cmd.Target, $cmd.Arguments, $AppRoot, (Join-Path $AppRoot 'assets\icon.ico'),
        'Уведомления и сеансы Claude Code', $script:AppId)
}

function Read-NotifierShortcut {
    <# .SYNOPSIS Свойства ярлыка: @{ Target; Arguments; Icon; AppId }. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    Import-NotifierShellLink
    $r = [ClaudeNotifier.ShellLink]::Read($Path)
    return @{ Target = $r[0]; Arguments = $r[1]; Icon = $r[2]; AppId = $r[3] }
}

function Get-NotifierShortcutPaths {
    param(
        [string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')),
        [string]$DesktopDir = ([Environment]::GetFolderPath('DesktopDirectory'))
    )
    return @{ StartMenu = (Join-Path $StartMenuDir $script:LinkName); Desktop = (Join-Path $DesktopDir $script:LinkName) }
}

function Install-NotifierShortcuts {
    <#
    .SYNOPSIS
    Ярлык в меню «Пуск» (нужен всегда: по нему Windows узнаёт AppUserModelID) и, если не -NoDesktop, на рабочем столе.
    Возвращает пути созданных ярлыков.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [switch]$NoDesktop,
        [string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')),
        [string]$DesktopDir = ([Environment]::GetFolderPath('DesktopDirectory'))
    )
    $paths = Get-NotifierShortcutPaths -StartMenuDir $StartMenuDir -DesktopDir $DesktopDir
    New-NotifierShortcut -Path $paths.StartMenu -AppRoot $AppRoot
    $made = @($paths.StartMenu)
    if (-not $NoDesktop) { New-NotifierShortcut -Path $paths.Desktop -AppRoot $AppRoot; $made += $paths.Desktop }
    return $made
}

function Remove-NotifierShortcuts {
    <# .SYNOPSIS Удаляет ярлыки Claude Notifier. Возвращает число удалённых. #>
    [CmdletBinding()]
    param(
        [string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')),
        [string]$DesktopDir = ([Environment]::GetFolderPath('DesktopDirectory'))
    )
    $paths = Get-NotifierShortcutPaths -StartMenuDir $StartMenuDir -DesktopDir $DesktopDir
    $n = 0
    foreach ($p in @($paths.StartMenu, $paths.Desktop)) {
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; $n++ }
    }
    return $n
}

function Test-NotifierShortcutInstalled {
    <# .SYNOPSIS Есть ли ярлык в меню «Пуск» — без него AppUserModelID не известен Windows. #>
    param([string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')))
    return (Test-Path -LiteralPath (Join-Path $StartMenuDir $script:LinkName))
}

Export-ModuleMember -Function Get-NotifierAppId, Get-NotifierLauncherCommand, New-NotifierShortcut, Read-NotifierShortcut, Get-NotifierShortcutPaths, Install-NotifierShortcuts, Remove-NotifierShortcuts, Test-NotifierShortcutInstalled
