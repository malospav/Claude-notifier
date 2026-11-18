BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Usage.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http
    [void](Import-NotifierUi)

    function New-UsageFetch([int]$Code, [string]$Body) {
        $resp = New-Object System.Net.Http.HttpResponseMessage ([System.Net.HttpStatusCode]$Code)
        $resp.Content = New-Object System.Net.Http.StringContent $Body
        return @{ Task = [System.Threading.Tasks.Task]::FromResult($resp); Client = (New-Object System.Net.Http.HttpClient); Started = [DateTime]::UtcNow }
    }
}

Describe 's_011_01 · расход лимитов' {
    It 'ответ сервера (utilization, ISO) и строка статуса (used_percentage, unix) приводятся к одному виду' {
        $api = ConvertFrom-Json '{"five_hour":{"utilization":34.5,"resets_at":"2026-11-17T12:00:00Z"},"seven_day":{"utilization":120,"resets_at":"2026-11-20T09:00:00+00:00"},"other":{"utilization":1}}'
        $w = ConvertFrom-NotifierUsageWindows -Object $api -PercentField utilization
        $w.five_hour.percent | Should -Be 34.5
        $w.five_hour.resets_at | Should -Be ([DateTimeOffset]::Parse('2026-11-17T12:00:00Z').ToUnixTimeSeconds())
        $w.seven_day.percent | Should -Be 100
        $w.Contains('other') | Should -Be $false
        $cli = ConvertFrom-Json '{"five_hour":{"used_percentage":12,"resets_at":1794854941}}'
        $c = ConvertFrom-NotifierUsageWindows -Object $cli -PercentField used_percentage
        $c.five_hour.resets_at | Should -Be 1794854941
        $c.Contains('seven_day') | Should -Be $false
    }

    It 'usage.json: запись и чтение; полосы: процент и сброс; прошедший сброс; нет данных' {
        $root = Join-Path $TestDrive 'u'
        $now = [DateTime]::UtcNow
        $soon = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()
        $past = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds()
        Save-NotifierUsage -DataRoot $root -Source api -Windows ([ordered]@{ five_hour = [ordered]@{ percent = 40; resets_at = $soon }; seven_day = [ordered]@{ percent = 70; resets_at = $past } }) | Should -Be $true
        Save-NotifierUsage -DataRoot $root -Source cli -Windows ([ordered]@{}) | Should -Be $false
        $u = Get-NotifierUsage -DataRoot $root
        $u.source | Should -Be 'api'
        $f = Format-NotifierUsageWindow -Usage $u -Window five_hour -Now $now
        $f.Percent | Should -Be 40
        $f.Detail | Should -Match '^сброс (в \d\d:\d\d|\d\d\.\d\d в \d\d:\d\d)$'
        (Format-NotifierUsageWindow -Usage $u -Window seven_day -Now $now).Detail | Should -Be 'окно обновилось'
        (Format-NotifierUsageWindow -Usage $null -Window five_hour).Percent | Should -Be -1
        Get-NotifierUsage -DataRoot (Join-Path $TestDrive 'none') | Should -Be $null
    }

    It 'токен: только claudeAiOauth и только не истёкший; без входа запрос не запускается' {
        $p = Join-Path $TestDrive 'cred.json'
        [IO.File]::WriteAllText($p, '{"mcpOAuth":{"x":{"accessToken":"mcp"}}}')
        Get-NotifierOAuthToken -CredentialsPath $p | Should -Be $null
        Start-NotifierUsageFetch -CredentialsPath $p | Should -Be $null
        $future = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeMilliseconds()
        [IO.File]::WriteAllText($p, ('{"claudeAiOauth":{"accessToken":"tok","expiresAt":' + $future + '}}'))
        Get-NotifierOAuthToken -CredentialsPath $p | Should -Be 'tok'
        $old = [DateTimeOffset]::UtcNow.AddHours(-1).ToUnixTimeMilliseconds()
        [IO.File]::WriteAllText($p, ('{"claudeAiOauth":{"accessToken":"tok","expiresAt":' + $old + '}}'))
        Get-NotifierOAuthToken -CredentialsPath $p | Should -Be $null
        Get-NotifierOAuthToken -CredentialsPath (Join-Path $TestDrive 'нет.json') | Should -Be $null
    }

    It 'ответ сервера → usage.json; ошибка → WARN; пороги 80/90 % срабатывают по данным сервера один раз' {
        $root = Join-Path $TestDrive 'fetch'
        New-Item -ItemType Directory $root -Force | Out-Null
        $reset = [DateTimeOffset]::UtcNow.AddHours(2).ToString('o')
        Complete-NotifierUsageFetch -DataRoot $root -Fetch (New-UsageFetch 200 ('{"five_hour":{"utilization":85,"resets_at":"' + $reset + '"}}')) | Should -Be 'ok'
        (Get-NotifierUsage -DataRoot $root).five_hour.percent | Should -Be 85
        Complete-NotifierUsageFetch -DataRoot $root -Fetch (New-UsageFetch 401 '{"error":"x"}') | Should -Be 'failed'
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match 'usage: расход не получен: HTTP 401'
        $status = ConvertTo-NotifierLimitStatus -Usage (Get-NotifierUsage -DataRoot $root)
        $hits = @(Test-NotifierLimits -StatusJson $status -DataRoot $root)
        $hits.Count | Should -Be 1
        $hits[0].Threshold | Should -Be 80
        @(Test-NotifierLimits -StatusJson $status -DataRoot $root).Count | Should -Be 0
    }

    It 'трей: опрос раз в 5 минут; готовый ответ — событие лимита в очередь трея' {
        $script:TrayDataRoot = Join-Path $TestDrive 'tick'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:UsageFetch = $null; $script:UsageNextAt = [datetime]::MinValue
        $script:usageBody = '{"seven_day":{"utilization":91,"resets_at":"' + [DateTimeOffset]::UtcNow.AddDays(2).ToString('o') + '"}}'
        Mock Start-NotifierUsageFetch { New-UsageFetch 200 $script:usageBody }
        $now = [DateTime]::UtcNow
        Invoke-NotifierUsageTick -Now $now
        $script:UsageFetch | Should -Not -Be $null
        Invoke-NotifierUsageTick -Now $now
        $script:UsageFetch | Should -Be $null
        $ev = $null
        $script:TrayQueue.TryDequeue([ref]$ev) | Should -Be $true
        $ev.type | Should -Be 'limit'
        Invoke-NotifierUsageTick -Now $now.AddMinutes(1)
        Assert-MockCalled Start-NotifierUsageFetch -Times 1 -Exactly -Scope It
    }

    It 'окно: свой заголовок, иконки переключают страницы, повторный щелчок — назад; полосы: нет данных и значение' {
        $script:TrayDataRoot = Join-Path $TestDrive 'win'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $tag = $script:SessionsForm.Tag
            ($script:SessionsForm -is [ClaudeNotifier.Ui.ChromeForm]) | Should -Be $true
            Switch-NotifierPage 1
            $tag.Title.Text | Should -Be 'Устройства'
            $tag.DevicesButton.Checked | Should -Be $true
            Switch-NotifierPage 2
            $tag.SettingsButton.Checked | Should -Be $true
            $tag.DevicesButton.Checked | Should -Be $false
            Switch-NotifierPage 2
            $tag.Title.Text | Should -Be 'Сеансы'
            Update-NotifierUsageViews
            $tag.Usage.Five.Percent | Should -Be -1
            $tag.Usage.Five.Detail | Should -Match 'нет данных'
            [void](Save-NotifierUsage -DataRoot $script:TrayDataRoot -Source cli -Windows ([ordered]@{ five_hour = [ordered]@{ percent = 55; resets_at = 0 } }))
            Update-NotifierUsageViews
            $tag.Usage.Five.Percent | Should -Be 55
            $tag.Usage.Five.Size = New-Object System.Drawing.Size(300, 40)
            $bmp = New-Object System.Drawing.Bitmap 300, 40
            $tag.Usage.Five.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 300, 40)))
            $bmp.Dispose()
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}
