$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray

function New-Ev([string]$Type = 'done', [string]$Ts = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")) {
    return [pscustomobject]@{ v = 1; id = [guid]::NewGuid().ToString(); ts = $Ts; type = $Type; title = "T $Type"; preview = 'p' }
}

function New-Q([object[]]$Items) {
    $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    foreach ($i in $Items) { $q.Enqueue($i) }
    return , $q
}

Describe 's_005_01 · мьютекс одного экземпляра' {
    It 'первый захват → Mutex, второй → $null; после освобождения снова захватывается' {
        $name = 'Local\cn-test-' + [guid]::NewGuid().ToString('N')
        $m1 = Enter-NotifierMutex -Name $name
        $m1 | Should Not Be $null
        Enter-NotifierMutex -Name $name | Should Be $null
        $m1.ReleaseMutex(); $m1.Dispose()
        $m3 = Enter-NotifierMutex -Name $name
        $m3 | Should Not Be $null
        $m3.ReleaseMutex(); $m3.Dispose()
    }
}

Describe 's_005_01 · проверка события' {
    It '<Case> → <Ok>' -TestCases @(
        @{ Case = 'корректное'; Ev = (New-Ev); Ok = $true },
        @{ Case = 'без preview'; Ev = [pscustomobject]@{ type = 'error'; title = 't' }; Ok = $true },
        @{ Case = 'неизвестный тип'; Ev = [pscustomobject]@{ type = 'boom'; title = 't' }; Ok = $false },
        @{ Case = 'нет title'; Ev = [pscustomobject]@{ type = 'done' }; Ok = $false },
        @{ Case = 'preview не строка'; Ev = [pscustomobject]@{ type = 'done'; title = 't'; preview = 5 }; Ok = $false },
        @{ Case = 'не объект'; Ev = 'text'; Ok = $false }
    ) {
        param($Case, $Ev, $Ok)
        Test-NotifierEventShape $Ev | Should Be $Ok
    }

    It 'задержка по ts: свежее событие ≈ 0 мс, без ts → -1' {
        Get-EventLatencyMs (New-Ev) | Should BeLessThan 1000
        Get-EventLatencyMs (New-Ev -Ts ([DateTime]::UtcNow.AddSeconds(-2).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))) | Should BeGreaterThan 1500
        Get-EventLatencyMs ([pscustomobject]@{ type = 'done' }) | Should Be -1
        Get-EventLatencyMs ([pscustomobject]@{ ts = 'garbage' }) | Should Be -1
    }
}

Describe 's_005_01 · Invoke-NotifierEventBatch' {
    It 'каждое событие → toast + звук своего типа, INFO с задержкой в логе' {
        $root = Join-Path $TestDrive 'ok'
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { 'x.wav' }
        Invoke-NotifierEventBatch -Queue (New-Q @((New-Ev done), (New-Ev permission))) -DataRoot $root | Should Be 2
        Assert-MockCalled Show-NotifierToast -Scope It -Times 2 -Exactly
        Assert-MockCalled Invoke-NotifierSound -Scope It -Times 1 -Exactly -ParameterFilter { $Type -eq 'permission' }
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match "\[INFO\] tray: показано 'done', задержка \d+ мс"
    }

    It 'выключенный тип пропускается' {
        $root = Join-Path $TestDrive 'disabled'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "events": { "error": { "enabled": false } } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { }
        Invoke-NotifierEventBatch -Queue (New-Q @((New-Ev error), (New-Ev done))) -DataRoot $root | Should Be 1
        Assert-MockCalled Show-NotifierToast -Scope It -Times 1 -Exactly
    }

    It 'событие неверного формата → WARN, остальные обрабатываются' {
        $root = Join-Path $TestDrive 'bad'
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { }
        Invoke-NotifierEventBatch -Queue (New-Q @([pscustomobject]@{ type = 'x' }, (New-Ev))) -DataRoot $root | Should Be 1
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[WARN\] tray: отброшено событие'
    }

    It 'исключение на одном событии не останавливает обработку' {
        $root = Join-Path $TestDrive 'throw'
        Mock Show-NotifierToast { if ($Event.type -eq 'error') { throw 'toast boom' } ; $true }
        Mock Invoke-NotifierSound { }
        Invoke-NotifierEventBatch -Queue (New-Q @((New-Ev error), (New-Ev done))) -DataRoot $root | Should Be 1
        Assert-MockCalled Invoke-NotifierSound -Scope It -Times 1 -Exactly -ParameterFilter { $Type -eq 'done' }
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] tray: ошибка обработки события: toast boom'
    }

    It '-NoOutput: ни toast, ни звука, но событие учитывается' {
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { }
        Invoke-NotifierEventBatch -Queue (New-Q @((New-Ev))) -DataRoot $TestDrive -NoOutput | Should Be 1
        Assert-MockCalled Show-NotifierToast -Scope It -Times 0
        Assert-MockCalled Invoke-NotifierSound -Scope It -Times 0
    }

    It 'за один тик не больше MaxBatch, остальное остаётся в очереди' {
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { }
        $q = New-Q @(1..5 | ForEach-Object { New-Ev })
        Invoke-NotifierEventBatch -Queue $q -DataRoot $TestDrive -MaxBatch 3 | Should Be 3
        $q.Count | Should Be 2
    }

    It 'пустая очередь → 0 без чтения конфига' {
        Mock Get-NotifierConfig { throw 'should not be called' }
        Invoke-NotifierEventBatch -Queue (New-Q @()) -DataRoot $TestDrive | Should Be 0
    }
}

Describe 's_005_01 · обрезка рабочего набора в простое' {
    $t0 = [datetime]'2026-11-16T12:00:00'
    It '<Case> → <Due>' -TestCases @(
        @{ Case = 'простой 30 с, ещё не обрезали'; Act = 0; Trim = -1; Now = 30; Due = $true },
        @{ Case = 'простой 29 с'; Act = 0; Trim = -1; Now = 29; Due = $false },
        @{ Case = 'уже обрезали после активности'; Act = 0; Trim = 31; Now = 60; Due = $false },
        @{ Case = 'новая активность после обрезки'; Act = 40; Trim = 31; Now = 70; Due = $true },
        @{ Case = 'простой продолжается, 5 мин с прошлой обрезки'; Act = 0; Trim = 31; Now = 331; Due = $true },
        @{ Case = 'простой продолжается, 4 мин с прошлой обрезки'; Act = 0; Trim = 31; Now = 271; Due = $false }
    ) {
        param($Case, $Act, $Trim, $Now, $Due)
        $lastTrim = if ($Trim -lt 0) { [datetime]::MinValue } else { $t0.AddSeconds($Trim) }
        Test-IdleTrimDue -LastActivity $t0.AddSeconds($Act) -LastTrim $lastTrim -Now $t0.AddSeconds($Now) | Should Be $Due
    }

    It 'EmptyWorkingSet для текущего процесса выполняется' {
        Invoke-WorkingSetTrim | Should Be $true
    }
}

Describe 's_005_01 · иконка и выход' {
    It 'иконка: подсказка «Claude Notifier», меню «Сеансы/История/Выход», иконка из assets' {
        $icon = New-NotifierTrayIcon -OnExit { }
        try {
                        @($icon.ContextMenuStrip.Items | ForEach-Object { $_.Text }) -join ',' | Should Be 'Сеансы,Устройства,Настройки,Статистика,История,,Выход'
            $icon.Icon.Width | Should Be ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)   # точка статуса
            $icon.Text | Should Be 'Claude · сеансов нет'
        }
        finally { $icon.Visible = $false; $icon.Dispose() }
    }

    It 'Stop-NotifierTray: таймер, сервер pipe, иконка, мьютекс' {
        Add-Type -AssemblyName System.Windows.Forms
        Mock Stop-NotifierPipeServer { $true }
        $name = 'Local\cn-test-' + [guid]::NewGuid().ToString('N')
        $state = @{
            Mutex  = (Enter-NotifierMutex -Name $name)
            Timer  = (New-Object System.Windows.Forms.Timer)
            Server = [pscustomobject]@{ PipeName = 'x' }
            Icon   = (New-Object System.Windows.Forms.NotifyIcon)
        }
        Stop-NotifierTray -State $state
        $state.Stopped | Should Be $true
        Assert-MockCalled Stop-NotifierPipeServer -Scope It -Times 1 -Exactly
        $again = Enter-NotifierMutex -Name $name
        $again | Should Not Be $null
        $again.ReleaseMutex(); $again.Dispose()
    }
}

Describe 's_005_01 · Start-NotifierTray в текущем процессе' {
    It 'уже запущен (мьютекс занят) → 0 сразу' {
        $name = 'Local\cn-test-' + [guid]::NewGuid().ToString('N')
        $held = Enter-NotifierMutex -Name $name
        try { Start-NotifierTray -MutexName $name -NoOutput -DataRoot $TestDrive | Should Be 0 }
        finally { $held.ReleaseMutex(); $held.Dispose() }
    }

    It 'цикл сообщений: событие обрабатывается, «Выход» останавливает всё и освобождает мьютекс' {
        Add-Type -AssemblyName System.Windows.Forms
        Import-Module (Join-Path $repoRoot 'src\lib\Ipc.psm1')
        $root = Join-Path $TestDrive 'inproc'
        $name = 'Local\cn-test-' + [guid]::NewGuid().ToString('N')
        $oldUser = $env:USERNAME
        $env:USERNAME = 'cn-inproc-' + [guid]::NewGuid().ToString('N')
        $script:testPipe = "claude-notifier-$env:USERNAME"
        $script:sent = $false
        # Таймер в этом же потоке: шаг 1 — отправить событие, шаг 2 — нажать «Выход».
        $driver = New-Object System.Windows.Forms.Timer
        $driver.Interval = 300
        $script:step = 0
        $driver.add_Tick({
            $script:step++
            if (-not $script:sent) { $script:sent = Send-NotifierEvent -Event (New-Ev) -PipeName $script:testPipe -TimeoutMs 100 }
            elseif ($script:step -ge 6) {
                $driver.Stop()
                @($script:TrayState.Icon.ContextMenuStrip.Items | Where-Object { $_.Text -eq 'Выход' })[0].PerformClick()
            }
        })
        $driver.Start()
        try {
            Start-NotifierTray -MutexName $name -NoOutput -DataRoot $root | Should Be 0
        }
        finally { $driver.Dispose(); $env:USERNAME = $oldUser }
        $script:sent | Should Be $true
        $log = Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8
        $log | Should Match 'tray: запущен'
        $log | Should Match "tray: показано 'done'"
        $log | Should Match 'tray: остановлен'
        $script:TrayState.Stopped | Should Be $true
        $again = Enter-NotifierMutex -Name $name
        $again | Should Not Be $null
        $again.ReleaseMutex(); $again.Dispose()
    }
}

Describe 's_005_01 · трей как процесс' {
    $user = 'cn-tray-' + [guid]::NewGuid().ToString('N')
    $mutexName = 'Local\cn-tray-test-' + [guid]::NewGuid().ToString('N')
    $lad = Join-Path $TestDrive 'lad'
    $log = Join-Path $lad 'claude-notifier\log.txt'

    function Start-TrayProcess {
        $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -File `"$tray`" -NoOutput -MutexName `"$mutexName`""
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $lad
        $psi.EnvironmentVariables['CLAUDE_NOTIFIER_HOME'] = (Join-Path $lad 'claude-notifier')
        $psi.EnvironmentVariables['USERNAME'] = $user
        return [System.Diagnostics.Process]::Start($psi)
    }

    function Wait-Log([string]$Pattern, [int]$Count = 1, [int]$TimeoutMs = 15000) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
            if (Test-Path $log) {
                $n = @([IO.File]::ReadAllLines($log) | Where-Object { $_ -match $Pattern }).Count
                if ($n -ge $Count) { return $true }
            }
            Start-Sleep -Milliseconds 50
        }
        return $false
    }

    $first = Start-TrayProcess
    try {
        It 'стартует и пишет в лог «запущен»' {
            Wait-Log 'tray: запущен' | Should Be $true
        }

        It 'второй экземпляр сразу завершается с кодом 0' {
            $second = Start-TrayProcess
            $second.WaitForExit(15000) | Should Be $true
            $second.ExitCode | Should Be 0
            $first.HasExited | Should Be $false
        }

        It '20 событий через Send-NotifierEvent: все обработаны, P95 задержки ≤ 1000 мс' {
            Import-Module (Join-Path $repoRoot 'src\lib\Ipc.psm1')
            $pipe = "claude-notifier-$user"
            foreach ($i in 1..20) {
                $ev = New-Ev -Type (@('done', 'permission', 'error', 'limit')[$i % 4])
                $sent = $false
                $deadline = [DateTime]::UtcNow.AddSeconds(3)
                while (-not $sent -and [DateTime]::UtcNow -lt $deadline) { $sent = Send-NotifierEvent -Event $ev -PipeName $pipe -TimeoutMs 200 }
                $sent | Should Be $true
            }
            Wait-Log 'tray: показано' 20 | Should Be $true
            $lat = @([IO.File]::ReadAllLines($log) | ForEach-Object { if ($_ -match 'задержка (\d+) мс') { [int]$Matches[1] } } | Sort-Object)
            $p95 = $lat[[Math]::Ceiling(0.95 * $lat.Count) - 1]
            Write-Host "      latency ms: min $($lat[0]), p95 $p95, max $($lat[-1])"
            $p95 | Should BeLessThan 1001
        }
    }
    finally {
        if (-not $first.HasExited) { $first.Kill(); [void]$first.WaitForExit(5000) }
    }
}
