#Requires -Version 5.1
<#
.SYNOPSIS
Вводит текст и Enter в консоль процесса Claude Code (сеанс в терминале), как будто его напечатали.

.DESCRIPTION
Запускается трем отдельным скрытым процессом (у трея своя консоль, отцеплять её нельзя): отцепляется от своей
консоли, подключается к консоли процесса -TargetPid и пишет в её буфер ввода нажатия клавиш (WriteConsoleInput),
затем Enter. Так трей продолжает сеанс после сброса лимита и отдаёт задание из очереди, когда Claude ждёт ввода
в терминале, а хука ожидания ответа нет.

Код выхода: 0 — введено; 2 — к консоли не подключиться (процесса нет или у него нет консоли); 3 — не записать.
#>
param([Parameter(Mandatory = $true)][int]$TargetPid, [Parameter(Mandatory = $true)][string]$Text)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;

public static class ClaudeNotifierConsoleType {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct KEY_EVENT_RECORD { public int bKeyDown; public ushort wRepeatCount; public ushort wVirtualKeyCode; public ushort wVirtualScanCode; public char UnicodeChar; public uint dwControlKeyState; }
    [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
    struct INPUT_RECORD { [FieldOffset(0)] public ushort EventType; [FieldOffset(4)] public KEY_EVENT_RECORD KeyEvent; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern bool WriteConsoleInput(IntPtr h, INPUT_RECORD[] buf, uint len, out uint written);

    static INPUT_RECORD Key(char c, ushort vk, bool down) {
        INPUT_RECORD r = new INPUT_RECORD();
        r.EventType = 1;   // KEY_EVENT
        r.KeyEvent.bKeyDown = down ? 1 : 0; r.KeyEvent.wRepeatCount = 1; r.KeyEvent.wVirtualKeyCode = vk; r.KeyEvent.UnicodeChar = c;
        return r;
    }

    static bool Write(IntPtr h, INPUT_RECORD[] recs) {
        uint w;
        return WriteConsoleInput(h, recs, (uint)recs.Length, out w) && w == recs.Length;
    }

    public static int Send(uint pid, string text) {
        FreeConsole();
        if (!AttachConsole(pid)) return 2;
        IntPtr h = CreateFile("CONIN$", 0xC0000000, 3, IntPtr.Zero, 3, 0, IntPtr.Zero);
        if (h == IntPtr.Zero || h == new IntPtr(-1)) { FreeConsole(); return 3; }
        try {
            INPUT_RECORD[] recs = new INPUT_RECORD[text.Length * 2];
            for (int i = 0; i < text.Length; i++) { recs[i * 2] = Key(text[i], 0, true); recs[i * 2 + 1] = Key(text[i], 0, false); }
            if (recs.Length > 0 && !Write(h, recs)) return 3;
            Thread.Sleep(350);   // текст — отдельно от Enter: поле ввода успевает его принять
            if (!Write(h, new INPUT_RECORD[] { Key('\r', 0x0D, true), Key('\r', 0x0D, false) })) return 3;
            return 0;
        }
        finally { CloseHandle(h); FreeConsole(); }
    }
}
'@
$clean = ($Text -replace '[\r\n]+', ' ').Trim()
if ($clean -eq '') { exit 3 }
exit ([ClaudeNotifierConsoleType]::Send([uint32]$TargetPid, $clean))
