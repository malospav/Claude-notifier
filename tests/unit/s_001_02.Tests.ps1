BeforeAll {
    $libDir = Resolve-Path (Join-Path $PSScriptRoot '..\..\src\lib')
    Import-Module (Join-Path $libDir 'Log.psm1') -Force
    Import-Module (Join-Path $libDir 'Config.psm1') -Force
    Import-Module (Join-Path $libDir 'Event.psm1') -Force

    $cfg = Get-NotifierDefaultConfig

    # Пример входа Stop из документации Claude Code (поля common + last_assistant_message).
    $stopJson = @'
{ "session_id": "abc123", "transcript_path": "C:\\Users\\u\\.claude\\projects\\x\\1.jsonl",
  "cwd": "C:\\dev\\Tools\\claude-notifier", "hook_event_name": "Stop",
  "last_assistant_message": "Готово: тесты проходят.", "extra_field": "drop me" }
'@
}

Describe 's_001_02 · ConvertTo-NotifierEvent' {
    It 'Stop → событие v1 со всеми полями' {
        $e = ConvertTo-NotifierEvent -HookKind stop -Json $stopJson -EntryPoint '' -HostSessionId '' -Config $cfg -DataRoot $TestDrive
        $names = ($e.PSObject.Properties | ForEach-Object { $_.Name }) -join ','
        $names | Should -Be 'v,id,ts,type,session_id,host_session_id,origin,project,title,preview,window'
        $e.v | Should -Be 1
        { [guid]::Parse($e.id) } | Should -Not -Throw
        $e.ts | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
        $e.type | Should -Be 'done'
        $e.session_id | Should -Be 'abc123'
        $e.preview | Should -Be 'Готово: тесты проходят.'
        $e.project | Should -Be 'claude-notifier'
        $e.title | Should -Be 'Готово · claude-notifier'
        $e.window | Should -Be $null
    }

    It 'Notification → permission с текстом из message' {
        $json = '{ "session_id": "s", "cwd": "C:\\p\\app", "hook_event_name": "Notification", "message": "Claude needs your permission", "title": "Permission needed", "notification_type": "permission_prompt" }'
        $e = ConvertTo-NotifierEvent -HookKind notification -Json $json -Config $cfg -DataRoot $TestDrive
        $e.type | Should -Be 'permission'
        $e.preview | Should -Be 'Claude needs your permission'
        $e.title | Should -Be 'Нужно разрешение · app'
    }

    It 'StopFailure → error: "<Expected>"' -TestCases @(
        @{ Json = '{ "cwd": "C:\\p", "error": "rate_limit", "error_details": "429 Too Many Requests" }'; Expected = 'rate_limit: 429 Too Many Requests' },
        @{ Json = '{ "cwd": "C:\\p", "error": "server_error" }'; Expected = 'server_error' },
        @{ Json = '{ "cwd": "C:\\p" }'; Expected = '' }
    ) {
        param($Json, $Expected)
        $e = ConvertTo-NotifierEvent -HookKind stopfailure -Json $Json -Config $cfg -DataRoot $TestDrive
        $e.type | Should -Be 'error'
        $e.preview | Should -Be $Expected
    }

    It 'origin = <Origin> при CLAUDE_CODE_ENTRYPOINT=<EntryPoint>' -TestCases @(
        @{ EntryPoint = 'claude-desktop'; Origin = 'desktop' },
        @{ EntryPoint = 'cli'; Origin = 'cli' },
        @{ EntryPoint = ''; Origin = 'cli' }
    ) {
        param($EntryPoint, $Origin)
        $e = ConvertTo-NotifierEvent -HookKind stop -Json $stopJson -EntryPoint $EntryPoint -Config $cfg -DataRoot $TestDrive
        $e.origin | Should -Be $Origin
    }

    It 'host_session_id берётся из CLAUDE_CODE_HOST_SESSION_ID или null' {
        (ConvertTo-NotifierEvent -HookKind stop -Json $stopJson -HostSessionId 'local_42' -Config $cfg -DataRoot $TestDrive).host_session_id | Should -Be 'local_42'
        (ConvertTo-NotifierEvent -HookKind stop -Json $stopJson -HostSessionId '' -Config $cfg -DataRoot $TestDrive).host_session_id | Should -Be $null
    }

    It 'по умолчанию читает origin и host_session_id из переменных среды' {
        $oldE = $env:CLAUDE_CODE_ENTRYPOINT; $oldH = $env:CLAUDE_CODE_HOST_SESSION_ID
        try {
            $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'; $env:CLAUDE_CODE_HOST_SESSION_ID = 'local_env'
            $e = ConvertTo-NotifierEvent -HookKind stop -Json $stopJson -Config $cfg -DataRoot $TestDrive
            $e.origin | Should -Be 'desktop'
            $e.host_session_id | Should -Be 'local_env'
        }
        finally { $env:CLAUDE_CODE_ENTRYPOINT = $oldE; $env:CLAUDE_CODE_HOST_SESSION_ID = $oldH }
    }

    It 'project для cwd "<Cwd>" = "<Project>"' -TestCases @(
        @{ Cwd = 'C:\\dev\\Tools\\claude-notifier\\'; Project = 'claude-notifier'; Title = 'Готово · claude-notifier' },
        @{ Cwd = '/home/u/repo'; Project = 'repo'; Title = 'Готово · repo' },
        @{ Cwd = ''; Project = ''; Title = 'Готово' }
    ) {
        param($Cwd, $Project, $Title)
        $e = ConvertTo-NotifierEvent -HookKind stop -Json "{ `"cwd`": `"$Cwd`" }" -Config $cfg -DataRoot $TestDrive
        $e.project | Should -Be $Project
        $e.title | Should -Be $Title
    }

    It 'без cwd → project пустой' {
        (ConvertTo-NotifierEvent -HookKind stop -Json '{}' -Config $cfg -DataRoot $TestDrive).project | Should -Be ''
    }

    It 'поле неверного типа игнорируется' {
        $e = ConvertTo-NotifierEvent -HookKind stop -Json '{ "last_assistant_message": 42, "session_id": [1] }' -Config $cfg -DataRoot $TestDrive
        $e.preview | Should -Be ''
        $e.session_id | Should -Be $null
    }

    It 'длина превью берётся из конфига' {
        $short = Get-NotifierDefaultConfig
        $short.previewLength = 20
        $e = ConvertTo-NotifierEvent -HookKind stop -Json ('{ "last_assistant_message": "' + ('x' * 50) + '" }') -Config $short -DataRoot $TestDrive
        $e.preview.Length | Should -Be 20
    }

    It 'без -Config читает настройки из DataRoot' {
        $root = Join-Path $TestDrive 'cfgroot'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "previewLength": 30 }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $e = ConvertTo-NotifierEvent -HookKind stop -Json ('{ "last_assistant_message": "' + ('y' * 100) + '" }') -DataRoot $root
        $e.preview.Length | Should -Be 30
    }

    It '<Case> → $null и WARN' -TestCases @(
        @{ Case = 'битый JSON'; Kind = 'stop'; Json = '{ not json' },
        @{ Case = 'JSON-массив'; Kind = 'stop'; Json = '[1,2]' },
        @{ Case = 'пустой stdin'; Kind = 'stop'; Json = '' },
        @{ Case = 'неизвестный HookKind'; Kind = 'bogus'; Json = '{}' }
    ) {
        param($Case, $Kind, $Json)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $e = ConvertTo-NotifierEvent -HookKind $Kind -Json $Json -Config $cfg -DataRoot $root
        $e | Should -Be $null
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] Event:'
    }

    It 'не читает переменные среды с TOKEN или KEY в имени' {
        $src = Get-Content (Join-Path $libDir 'Event.psm1') -Raw
        $src | Should -Not -Match '(?i)env:[A-Z_]*(TOKEN|KEY)'
        $src | Should -Not -Match '(?i)GetEnvironmentVariables?\('
    }
}

Describe 's_001_02 · Format-NotifierPreview' {
    It '"<Name>"' -TestCases @(
        @{ Name = 'переводы строк → пробел'; Text = "a`r`nb`nc`td"; Max = 200; Expected = 'a b c d' },
        @{ Name = 'повторные пробелы схлопываются'; Text = "  a    b  "; Max = 200; Expected = 'a b' },
        @{ Name = 'ровно на границе не режется'; Text = ('z' * 10); Max = 10; Expected = ('z' * 10) },
        @{ Name = 'длиннее границы → обрезка с …'; Text = ('z' * 11); Max = 10; Expected = ('z' * 9) + [char]0x2026 },
        @{ Name = 'null → пусто'; Text = $null; Max = 10; Expected = '' }
    ) {
        param($Name, $Text, $Max, $Expected)
        Format-NotifierPreview -Text $Text -MaxLength $Max | Should -BeExactly $Expected
    }

    It '500 символов → ровно 200 с … в конце' {
        $p = Format-NotifierPreview -Text ('w' * 500) -MaxLength 200
        $p.Length | Should -Be 200
        $p[-1] | Should -Be ([char]0x2026)
    }
}
