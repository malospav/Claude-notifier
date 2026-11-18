BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)

    function Write-Lines([string]$Path, [string[]]$Lines, [switch]$Append) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $text = ($Lines -join "`n") + "`n"
        if ($Append) { [IO.File]::AppendAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
        else { [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
    }

    # Время записи — сегодня в 10:00 по местному времени (день статистики — по местному времени).
    $script:Base = [DateTime]::Today.AddHours(10)
    function Ts([double]$Minutes, [int]$DaysAgo = 0) { $script:Base.AddDays(-$DaysAgo).AddMinutes($Minutes).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }

    function New-ProjectsDir([string]$Root) {
        $shop = Join-Path $Root 'C--dev-shop'
        Write-Lines (Join-Path $shop 's1.jsonl') @(
            ('{"type":"user","timestamp":"' + (Ts 0) + '","cwd":"C:\\dev\\shop","message":{"content":"x"}}'),
            ('{"type":"assistant","timestamp":"' + (Ts 1) + '","cwd":"C:\\dev\\shop","message":{"id":"msg_1","usage":{"output_tokens":10}}}'),
            ('{"type":"assistant","timestamp":"' + (Ts 1.1667) + '","cwd":"C:\\dev\\shop","message":{"id":"msg_1","usage":{"output_tokens":30}}}'),
            ('{"type":"user","timestamp":"' + (Ts 2) + '","cwd":"C:\\dev\\shop","message":{"content":[{"type":"tool_result"}]}}'),
            ('{"type":"assistant","timestamp":"' + (Ts 3) + '","cwd":"C:\\dev\\shop\\docs","message":{"id":"msg_2","usage":{"output_tokens":5}}}'),
            ('{"type":"user","timestamp":"' + (Ts 20) + '","cwd":"C:\\dev\\shop\\docs","message":{"content":"y"}}'),
            ('{"type":"user","isMeta":true,"timestamp":"' + (Ts 20.5) + '","cwd":"C:\\dev\\shop","message":{"content":"meta"}}')
        )
        # Субагент: своя папка в cwd, но проект — его сеанса; время не считается.
        Write-Lines (Join-Path $shop 's1\subagents\agent-x.jsonl') @(
            ('{"type":"user","timestamp":"' + (Ts 4) + '","cwd":"C:\\dev\\other","message":{"content":"task"}}'),
            ('{"type":"assistant","timestamp":"' + (Ts 5) + '","cwd":"C:\\dev\\other","message":{"id":"msg_9","usage":{"output_tokens":100}}}')
        )
        # Имя с дефисом и вчерашний день.
        Write-Lines (Join-Path $Root 'C--dev-Tools-claude-notifier\s2.jsonl') @(
            ('{"type":"user","timestamp":"' + (Ts 0 1) + '","cwd":"C:\\dev\\Tools\\claude-notifier","message":{"content":"z"}}'),
            ('{"type":"assistant","timestamp":"' + (Ts 2 1) + '","cwd":"C:\\dev\\Tools\\claude-notifier","message":{"id":"msg_5","usage":{"output_tokens":2000}}}')
        )
        # Старый журнал (изменён 20 дней назад) не читается.
        $old = Join-Path $Root 'C--dev-old\s3.jsonl'
        Write-Lines $old @(('{"type":"assistant","timestamp":"' + (Ts 0) + '","cwd":"C:\\dev\\old","message":{"id":"msg_7","usage":{"output_tokens":999}}}'))
        (Get-Item $old).LastWriteTime = [DateTime]::Now.AddDays(-20)
    }
}

Describe 's_012_02 · статистика за день и неделю' {
    It 'токены (сообщение — один раз), активное время без пауз > 5 мин, запросы; проект — по папке журнала; субагент — в проект сеанса' {
        $pd = Join-Path $TestDrive 'p1'
        New-ProjectsDir $pd
        $sd = Join-Path $TestDrive 'a1'
        Update-NotifierActivity -ProjectsDir $pd -StateDir $sd | Should -Be 3
        $s = Get-NotifierActivitySummary -StateDir $sd
        @($s.Days).Count | Should -Be 7
        $today = @($s.Days)[-1]
        $today.tokens | Should -Be 135          # 30 + 5 + субагент 100
        $today.seconds | Should -Be 210         # 60 + 10 + 50 + 60 + 30 (служебная запись); пауза 17 мин не считается
        $today.prompts | Should -Be 2           # без результата инструмента и служебного
        @($s.Days)[-2].tokens | Should -Be 2000
        $s.Today.Count | Should -Be 1
        $s.Today[0].project | Should -Be 'shop'
        $s.Today[0].tokens | Should -Be 135
        ($s.Week | ForEach-Object { $_.project }) -join ',' | Should -Be 'claude-notifier,shop'
        $s.Total.tokens | Should -Be 2135
    }

    It 'дочитывает только новые строки; повторный обход без изменений ничего не читает' {
        $pd = Join-Path $TestDrive 'p2'
        New-ProjectsDir $pd
        $sd = Join-Path $TestDrive 'a2'
        [void](Update-NotifierActivity -ProjectsDir $pd -StateDir $sd)
        Update-NotifierActivity -ProjectsDir $pd -StateDir $sd | Should -Be 0
        Write-Lines (Join-Path $pd 'C--dev-shop\s1.jsonl') @(('{"type":"assistant","timestamp":"' + (Ts 21) + '","cwd":"C:\\dev\\shop","message":{"id":"msg_3","usage":{"output_tokens":7}}}')) -Append
        Update-NotifierActivity -ProjectsDir $pd -StateDir $sd | Should -Be 1
        (@((Get-NotifierActivitySummary -StateDir $sd).Days)[-1]).tokens | Should -Be 142
        (@((Get-NotifierActivitySummary -StateDir $sd).Days)[-1]).seconds | Should -Be 240
    }

    It 'длительность: меньше минуты, минуты, часы' {
        Format-NotifierDuration 30 | Should -Be 'меньше минуты'
        Format-NotifierDuration 2700 | Should -Be '45 мин'
        Format-NotifierDuration 11100 | Should -Be '3 ч 05 мин'
        Format-NotifierTokensShort 850 | Should -Be '850'
        Format-NotifierTokensShort 12400 | Should -Be '12 тыс.'
        Format-NotifierTokensShort 1250000 | Should -Be '1,3 млн'
    }

    It 'график и списки: подписи дней, «Сегодня», проекты по разделам' {
        $pd = Join-Path $TestDrive 'p3'
        New-ProjectsDir $pd
        $sd = Join-Path $TestDrive 'a3'
        [void](Update-NotifierActivity -ProjectsDir $pd -StateDir $sd)
        $s = Get-NotifierActivitySummary -StateDir $sd
        $c = ConvertTo-NotifierStatsChart -Summary $s
        $c.Values.Count | Should -Be 7
        $c.Labels[6] | Should -Be 'Сегодня'
        $c.Labels[0] | Should -Match '^[А-Я][а-я]$'
        $c.ValueLabels[5] | Should -Be '2 тыс.'
        $c.Highlight | Should -Be 6
        $cards = ConvertTo-NotifierStatsCards -Summary $s
        $cards.Count | Should -Be 3
        $cards[0].Section | Should -Be 'Сегодня'
        $cards[0].Title | Should -Be 'shop'
        $cards[0].StateText | Should -Be '3 мин'
        $cards[0].Right | Should -Be '135 токенов'
        $cards[2].Section | Should -Be 'За 7 дней'
    }

    It 'страница «Статистика»: иконка в заголовке, подсчёт в фоне, график и списки' {
        $script:TrayDataRoot = Join-Path $TestDrive 'win'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $pd = Join-Path $TestDrive 'p4'
        New-ProjectsDir $pd
        $script:ActivityProjectsDir = $pd
        $script:ActivitySummary = $null; $script:ActivityJob = $null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $tag = $script:SessionsForm.Tag
            Switch-NotifierPage 3
            $tag.Title.Text | Should -Be 'Статистика'
            $tag.StatsButton.Checked | Should -Be $true
            $script:ActivityJob | Should -Not -Be $null
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not (Complete-NotifierActivityScan) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
            $script:ActivitySummary | Should -Not -Be $null
            $tag.Stats.Chart.Values.Count | Should -Be 7
            $tag.Stats.Summary.Text | Should -Match '^За 7 дней: 2 тыс\. токенов'
            $tag.Stats.List.Count | Should -Be 3
            Test-Path (Join-Path $script:TrayDataRoot 'activity') | Should -Be $true
            $tag.Stats.Chart.Size = New-Object System.Drawing.Size(460, 150)
            $bmp = New-Object System.Drawing.Bitmap 460, 150
            $tag.Stats.Chart.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 460, 150)))
            $bmp.Dispose()
            Switch-NotifierPage 3
            $tag.Title.Text | Should -Be 'Сеансы'
        }
        finally {
            $script:SessionsForm.Dispose(); $script:SessionsForm = $null
            $script:ActivityProjectsDir = $null
        }
    }
}
