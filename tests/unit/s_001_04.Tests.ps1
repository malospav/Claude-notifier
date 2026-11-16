$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$bridge = Join-Path $repoRoot 'src\hook-bridge.ps1'
. $bridge

$stopJson = '{ "session_id": "s1", "cwd": "C:\\dev\\proj", "last_assistant_message": "Готово" }'

Describe 's_001_04 · Invoke-NotifierHookBridge' {
    It 'трей отвечает → sent, трей не запускается, окно приложено к событию' {
        Mock Get-SessionWindow { @{ hwnd = [int64]77; pid = 5 } }
        Mock Send-NotifierEvent { $true }
        Mock Start-NotifierTray { $true }
        Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $TestDrive | Should Be 'sent'
        Assert-MockCalled Start-NotifierTray -Scope It -Times 0
        Assert-MockCalled Send-NotifierEvent -Scope It -Times 1 -Exactly -ParameterFilter {
            $Event.type -eq 'done' -and $Event.window.hwnd -eq 77 -and $Event.preview -eq 'Готово'
        }
    }

    It 'трей не отвечает → запуск трея и до 3 повторов (успех на 2-м)' {
        $script:calls = 0
        Mock Get-SessionWindow { @{ hwnd = [int64]0; pid = 0 } }
        Mock Send-NotifierEvent { $script:calls++; $script:calls -ge 3 }
        Mock Start-NotifierTray { $true }
        Mock Wait-NotifierRetry { }
        Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $TestDrive | Should Be 'sent-after-start'
        Assert-MockCalled Start-NotifierTray -Scope It -Times 1 -Exactly
        Assert-MockCalled Wait-NotifierRetry -Scope It -Times 2 -Exactly -ParameterFilter { $Milliseconds -eq 300 }
    }

    It 'трей так и не ответил → 1 + 3 попытки, ERROR в логе, undelivered' {
        $root = Join-Path $TestDrive 'undelivered'
        Mock Get-SessionWindow { @{ hwnd = [int64]0; pid = 0 } }
        Mock Send-NotifierEvent { $false }
        Mock Start-NotifierTray { $true }
        Mock Wait-NotifierRetry { }
        Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $root | Should Be 'undelivered'
        Assert-MockCalled Send-NotifierEvent -Scope It -Times 4 -Exactly
        $log = Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8
        $log | Should Match "\[ERROR\] bridge: событие 'done' не доставлено после 3 повторов"
        $log | Should Not Match 'Готово'   # превью в лог не попадает
    }

    It 'тип события выключен в конфиге → disabled, ничего не отправляется' {
        $root = Join-Path $TestDrive 'disabled'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "events": { "done": { "enabled": false } } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Mock Send-NotifierEvent { $true }
        Mock Get-SessionWindow { @{ hwnd = [int64]0; pid = 0 } }
        Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $root | Should Be 'disabled'
        Assert-MockCalled Send-NotifierEvent -Scope It -Times 0
        Assert-MockCalled Get-SessionWindow -Scope It -Times 0
    }

    It '<Case> → invalid, ничего не отправляется' -TestCases @(
        @{ Case = 'пустой stdin'; Kind = 'stop'; Json = '' },
        @{ Case = 'неизвестный вид хука'; Kind = 'bogus'; Json = $stopJson }
    ) {
        param($Case, $Kind, $Json)
        Mock Send-NotifierEvent { $true }
        Invoke-NotifierHookBridge -Kind $Kind -InputJson $Json -DataRoot $TestDrive | Should Be 'invalid'
        Assert-MockCalled Send-NotifierEvent -Scope It -Times 0
    }

    It 'исключение внутри → failed и ERROR, без исключения наружу' {
        $root = Join-Path $TestDrive 'failed'
        Mock Get-SessionWindow { throw 'boom' }
        { Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $root } | Should Not Throw
        Invoke-NotifierHookBridge -Kind stop -InputJson $stopJson -DataRoot $root | Should Be 'failed'
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] bridge: .*boom'
    }
}

Describe 's_001_04 · Start-NotifierTray' {
    It 'трея нет → ERROR и $false, процесс не запускается' {
        $root = Join-Path $TestDrive 'notray'
        Mock Start-Process { }
        $script:BridgeRoot = Join-Path $TestDrive 'empty-app'
        try {
            Start-NotifierTray -DataRoot $root | Should Be $false
            Assert-MockCalled Start-Process -Scope It -Times 0
            (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] bridge: трей не найден'
        }
        finally { $script:BridgeRoot = Split-Path $bridge }
    }

    It 'трей есть → conhost --headless powershell -File <трей>' {
        $app = Join-Path $TestDrive 'app'
        New-Item -ItemType Directory -Path $app | Out-Null
        Set-Content (Join-Path $app 'ClaudeNotifier.Tray.ps1') '# stub'
        Mock Start-Process { }
        $script:BridgeRoot = $app
        try {
            Start-NotifierTray -DataRoot $TestDrive | Should Be $true
            Assert-MockCalled Start-Process -Scope It -Times 1 -Exactly -ParameterFilter {
                $FilePath -like '*\System32\conhost.exe' -and $ArgumentList[0] -eq '--headless' -and
                ($ArgumentList -join ' ') -like '*powershell.exe*-File*ClaudeNotifier.Tray.ps1*'
            }
        }
        finally { $script:BridgeRoot = Split-Path $bridge }
    }

    It 'Wait-NotifierRetry ждёт заданное время' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Wait-NotifierRetry 30
        $sw.ElapsedMilliseconds | Should BeGreaterThan 20
    }
}

Describe 's_001_04 · кэш сборки Win32 (ускорение bridge)' {
    function Invoke-Child([string]$LocalAppData, [string]$Code) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -Command `"$Code`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $LocalAppData
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd().Trim()
        $p.WaitForExit()
        return $out
    }

    It 'первый процесс компилирует DLL в кэш, второй берёт её из кэша без перекомпиляции' {
        $lad = Join-Path $TestDrive 'lad'
        New-Item -ItemType Directory -Path $lad | Out-Null
        $window = Join-Path $repoRoot 'src\lib\Window.psm1'
        $code = "Import-Module '$window'; [ClaudeNotifier.Win32]::GetParentPid(`$PID) -gt 0"
        Invoke-Child $lad $code | Should Be 'True'
        $dll = @(Get-ChildItem (Join-Path $lad 'claude-notifier\cache') -Filter 'ClaudeNotifier.Win32.*.dll')
        $dll.Count | Should Be 1
        $stamp = $dll[0].LastWriteTimeUtc
        Invoke-Child $lad $code | Should Be 'True'
        (Get-Item $dll[0].FullName).LastWriteTimeUtc | Should Be $stamp
        @(Get-ChildItem (Join-Path $lad 'claude-notifier\cache')).Count | Should Be 1   # временных файлов не осталось
    }

    It 'тип уже загружен → loaded' {
        & (Get-Module Window) { Import-Win32Type -CacheDir (Join-Path $TestDrive 'unused') } | Should Be 'loaded'
    }
}

Describe 's_001_04 · процесс bridge целиком' {
    function Invoke-BridgeProcess([string]$Kind, [string]$Stdin, [string]$LocalAppData) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $psi.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$bridge`" $Kind"
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $LocalAppData
        $psi.EnvironmentVariables['USERNAME'] = 'cn-test-' + [guid]::NewGuid().ToString('N')  # свой pipe: трея нет
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = [System.Diagnostics.Process]::Start($psi)
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Stdin)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $out = $p.StandardOutput.ReadToEnd()
        $err = $p.StandardError.ReadToEnd()
        $p.WaitForExit()
        $sw.Stop()
        return @{ ExitCode = $p.ExitCode; Stdout = $out; Stderr = $err; Ms = $sw.ElapsedMilliseconds }
    }

    It 'с работающим трей-сервером: событие доставлено, среднее время 5 запусков ≤ 500 мс' {
        Import-Module (Join-Path $repoRoot 'src\lib\Ipc.psm1')
        $user = 'cn-perf-' + [guid]::NewGuid().ToString('N')
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server = Start-NotifierPipeServer -Queue $queue -PipeName "claude-notifier-$user" -DataRoot $TestDrive
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not $server.State.Listening -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 10 }
            $stdin = '{ "session_id": "s1", "cwd": "C:\\dev\\proj", "last_assistant_message": "ok" }'
            $times = foreach ($i in 0..5) {
                $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -File `"$bridge`" stop"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardInput = $true
                $psi.EnvironmentVariables['USERNAME'] = $user
                $sw = [Diagnostics.Stopwatch]::StartNew()
                $p = [System.Diagnostics.Process]::Start($psi)
                $b = [Text.Encoding]::UTF8.GetBytes($stdin)
                $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
                $p.StandardInput.Close()
                $p.WaitForExit()
                $sw.ElapsedMilliseconds
            }
            $avg = ($times | Select-Object -Skip 1 | Measure-Object -Average).Average   # первый запуск — прогрев кэша
            Write-Host "      bridge ms: $($times -join ', '); avg(5) = $([int]$avg)"
            $avg | Should BeLessThan 500
            $queue.Count | Should Be 6
        }
        finally { [void](Stop-NotifierPipeServer -Server $server) }
    }

    It 'код выхода 0 и пустой stdout при <Case>' -TestCases @(
        @{ Case = 'битом stdin'; Kind = 'stop'; Stdin = '{ broken' },
        @{ Case = 'неизвестном виде хука'; Kind = 'nope'; Stdin = '{}' },
        @{ Case = 'выключенном типе события'; Kind = 'stop'; Stdin = '{ "cwd": "C:\\x" }'; Disable = $true }
    ) {
        param($Case, $Kind, $Stdin, $Disable)
        $lad = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $lad 'claude-notifier') -Force | Out-Null
        if ($Disable) { '{ "events": { "done": { "enabled": false } } }' | Set-Content (Join-Path $lad 'claude-notifier\config.json') -Encoding UTF8 }
        $r = Invoke-BridgeProcess $Kind $Stdin $lad
        $r.ExitCode | Should Be 0
        $r.Stdout | Should Be ''
        $r.Stderr | Should Be ''
    }
}
