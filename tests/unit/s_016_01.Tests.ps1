BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    [void](Import-NotifierUi)
}

Describe 's_016_01 · хуки через curl.exe: приём треем на 127.0.0.1' {
    BeforeAll {
        $script:port = 47690 + (Get-Random -Maximum 200)
        [ClaudeNotifier.Ui.HookServer]::Start($script:port) | Should -Be $true
        $script:curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        function Send-Hook([string]$Kind, [string]$Json, [string[]]$Extra = @('-H', 'X-Claude-Notifier: hook')) {
            $tmp = Join-Path $TestDrive "in-$([guid]::NewGuid().ToString('N')).json"
            [IO.File]::WriteAllText($tmp, $Json, (New-Object System.Text.UTF8Encoding $false))
            $code = & $script:curl -s -m 5 -o NUL -w '%{http_code}' @Extra --data-binary "@$tmp" "http://127.0.0.1:$($script:port)/claude-notifier/hook/$Kind"
            return [string]$code
        }
        function Get-Calls { $list = @(); $c = $null; while ([ClaudeNotifier.Ui.HookServer]::Calls.TryDequeue([ref]$c)) { $list += $c }; return $list }
    }
    AfterAll { [ClaudeNotifier.Ui.HookServer]::Stop() }

    It 'принимает хук с нашим заголовком: вид, тело в UTF-8, процесс curl и предок' {
        [void](Get-Calls)
        Send-Hook 'stop' '{"session_id":"s1","cwd":"C:\\dev\\shop","last_assistant_message":"Готово, всё работает"}' | Should -Be '204'
        Start-Sleep -Milliseconds 100
        $calls = @(Get-Calls)
        $calls.Count | Should -Be 1
        $calls[0].Kind | Should -Be 'stop'
        $calls[0].Body | Should -Match 'Готово, всё работает'
        ($calls[0].CallerPid -gt 0) | Should -Be $true
    }

    It 'отклоняет чужое: без заголовка, с Origin (браузер), неизвестный вид, GET' {
        [void](Get-Calls)
        Send-Hook 'stop' '{}' -Extra @() | Should -Be '403'
        Send-Hook 'stop' '{}' -Extra @('-H', 'X-Claude-Notifier: hook', '-H', 'Origin: http://evil.example') | Should -Be '403'
        Send-Hook 'rm-rf' '{}' | Should -Be '404'
        [string](& $script:curl -s -o NUL -w '%{http_code}' -H 'X-Claude-Notifier: hook' "http://127.0.0.1:$($script:port)/claude-notifier/hook/stop") | Should -Be '403'
        Start-Sleep -Milliseconds 100
        @(Get-Calls).Count | Should -Be 0
    }

    It 'с секретом установки: прежний «hook» и чужой секрет отклоняются, верный принимается' {
        [void](Get-Calls)
        $secret = Get-NotifierHookSecret -DataRoot (Join-Path $TestDrive 'sec') -Create
        $secret | Should -Match '^[A-Za-z0-9_-]{43}$'
        Get-NotifierHookSecret -DataRoot (Join-Path $TestDrive 'sec') | Should -Be $secret   # повторно — тот же
        Get-NotifierHookSecret -DataRoot (Join-Path $TestDrive 'nosec') | Should -Be ''
        [ClaudeNotifier.Ui.HookServer]::Secret = $secret
        try {
            Send-Hook 'stop' '{}' | Should -Be '403'
            Send-Hook 'stop' '{}' -Extra @('-H', "X-Claude-Notifier: $($secret.Substring(1))x") | Should -Be '403'
            Send-Hook 'stop' '{"session_id":"sec"}' -Extra @('-H', "X-Claude-Notifier: $secret") | Should -Be '204'
        }
        finally { [ClaudeNotifier.Ui.HookServer]::Secret = '' }
        Start-Sleep -Milliseconds 100
        @(Get-Calls).Count | Should -Be 1
    }

    It 'переменные окружения сеанса — через заголовки curl (--variable, без оболочки)' {
        [void](Get-Calls)
        $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'; $env:CLAUDE_CODE_HOST_SESSION_ID = 'local_abc'
        try {
            Send-Hook 'prompt' '{"session_id":"s2"}' -Extra @('-H', 'X-Claude-Notifier: hook', '--variable', '%CLAUDE_CODE_ENTRYPOINT=', '--variable', '%CLAUDE_CODE_HOST_SESSION_ID=',
                '--expand-header', 'X-Claude-Entry: {{CLAUDE_CODE_ENTRYPOINT}}', '--expand-header', 'X-Claude-Host: {{CLAUDE_CODE_HOST_SESSION_ID}}') | Should -Be '204'
        }
        finally { Remove-Item Env:CLAUDE_CODE_ENTRYPOINT, Env:CLAUDE_CODE_HOST_SESSION_ID -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 100
        $c = @(Get-Calls)[0]
        $c.Entry | Should -Be 'claude-desktop'
        $c.HostSession | Should -Be 'local_abc'
    }

    It 'вызов → событие v1 как от моста: тип, проект, окно; выключенный тип — отброшен' {
        $script:TrayDataRoot = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $call = New-Object ClaudeNotifier.Ui.HookCall
        $call.Kind = 'stop'; $call.Body = '{"session_id":"s3","cwd":"C:\\dev\\shop","last_assistant_message":"Сделано"}'
        $call.Entry = ''; $call.ConsoleHwnd = 4242; $call.WalkHwnd = 777; $call.ClaudePid = 99
        $ev = ConvertFrom-NotifierHookCall -Call $call
        $ev.type | Should -Be 'done'
        $ev.session_id | Should -Be 's3'
        $ev.project | Should -Be 'shop'
        $ev.origin | Should -Be 'cli'
        $ev.window.hwnd | Should -Be 4242   # CLI — окно консоли
        $ev.window.pid | Should -Be 99
        $call.Entry = 'claude-desktop'
        (ConvertFrom-NotifierHookCall -Call $call).window.hwnd | Should -Be 777   # приложение — окно предка
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"events":{"done":{"enabled":false}}}')
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).events.done.enabled | Should -Be $false
        ConvertFrom-NotifierHookCall -Call $call | Should -Be $null
        Remove-Item (Join-Path $script:TrayDataRoot 'config.json')
        # Из очереди сервера — в очередь трея.
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        [ClaudeNotifier.Ui.HookServer]::Calls.Enqueue($call)
        Invoke-NotifierHookCalls | Should -Be 1
    }
}
