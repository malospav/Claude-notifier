BeforeAll {
    $libDir = Resolve-Path (Join-Path $PSScriptRoot '..\..\src\lib')
    Import-Module (Join-Path $libDir 'Window.psm1') -Force
}

Describe 's_003_01 · Add-Type' {
    It 'тип Win32 объявлен один раз: повторный импорт модуля не падает' {
        { Import-Module (Join-Path $libDir 'Window.psm1') -Force } | Should -Not -Throw
        ('ClaudeNotifier.Win32' -as [type]) | Should -Not -Be $null
    }
}

Describe 's_003_01 · Get-SessionWindow' {
    BeforeAll {
        $tree = @{
            100 = @{ ParentId = 200; Name = 'powershell.exe' }
            200 = @{ ParentId = 300; Name = 'cmd.exe' }
            300 = @{ ParentId = 400; Name = 'claude.exe' }
            400 = @{ ParentId = 1; Name = 'claude.exe' }
            1   = @{ ParentId = 0; Name = 'explorer.exe' }
        }
    }

    # Мок-дерево процессов: 100 (bridge) ← 200 cmd ← 300 claude.exe (CLI) ← 400 claude.exe (desktop, есть окно) ← 1 explorer

    It 'desktop: обход родителей находит первый процесс с окном и pid claude.exe' {
        Mock -ModuleName Window Get-ParentProcessInfo { switch ($ProcessId) { 100 { @{ ParentId = 200; Name = 'powershell.exe' } } 200 { @{ ParentId = 300; Name = 'cmd.exe' } } 300 { @{ ParentId = 400; Name = 'claude.exe' } } 400 { @{ ParentId = 1; Name = 'claude.exe' } } 1 { @{ ParentId = 0; Name = 'explorer.exe' } } } }
        Mock -ModuleName Window Get-ProcessMainWindow { if ($ProcessId -eq 400) { [int64]777 } else { [int64]0 } }
        Mock -ModuleName Window Get-ConsoleRootWindow { [int64]555 }
        $w = Get-SessionWindow -Origin desktop -ProcessId 100
        $w.hwnd | Should -Be 777
        $w.pid | Should -Be 300
        Assert-MockCalled -ModuleName Window Get-ConsoleRootWindow -Scope It -Times 0
    }

    It 'cli: приоритет у окна консоли (root owner)' {
        Mock -ModuleName Window Get-ParentProcessInfo { switch ($ProcessId) { 100 { @{ ParentId = 200; Name = 'powershell.exe' } } 200 { @{ ParentId = 300; Name = 'cmd.exe' } } 300 { @{ ParentId = 400; Name = 'claude.exe' } } 400 { @{ ParentId = 1; Name = 'claude.exe' } } 1 { @{ ParentId = 0; Name = 'explorer.exe' } } } }
        Mock -ModuleName Window Get-ProcessMainWindow { [int64]0 }
        Mock -ModuleName Window Get-ConsoleRootWindow { [int64]555 }
        $w = Get-SessionWindow -Origin cli -ProcessId 100
        $w.hwnd | Should -Be 555
        $w.pid | Should -Be 300
    }

    It 'cli без консоли → fallback на обход родителей' {
        Mock -ModuleName Window Get-ParentProcessInfo { switch ($ProcessId) { 100 { @{ ParentId = 200; Name = 'powershell.exe' } } 200 { @{ ParentId = 300; Name = 'cmd.exe' } } 300 { @{ ParentId = 400; Name = 'claude.exe' } } 400 { @{ ParentId = 1; Name = 'claude.exe' } } 1 { @{ ParentId = 0; Name = 'explorer.exe' } } } }
        Mock -ModuleName Window Get-ProcessMainWindow { if ($ProcessId -eq 200) { [int64]42 } else { [int64]0 } }
        Mock -ModuleName Window Get-ConsoleRootWindow { [int64]0 }
        (Get-SessionWindow -Origin cli -ProcessId 100).hwnd | Should -Be 42
    }

    It 'окно не найдено → hwnd 0, pid claude.exe' {
        Mock -ModuleName Window Get-ParentProcessInfo { switch ($ProcessId) { 100 { @{ ParentId = 200; Name = 'powershell.exe' } } 200 { @{ ParentId = 300; Name = 'cmd.exe' } } 300 { @{ ParentId = 400; Name = 'claude.exe' } } 400 { @{ ParentId = 1; Name = 'claude.exe' } } 1 { @{ ParentId = 0; Name = 'explorer.exe' } } } }
        Mock -ModuleName Window Get-ProcessMainWindow { [int64]0 }
        Mock -ModuleName Window Get-ConsoleRootWindow { [int64]0 }
        $w = Get-SessionWindow -Origin desktop -ProcessId 100
        $w.hwnd | Should -Be 0
        $w.pid | Should -Be 300
    }

    It 'цикл в дереве процессов не зацикливает обход' {
        Mock -ModuleName Window Get-ParentProcessInfo { if ($ProcessId -eq 10) { @{ ParentId = 11; Name = 'a.exe' } } else { @{ ParentId = 10; Name = 'b.exe' } } }
        Mock -ModuleName Window Get-ProcessMainWindow { [int64]0 }
        $w = Get-SessionWindow -Origin desktop -ProcessId 10
        $w.hwnd | Should -Be 0
        $w.pid | Should -Be 0
    }

    It 'исключение внутри → @{hwnd=0; pid=0} без исключения' {
        Mock -ModuleName Window Get-ParentProcessInfo { throw 'boom' }
        $w = Get-SessionWindow -Origin cli -ProcessId 100
        $w.hwnd | Should -Be 0
        $w.pid | Should -Be 0
    }


}

Describe 's_003_01 · реальные обёртки процессов' {
    It 'реальные обёртки Win32 и процессов работают' {
        $self = & (Get-Module Window) { Get-ParentProcessInfo $PID }
        $self.ParentId | Should -BeGreaterThan 0
        (& (Get-Module Window) { Get-ParentProcessInfo 999999 }) | Should -Be $null
        (& (Get-Module Window) { Get-ProcessMainWindow 999999 }) | Should -Be 0
        (& (Get-Module Window) { Get-ConsoleRootWindow }) -is [int64] | Should -Be $true
    }
    It 'реальный процесс: cli из консоли возвращает окно консоли, если оно есть' {
        $console = [ClaudeNotifier.Win32]::GetConsoleWindow()
        $w = Get-SessionWindow -Origin cli
        if ($console -ne [IntPtr]::Zero) { $w.hwnd | Should -Not -Be 0 }
        else { $w.hwnd -is [int64] | Should -Be $true }
    }
}

Describe 's_003_01 · Set-SessionWindowFocus' {
    It 'hwnd 0 → closed' {
        Set-SessionWindowFocus -Hwnd 0 | Should -Be 'closed'
    }

    It 'несуществующее окно (реальный IsWindow) → closed' {
        Set-SessionWindowFocus -Hwnd 1 | Should -Be 'closed'
    }

    It 'окно есть, SetForegroundWindow = true → focused, без восстановления' {
        Mock -ModuleName Window Test-Win32Window { $true }
        Mock -ModuleName Window Test-Win32Iconic { $false }
        Mock -ModuleName Window Invoke-Win32Restore { }
        Mock -ModuleName Window Invoke-Win32Foreground { $true }
        Mock -ModuleName Window Invoke-Win32Flash { }
        Set-SessionWindowFocus -Hwnd 123 | Should -Be 'focused'
        Assert-MockCalled -ModuleName Window Invoke-Win32Restore -Scope It -Times 0
        Assert-MockCalled -ModuleName Window Invoke-Win32Flash -Scope It -Times 0
    }

    It 'свёрнутое окно сначала восстанавливается' {
        Mock -ModuleName Window Test-Win32Window { $true }
        Mock -ModuleName Window Test-Win32Iconic { $true }
        Mock -ModuleName Window Invoke-Win32Restore { }
        Mock -ModuleName Window Invoke-Win32Foreground { $true }
        Set-SessionWindowFocus -Hwnd 123 | Should -Be 'focused'
        Assert-MockCalled -ModuleName Window Invoke-Win32Restore -Scope It -Times 1 -Exactly
    }

    It 'SetForegroundWindow = false → FlashWindowEx и flashed' {
        Mock -ModuleName Window Test-Win32Window { $true }
        Mock -ModuleName Window Test-Win32Iconic { $false }
        Mock -ModuleName Window Invoke-Win32Foreground { $false }
        Mock -ModuleName Window Invoke-Win32Flash { }
        Set-SessionWindowFocus -Hwnd 123 | Should -Be 'flashed'
        Assert-MockCalled -ModuleName Window Invoke-Win32Flash -Scope It -Times 1 -Exactly
    }

}

Describe 's_003_01 · реальные обёртки Win32' {
    It 'реальные обёртки Win32 не падают на несуществующем окне' {
        $m = Get-Module Window
        (& $m { Test-Win32Iconic 1 }) | Should -Be $false
        { & $m { Invoke-Win32Restore 1 } } | Should -Not -Throw
        (& $m { Invoke-Win32Foreground 1 }) | Should -Be $false
        { & $m { Invoke-Win32Flash 1 } } | Should -Not -Throw
    }
}
