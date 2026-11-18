BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Shortcut.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray

    function Read-IcoFrames([string]$Path) {
        $b = [IO.File]::ReadAllBytes($Path)
        $count = [BitConverter]::ToUInt16($b, 4)
        $frames = @()
        for ($i = 0; $i -lt $count; $i++) {
            $o = 6 + 16 * $i
            $size = [int]$b[$o]; if ($size -eq 0) { $size = 256 }
            $len = [BitConverter]::ToUInt32($b, $o + 8); $off = [BitConverter]::ToUInt32($b, $o + 12)
            $png = ($b[$off] -eq 0x89 -and $b[$off + 1] -eq 0x50)
            $frames += [pscustomobject]@{ Size = $size; Png = $png; Length = $len }
        }
        return @{ Reserved = [BitConverter]::ToUInt16($b, 0); Type = [BitConverter]::ToUInt16($b, 2); Frames = $frames }
    }
}

Describe 's_009_01 · иконка приложения' {
    It 'src\assets\icon.ico: 9 PNG-кадров от 16 до 256 px' {
        $ico = Read-IcoFrames (Join-Path $repoRoot 'src\assets\icon.ico')
        $ico.Reserved | Should -Be 0
        $ico.Type | Should -Be 1
        ($ico.Frames | ForEach-Object { $_.Size }) -join ',' | Should -Be '16,20,24,32,40,48,64,128,256'
        @($ico.Frames | Where-Object { -not $_.Png }).Count | Should -Be 0
    }

    It 'генератор пересоздаёт иконку; 256 px: прозрачный угол, белая точка в центре, градиент сверху синий' {
        $out = Join-Path $TestDrive 'icon.ico'
        $preview = Join-Path $TestDrive 'preview'
        & (Join-Path $repoRoot 'tools\New-Icon.ps1') -OutFile $out -PreviewDir $preview | Out-Null
        (Read-IcoFrames $out).Frames.Count | Should -Be 9
        Add-Type -AssemblyName System.Drawing
        $bmp = New-Object System.Drawing.Bitmap (Join-Path $preview 'icon-256.png')
        try {
            $bmp.GetPixel(2, 2).A | Should -Be 0
            $c = $bmp.GetPixel(128, 128)
            "$($c.R),$($c.G),$($c.B)" | Should -Be '255,255,255'
            $top = $bmp.GetPixel(128, 40)
            $top.B | Should -BeGreaterThan 200
            $top.R | Should -BeLessThan 60
        }
        finally { $bmp.Dispose() }
        $small = New-Object System.Drawing.Bitmap (Join-Path $preview 'icon-16.png')
        try { $c = $small.GetPixel(8, 8); "$($c.R),$($c.G),$($c.B)" | Should -Be '255,255,255' } finally { $small.Dispose() }
    }
}

Describe 's_009_01 · ярлыки' {
    It 'ярлык: conhost --headless → трей с -Show, иконка приложения, свой AppUserModelID' {
        $lnk = Join-Path $TestDrive 'a\Claude Notifier.lnk'
        $app = 'C:\Users\x\AppData\Local\claude-notifier\app'
        New-NotifierShortcut -Path $lnk -AppRoot $app
        $r = Read-NotifierShortcut -Path $lnk
        $r.Target | Should -Be (Join-Path $env:SystemRoot 'System32\conhost.exe')
        $r.Arguments | Should -Match '^--headless ".*\\powershell\.exe" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "C:\\Users\\x\\AppData\\Local\\claude-notifier\\app\\ClaudeNotifier\.Tray\.ps1" -Show$'
        $r.Icon | Should -Be "$app\assets\icon.ico"
        $r.AppId | Should -Be 'ClaudeNotifier.App'
        Get-NotifierAppId | Should -Be 'ClaudeNotifier.App'
    }

    It 'Install/Remove: «Пуск» всегда, рабочий стол — если не -NoDesktop' {
        $sm = Join-Path $TestDrive 'sm'; $desk = Join-Path $TestDrive 'desk'
        $made = @(Install-NotifierShortcuts -AppRoot 'C:\app' -NoDesktop -StartMenuDir $sm -DesktopDir $desk)
        $made.Count | Should -Be 1
        Test-NotifierShortcutInstalled -StartMenuDir $sm | Should -Be $true
        Test-Path (Join-Path $desk 'Claude Notifier.lnk') | Should -Be $false
        $made = @(Install-NotifierShortcuts -AppRoot 'C:\app' -StartMenuDir $sm -DesktopDir $desk)
        $made.Count | Should -Be 2
        Remove-NotifierShortcuts -StartMenuDir $sm -DesktopDir $desk | Should -Be 2
        Remove-NotifierShortcuts -StartMenuDir $sm -DesktopDir $desk | Should -Be 0
        Test-NotifierShortcutInstalled -StartMenuDir $sm | Should -Be $false
    }

    It 'install.ps1 создаёт ярлыки, uninstall.ps1 удаляет' {
        $id = [guid]::NewGuid().ToString('N')
        $settings = Join-Path $TestDrive "home-$id\.claude\settings.json"
        New-Item -ItemType Directory -Path (Split-Path $settings) -Force | Out-Null
        $data = Join-Path $TestDrive "data-$id\claude-notifier"
        $classes = "HKCU:\Software\claude-notifier-tests-$id"
        $sm = Join-Path $TestDrive "sm-$id"; $desk = Join-Path $TestDrive "desk-$id"
        try {
            & (Join-Path $repoRoot 'install.ps1') -SettingsPath $settings -DataRoot $data -ClassesRoot $classes -StartMenuDir $sm -DesktopDir $desk | Out-Null
            Test-Path (Join-Path $sm 'Claude Notifier.lnk') | Should -Be $true
            Test-Path (Join-Path $desk 'Claude Notifier.lnk') | Should -Be $true
            (Read-NotifierShortcut -Path (Join-Path $sm 'Claude Notifier.lnk')).Icon | Should -Be (Join-Path $data 'app\assets\icon.ico')
            Test-Path (Join-Path $data 'app\lib\Shortcut.psm1') | Should -Be $true
            & (Join-Path $repoRoot 'uninstall.ps1') -SettingsPath $settings -DataRoot $data -ClassesRoot $classes -StartMenuDir $sm -DesktopDir $desk | Out-Null
            Test-Path (Join-Path $sm 'Claude Notifier.lnk') | Should -Be $false
            Test-Path (Join-Path $desk 'Claude Notifier.lnk') | Should -Be $false
        }
        finally { Remove-Item -LiteralPath $classes -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 's_009_01 · открытие окна ярлыком' {
    It 'событие show проходит проверку формы и открывает окно, а не уведомление' {
        Test-NotifierEventShape (New-NotifierShowEvent) | Should -Be $true
        Mock Show-NotifierSessionsWindow { }
        Mock Show-NotifierToast { $true }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue((New-NotifierShowEvent))
        Invoke-NotifierEventBatch -Queue $q -DataRoot (Join-Path $TestDrive 'show') | Should -Be 1
        Assert-MockCalled Show-NotifierSessionsWindow -Times 1 -Exactly -Scope It
        Assert-MockCalled Show-NotifierToast -Times 0 -Scope It
        Test-Path (Join-Path $TestDrive 'show\history.json') | Should -Be $false
    }

    It 'трей уже работает: -Show передаёт команду и выходит с 0; без -Show — просто выходит' {
        $name = 'Local\cn-test-' + [guid]::NewGuid().ToString('N')
        $held = Enter-NotifierMutex -Name $name
        try {
            Mock Request-NotifierShowWindow { $true }
            Start-NotifierTray -MutexName $name -Show -DataRoot $TestDrive | Should -Be 0
            Assert-MockCalled Request-NotifierShowWindow -Times 1 -Exactly -Scope It
            Start-NotifierTray -MutexName $name -DataRoot $TestDrive | Should -Be 0
            Assert-MockCalled Request-NotifierShowWindow -Times 1 -Exactly -Scope It
        }
        finally { $held.ReleaseMutex(); $held.Dispose() }
    }

}

Describe 's_009_01 · команда «показать окно» по pipe' {   # отдельно: моки Pester 3.4 живут весь Describe
    It 'Request-NotifierShowWindow: трей не отвечает → $false и WARN' {
        # Свой pipe: команда не должна уйти в настоящий трей пользователя.
        $root = Join-Path $TestDrive 'req'
        $pipe = 'cn-test-' + [guid]::NewGuid().ToString('N')
        Request-NotifierShowWindow -DataRoot $root -PipeName $pipe | Should -Be $false
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] tray: окно не открыто'
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server = Start-NotifierPipeServer -Queue $q -PipeName $pipe -DataRoot $root
        try {
            Start-Sleep -Milliseconds 300
            $ok = $false
            for ($i = 0; $i -lt 10 -and -not $ok; $i++) { $ok = Request-NotifierShowWindow -DataRoot $root -PipeName $pipe; if (-not $ok) { Start-Sleep -Milliseconds 100 } }
            $ok | Should -Be $true
            $got = $null
            for ($i = 0; $i -lt 20 -and -not $q.TryDequeue([ref]$got); $i++) { Start-Sleep -Milliseconds 50 }
            $got.type | Should -Be 'show'
        }
        finally { [void](Stop-NotifierPipeServer -Server $server) }
    }
}
