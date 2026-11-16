$libDir = Resolve-Path (Join-Path $PSScriptRoot '..\..\src\lib')
Import-Module (Join-Path $libDir 'Log.psm1') -Force
Import-Module (Join-Path $libDir 'Ipc.psm1') -Force

function Wait-Until([scriptblock]$Condition, [int]$TimeoutMs = 3000) {
    # Опрос условия с дедлайном (без фиксированных пауз).
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 10
    }
    return [bool](& $Condition)
}

function New-TestServer([string]$DataRoot) {
    $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $name = 'cn-test-' + [guid]::NewGuid().ToString('N')
    $server = Start-NotifierPipeServer -Queue $queue -PipeName $name -DataRoot $DataRoot
    $listening = Wait-Until { $server.State.Listening }
    if (-not $listening) { throw 'pipe server did not start' }
    # Возвращаем только дескриптор: лишний вывод в конвейер превратил бы результат в массив.
    return @{ Queue = $queue; Name = $name; Server = $server }
}

function Send-Raw([string]$PipeName, [string]$Text) {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::Out)
    try {
        $c.Connect(1000)
        $b = [Text.Encoding]::UTF8.GetBytes($Text)
        $c.Write($b, 0, $b.Length)
        $c.Flush()
    }
    finally { $c.Dispose() }
}

Describe 's_001_03 · имя и безопасность pipe' {
    It 'имя pipe = claude-notifier-<USERNAME>' {
        Get-NotifierPipeName | Should Be "claude-notifier-$env:USERNAME"
    }

    It 'DACL: единственное правило — FullControl для текущего пользователя, наследование отключено' {
        $sec = New-NotifierPipeSecurity
        $rules = @($sec.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $rules.Count | Should Be 1
        $rules[0].IdentityReference.Value | Should Be ([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        $rules[0].AccessControlType | Should Be 'Allow'
        $rules[0].PipeAccessRights | Should Be 'FullControl'
        $sec.AreAccessRulesProtected | Should Be $true
    }
}

Describe 's_001_03 · Receive-NotifierFrame' {
    function New-Stream([string]$Text) {
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
        return , (New-Object System.IO.MemoryStream (, $bytes))
    }

    It '<Case> → <Result>' -TestCases @(
        @{ Case = 'объект с \n'; Text = "{`"a`":`"Готово`"}`n{`"b`":2}"; Result = 'ok'; Count = 1 },
        @{ Case = 'объект без \n'; Text = '{"a":1}'; Result = 'ok'; Count = 1 },
        @{ Case = 'пусто'; Text = ''; Result = 'empty'; Count = 0 },
        @{ Case = 'одни пробелы'; Text = "   `n"; Result = 'empty'; Count = 0 },
        @{ Case = 'битый JSON'; Text = "{ not`n"; Result = 'invalid'; Count = 0 },
        @{ Case = 'JSON-число'; Text = "42`n"; Result = 'invalid'; Count = 0 },
        @{ Case = 'кадр длиннее лимита'; Text = ('{"p":"' + ('x' * 100) + '"}'); Result = 'toolong'; Count = 0 }
    ) {
        param($Case, $Text, $Result, $Count)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Receive-NotifierFrame -Stream (New-Stream $Text) -Queue $q -DataRoot $root -MaxChars 64 | Should Be $Result
        $q.Count | Should Be $Count
        if ($Result -eq 'invalid' -or $Result -eq 'toolong') {
            (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[WARN\] Ipc:'
        }
    }

    It 'читает только первый кадр и не закрывает поток' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $stream = New-Stream "{`"n`":1}`n{`"n`":2}`n"
        Receive-NotifierFrame -Stream $stream -Queue $q -DataRoot $TestDrive | Should Be 'ok'
        $stream.CanRead | Should Be $true
        $item = $null; [void]$q.TryDequeue([ref]$item); $item.n | Should Be 1
    }
}

Describe 's_001_03 · Send-NotifierEvent и сервер' {
    It 'сервер запущен → событие (с кириллицей) попадает в очередь' {
        $t = New-TestServer $TestDrive
        try {
            Send-NotifierEvent -Event ([pscustomobject]@{ v = 1; type = 'done'; preview = 'Готово ✓' }) -PipeName $t.Name -TimeoutMs 1000 | Should Be $true
            Wait-Until { $t.Queue.Count -ge 1 } | Should Be $true
            $item = $null
            $t.Queue.TryDequeue([ref]$item) | Should Be $true
            $item.type | Should Be 'done'
            $item.preview | Should Be 'Готово ✓'
        }
        finally { Stop-NotifierPipeServer -Server $t.Server | Should Be $true }
    }

    It 'принимает несколько событий подряд' {
        $t = New-TestServer $TestDrive
        try {
            foreach ($i in 1..5) {
                $sent = $false
                $deadline = [DateTime]::UtcNow.AddSeconds(3)
                while (-not $sent -and [DateTime]::UtcNow -lt $deadline) {
                    $sent = Send-NotifierEvent -Event @{ n = $i } -PipeName $t.Name -TimeoutMs 200
                }
                $sent | Should Be $true
            }
            Wait-Until { $t.Queue.Count -ge 5 } | Should Be $true
        }
        finally { [void](Stop-NotifierPipeServer -Server $t.Server) }
    }

    It 'сервера нет → $false не дольше 100 мс сверх таймаута 50 мс' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Send-NotifierEvent -Event @{ x = 1 } -PipeName ('cn-none-' + [guid]::NewGuid().ToString('N')) -TimeoutMs 50
        $sw.Stop()
        $r | Should Be $false
        $sw.ElapsedMilliseconds | Should BeLessThan 150
    }

    It 'не выбрасывает исключение на несериализуемом событии' {
        { Send-NotifierEvent -Event $null -PipeName 'cn-none' -TimeoutMs 10 } | Should Throw   # обязательный параметр
        $bad = [pscustomobject]@{ self = $null }
        { Send-NotifierEvent -Event $bad -PipeName ('cn-none-' + [guid]::NewGuid().ToString('N')) -TimeoutMs 10 } | Should Not Throw
    }

    It '<Case> → отброшено с WARN, следующее событие принимается' -TestCases @(
        @{ Case = 'невалидный JSON'; Payload = "{ not json`n"; Warn = 'невалидный JSON' },
        @{ Case = 'JSON-массив'; Payload = "[1,2]`n"; Warn = 'невалидный JSON' },
        @{ Case = 'кадр длиннее лимита'; Payload = ('{"p":"' + ('x' * 300) + '"}' + "`n"); Warn = 'длиннее' }
    ) {
        param($Case, $Payload, $Warn)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $name = 'cn-test-' + [guid]::NewGuid().ToString('N')
        $server = Start-NotifierPipeServer -Queue $queue -PipeName $name -DataRoot $root -MaxChars 256
        try {
            Wait-Until { $server.State.Listening } | Should Be $true
            Send-Raw $name $Payload
            Wait-Until { Test-Path (Join-Path $root 'log.txt') } | Should Be $true
            (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match "\[WARN\] Ipc: .*$Warn"
            $queue.Count | Should Be 0

            $ok = $false
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not $ok -and [DateTime]::UtcNow -lt $deadline) {
                $ok = Send-NotifierEvent -Event @{ after = 1 } -PipeName $name -TimeoutMs 200
            }
            $ok | Should Be $true
            Wait-Until { $queue.Count -ge 1 } | Should Be $true
        }
        finally { [void](Stop-NotifierPipeServer -Server $server) }
    }

    It 'пустое подключение без данных игнорируется' {
        $t = New-TestServer $TestDrive
        try {
            Send-Raw $t.Name ''
            Send-NotifierEvent -Event @{ z = 1 } -PipeName $t.Name -TimeoutMs 1000 | Should Be $true
            Wait-Until { $t.Queue.Count -ge 1 } | Should Be $true
            $t.Queue.Count | Should Be 1
        }
        finally { [void](Stop-NotifierPipeServer -Server $t.Server) }
    }

    It 'Stop-NotifierPipeServer освобождает pipe: новый сервер с тем же именем стартует' {
        $t = New-TestServer $TestDrive
        Stop-NotifierPipeServer -Server $t.Server | Should Be $true
        $t.Server.State.Listening | Should Be $false
        Send-NotifierEvent -Event @{ a = 1 } -PipeName $t.Name -TimeoutMs 50 | Should Be $false

        $queue2 = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server2 = Start-NotifierPipeServer -Queue $queue2 -PipeName $t.Name -DataRoot $TestDrive
        try {
            Wait-Until { $server2.State.Listening } | Should Be $true
            Send-NotifierEvent -Event @{ a = 2 } -PipeName $t.Name -TimeoutMs 1000 | Should Be $true
        }
        finally { [void](Stop-NotifierPipeServer -Server $server2) }
    }
}
