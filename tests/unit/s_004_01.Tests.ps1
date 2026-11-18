# Pester 5: таблицы -TestCases строятся при обнаружении тестов — помощники нужны и там.
BeforeDiscovery {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Limits.psm1') -Force

    $r1 = 1795000000   # resets_at окна (Unix seconds)
    $r2 = 1795018000

    function New-Status([object]$Five = $null, [object]$Week = $null, [long]$Reset5 = $r1, [long]$Reset7 = $r2) {
        $rl = @{}
        if ($null -ne $Five) { $rl.five_hour = @{ used_percentage = $Five; resets_at = $Reset5 } }
        if ($null -ne $Week) { $rl.seven_day = @{ used_percentage = $Week; resets_at = $Reset7 } }
        $o = @{ session_id = 's1'; cwd = 'C:\dev\Tools\claude-notifier'; model = @{ display_name = 'Opus' } }
        if ($rl.Count -gt 0) { $o.rate_limits = $rl }
        return ($o | ConvertTo-Json -Depth 5 -Compress)
    }

    function Get-Thresholds($Results) { return (@($Results | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Window):$($_.Threshold)" }) -join ',') }
}

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Limits.psm1') -Force

    $r1 = 1795000000   # resets_at окна (Unix seconds)
    $r2 = 1795018000

    function New-Status([object]$Five = $null, [object]$Week = $null, [long]$Reset5 = $r1, [long]$Reset7 = $r2) {
        $rl = @{}
        if ($null -ne $Five) { $rl.five_hour = @{ used_percentage = $Five; resets_at = $Reset5 } }
        if ($null -ne $Week) { $rl.seven_day = @{ used_percentage = $Week; resets_at = $Reset7 } }
        $o = @{ session_id = 's1'; cwd = 'C:\dev\Tools\claude-notifier'; model = @{ display_name = 'Opus' } }
        if ($rl.Count -gt 0) { $o.rate_limits = $rl }
        return ($o | ConvertTo-Json -Depth 5 -Compress)
    }

    function Get-Thresholds($Results) { return (@($Results | Where-Object { $null -ne $_ } | ForEach-Object { "$($_.Window):$($_.Threshold)" }) -join ',') }
}

Describe 's_004_01 · Test-NotifierLimits' {
    It 'последовательность 79 → 80 → 85 → 90 для 5-часового окна' {
        $root = Join-Path $TestDrive 'seq'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 79) -DataRoot $root) | Should -Be ''
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 80) -DataRoot $root) | Should -Be 'five_hour:80'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 85) -DataRoot $root) | Should -Be ''
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 90.4) -DataRoot $root) | Should -Be 'five_hour:90'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 99) -DataRoot $root) | Should -Be ''
    }

    It 'скачок 70 → 95 → одно событие с порогом 90; 80 считается сработавшим' {
        $root = Join-Path $TestDrive 'jump'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 70) -DataRoot $root) | Should -Be ''
        $r = @(Test-NotifierLimits -StatusJson (New-Status 95) -DataRoot $root)
        $r.Count | Should -Be 1
        $r[0].Threshold | Should -Be 90
        $state = Get-Content (Join-Path $root 'limits.json') -Raw | ConvertFrom-Json
        (@($state.five_hour.fired) -join ',') | Should -Be '80,90'
    }

    It 'новый resets_at сбрасывает сработавшие пороги окна' {
        $root = Join-Path $TestDrive 'reset'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 82) -DataRoot $root) | Should -Be 'five_hour:80'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 82) -DataRoot $root) | Should -Be ''
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 82 -Reset5 ($r1 + 18000)) -DataRoot $root) | Should -Be 'five_hour:80'
    }

    It 'окна независимы: оба пересекли порог одновременно' {
        $root = Join-Path $TestDrive 'both'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 81 92) -DataRoot $root) | Should -Be 'five_hour:80,seven_day:90'
    }

    It '<Case> → пусто, без ошибок' -TestCases @(
        @{ Case = 'нет rate_limits'; Json = (New-Status) },
        @{ Case = 'битый JSON'; Json = '{ broken' },
        @{ Case = 'used_percentage не число'; Json = '{ "rate_limits": { "five_hour": { "used_percentage": "x", "resets_at": 1 } } }' },
        @{ Case = 'нет resets_at'; Json = '{ "rate_limits": { "five_hour": { "used_percentage": 95 } } }' },
        @{ Case = 'rate_limits не объект'; Json = '{ "rate_limits": 5 }' }
    ) {
        param($Case, $Json)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        { Test-NotifierLimits -StatusJson $Json -DataRoot $root } | Should -Not -Throw
        @(Test-NotifierLimits -StatusJson $Json -DataRoot $root).Count | Should -Be 0
    }

    It 'пороги берутся из конфига' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "limitThresholds": [50] }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 55) -DataRoot $root) | Should -Be 'five_hour:50'
    }

    It 'битый limits.json → начинается заново с WARN' {
        $root = Join-Path $TestDrive 'badstate'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content (Join-Path $root 'limits.json') '{ nope'
        Get-Thresholds (Test-NotifierLimits -StatusJson (New-Status 85) -DataRoot $root) | Should -Be 'five_hour:80'
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] limits: limits\.json'
    }

    It 'без изменений состояния limits.json не перезаписывается' {
        $root = Join-Path $TestDrive 'nowrite'
        [void](Test-NotifierLimits -StatusJson (New-Status 50) -DataRoot $root)
        Test-Path (Join-Path $root 'limits.json') | Should -Be $false
    }
}

Describe 's_004_01 · превью и событие' {
    It 'превью 5-часового окна: «5 ч: 92 %, сброс в HH:mm» (локальное время)' {
        $hhmm = [DateTimeOffset]::FromUnixTimeSeconds($r1).LocalDateTime.ToString('HH:mm')
        $r = @(Test-NotifierLimits -StatusJson (New-Status 92.4) -DataRoot (Join-Path $TestDrive 'p5'))
        $r[0].Preview | Should -Be "5 ч: 92 %, сброс в $hhmm"
    }

    It 'превью недельного окна: «Неделя: 81 %, сброс dd.MM HH:mm»' {
        $when = [DateTimeOffset]::FromUnixTimeSeconds($r2).LocalDateTime.ToString('dd.MM HH:mm')
        $r = @(Test-NotifierLimits -StatusJson (New-Status $null 81.2) -DataRoot (Join-Path $TestDrive 'p7'))
        $r[0].Preview | Should -Be "Неделя: 81 %, сброс $when"
    }

    It 'New-NotifierLimitEvent → событие v1 типа limit' {
        $r = @(Test-NotifierLimits -StatusJson (New-Status 85) -DataRoot (Join-Path $TestDrive 'ev'))
        $e = New-NotifierLimitEvent -Result $r[0] -StatusJson (New-Status 85) -EntryPoint 'claude-desktop' -HostSessionId 'local_1'
        $e.v | Should -Be 1
        $e.type | Should -Be 'limit'
        $e.title | Should -Be 'Лимит · claude-notifier'
        $e.preview | Should -Be $r[0].Preview
        $e.session_id | Should -Be 's1'
        $e.origin | Should -Be 'desktop'
        $e.host_session_id | Should -Be 'local_1'
        { [guid]::Parse($e.id) } | Should -Not -Throw
        $e.ts | Should -Match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$'
    }

    It 'New-NotifierLimitEvent без cwd → заголовок без проекта, origin cli' {
        $r = [pscustomobject]@{ Window = 'five_hour'; Threshold = 80; Percent = 80; Preview = 'x' }
        $e = New-NotifierLimitEvent -Result $r -StatusJson '{ broken' -EntryPoint '' -HostSessionId ''
        $e.title | Should -Be 'Лимит'
        $e.origin | Should -Be 'cli'
        $e.host_session_id | Should -Be $null
    }
}
