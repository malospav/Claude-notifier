BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
    [ClaudeNotifier.Ui.Motion]::Force($true)
    $script:TrayNoOutput = $true
    $script:BridgeSource = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\hook-bridge.ps1'))
    function New-Root([string]$Name) { $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory $d -Force | Out-Null; $script:TrayDataRoot = $d; return $d }
    function New-Sess([string]$Sid, [string]$State, [string]$Origin = 'cli') {
        return [pscustomobject]@{ session_id = $Sid; project = "p-$Sid"; origin = $Origin; device = ''; state = $State; window = [pscustomobject]@{ hwnd = 1; pid = 4242 } }
    }
}

Describe 's_019_01 · разрешение по шаблону' {
    It 'шаблон: Bash — два слова, цепочки — нельзя; WebFetch — домен; правка — любые' {
        Get-NotifierAutoAllowPrefix -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test -- --watch' }) | Should -Be 'npm test'
        ($null -eq (Get-NotifierAutoAllowPrefix -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test && rm -rf /' }))) | Should -Be $true
        ($null -eq (Get-NotifierAutoAllowPrefix -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'cat a | sh' }))) | Should -Be $true
        Get-NotifierAutoAllowPrefix -ToolName WebFetch -ToolInput ([pscustomobject]@{ url = 'https://docs.example.com/a' }) | Should -Be 'docs.example.com'
        Get-NotifierAutoAllowPrefix -ToolName Edit -ToolInput ([pscustomobject]@{ file_path = 'C:\x\a.cs' }) | Should -Be ''
    }

    It 'правило: тот же проект и начало команды целым словом; цепочка, другой проект, истёкшее — нет' {
        $root = New-Root 'rules'
        $now = [DateTime]::UtcNow
        $r = Add-NotifierAutoAllowRule -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test' }) -Minutes 30 -DataRoot $root -Now $now
        $r.prefix | Should -Be 'npm test'
        (Test-NotifierAutoAllow -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test -- a.spec' }) -DataRoot $root) | Should -Not -BeNullOrEmpty
        (Test-NotifierAutoAllow -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm testing' }) -DataRoot $root) | Should -BeNullOrEmpty
        (Test-NotifierAutoAllow -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test; curl evil' }) -DataRoot $root) | Should -BeNullOrEmpty
        (Test-NotifierAutoAllow -Project 'other' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test' }) -DataRoot $root) | Should -BeNullOrEmpty
        (Test-NotifierAutoAllow -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test' }) -DataRoot $root -Now $now.AddMinutes(31)) | Should -BeNullOrEmpty
        # То же правило — продлевается, а не дублируется; убрать по номеру.
        [void](Add-NotifierAutoAllowRule -Project 'shop' -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'npm test' }) -DataRoot $root)
        @(Get-NotifierAutoAllowRules -DataRoot $root).Count | Should -Be 1
        Remove-NotifierAutoAllowRule -Index 0 -DataRoot $root
        @(Get-NotifierAutoAllowRules -DataRoot $root).Count | Should -Be 0
    }

    It 'хук разрешения проверяет правила до создания запроса' {
        $a = $script:BridgeSource.IndexOf('Test-NotifierAutoAllow')
        $b = $script:BridgeSource.IndexOf('$req = New-NotifierPermissionRequest')
        ($a -gt 0 -and $a -lt $b) | Should -Be $true
    }
}

Describe 's_019_01 · маскот растёт, сценки, свой у проекта' {
    It 'уровни: 5 задач — 2-й, 15 — 3-й; что открывается' {
        (Get-NotifierLevelOf -Xp 0).Level | Should -Be 1
        (Get-NotifierLevelOf -Xp 4).Level | Should -Be 1
        (Get-NotifierLevelOf -Xp 5).Level | Should -Be 2
        (Get-NotifierLevelOf -Xp 15).Level | Should -Be 3
        (Get-NotifierLevelOf -Xp 15).Next | Should -Be 30
        [ClaudeNotifier.Ui.MascotStyle]::LevelUnlock(6) | Should -Be 'корона'
        [ClaudeNotifier.Ui.MascotStyle]::LevelFriend(4) | Should -Be 60
    }

    It '«Готово» — опыт и уровень; пятая ошибка подряд — счёт серии' {
        $root = New-Root 'xp'
        Mock Test-NotifierNotchActive { $true }
        Mock Get-NotifierHistory { @() }
        Invoke-NotifierMascotEvent -Event ([pscustomobject]@{ type = 'done'; session_id = 'a'; taskSeconds = 4000 }) -DataRoot $root
        (Get-NotifierMascotProgress -DataRoot $root) | Should -Be 1
        foreach ($i in 1..4) { Invoke-NotifierMascotEvent -Event ([pscustomobject]@{ type = 'done'; session_id = 'a' }) -DataRoot $root }
        (Get-NotifierMascotProgress -DataRoot $root) | Should -Be 5
        [ClaudeNotifier.Ui.NotchView]::MascotLevel | Should -Be 2
        $script:ErrorStreak = 0
        foreach ($i in 1..5) { Invoke-NotifierMascotEvent -Event ([pscustomobject]@{ type = 'error'; session_id = 'a' }) -DataRoot $root }
        $script:ErrorStreak | Should -Be 5
    }

    It 'свой маскот у проекта: всегда один и тот же, у устройства — свой' {
        [ClaudeNotifier.Ui.Mascot]::Kind = 'flatsphynx'
        [ClaudeNotifier.Ui.Mascot]::ByProject = $true
        try {
            $a = [ClaudeNotifier.Ui.Mascot]::ForItem('', 'shop')
            [ClaudeNotifier.Ui.Mascot]::ForItem('', 'shop') | Should -Be $a
            [ClaudeNotifier.Ui.Mascot]::Kinds -contains $a | Should -Be $true
            [ClaudeNotifier.Ui.Mascot]::SetDevice('mac', 'fox')
            [ClaudeNotifier.Ui.Mascot]::ForItem('mac', 'shop') | Should -Be 'fox'
            [ClaudeNotifier.Ui.Mascot]::ByProject = $false
            [ClaudeNotifier.Ui.Mascot]::ForItem('', 'shop') | Should -Be 'flatsphynx'
        }
        finally { [ClaudeNotifier.Ui.Mascot]::ByProject = $false; [ClaudeNotifier.Ui.Mascot]::ClearDevices() }
    }

    It 'сценки рисуются: салют, чай, игра с мячиком, звёзды уровня' {
        $bmp = New-Object System.Drawing.Bitmap 200, 200
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            foreach ($r in @('fireworks', 'tea')) {
                foreach ($age in @(0.1, 0.8, 1.6, 2.4)) {
                    $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Play = $true; $m.React = $r; $m.ReactAge = $age; $m.Level = 10
                    [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF 40, 40, 120, 120), 'flatsphynx', 'waiting', 1.0, 1, $true, $m)
                }
            }
            $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Play = $true; $m.IdlePlay = 2.0
            [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF 40, 40, 120, 120), 'fox', 'waiting', 1.0, 1, $true, $m)
        }
        finally { $g.Dispose(); $bmp.Dispose() }
    }
}

Describe 's_019_01 · прогноз лимита' {
    It 'тратится быстро — к какому времени кончится; медленно или после сброса — без прогноза' {
        $t0 = [DateTime]::UtcNow.AddMinutes(-30)
        $reset = ([DateTimeOffset]$t0.AddHours(4)).ToUnixTimeSeconds()
        $s = @(@{ At = $t0; P = 10.0; Reset = $reset }, @{ At = $t0.AddMinutes(30); P = 40.0; Reset = $reset })
        $eta = Get-NotifierLimitForecast -Samples $s -Now $t0.AddMinutes(30)
        $eta | Should -Not -BeNullOrEmpty
        [Math]::Round(($eta - $t0.AddMinutes(30)).TotalMinutes) | Should -Be 60   # 60 % осталось, 1 % в минуту
        $slow = @(@{ At = $t0; P = 10.0; Reset = $reset }, @{ At = $t0.AddMinutes(30); P = 10.3; Reset = $reset })
        Get-NotifierLimitForecast -Samples $slow -Now $t0.AddMinutes(30) | Should -BeNullOrEmpty
        $soon = ([DateTimeOffset]$t0.AddMinutes(50)).ToUnixTimeSeconds()
        $late = @(@{ At = $t0; P = 10.0; Reset = $soon }, @{ At = $t0.AddMinutes(30); P = 40.0; Reset = $soon })
        Get-NotifierLimitForecast -Samples $late -Now $t0.AddMinutes(30) | Should -BeNullOrEmpty
        Get-NotifierLimitForecast -Samples @($s[1]) | Should -BeNullOrEmpty
    }
}

Describe 's_019_01 · очередь и продолжение после лимита' {
    It 'очередь: добавить, убрать; сеанс освободился — уходит первое задание' {
        $root = New-Root 'queue'
        Add-NotifierQueuedTask -SessionId 's1' -Text 'первое' | Should -Be 1
        Add-NotifierQueuedTask -SessionId 's1' -Text 'второе' | Should -Be 2
        Mock Get-NotifierSessions { @((New-Sess 's1' 'working')) }
        Mock Send-NotifierSessionText { 'reply' }
        Invoke-NotifierQueueTick
        Should -Invoke Send-NotifierSessionText -Times 0 -Exactly   # работает — ждём
        Mock Get-NotifierSessions { @((New-Sess 's1' 'waiting')) }
        Invoke-NotifierQueueTick
        Should -Invoke Send-NotifierSessionText -Times 1 -Exactly -ParameterFilter { $Text -eq 'первое' }
        @(Get-NotifierQueue -SessionId 's1') | Should -Be @('второе')
        Remove-NotifierQueuedTask -SessionId 's1' -All
        @(Get-NotifierQueue -SessionId 's1').Count | Should -Be 0
    }

    It 'лимит: ошибка лимита — ждём сброса; время прошло — «Продолжай»; продолжили сами — ожидание снято' {
        $root = New-Root 'limit'
        $reset = [DateTimeOffset]::UtcNow.AddHours(2).ToUnixTimeSeconds()
        [IO.File]::WriteAllText((Join-Path $root 'usage.json'), ('{"source":"api","at":"' + [DateTime]::UtcNow.ToString('o') + '","five_hour":{"percent":100,"resets_at":' + $reset + '},"seven_day":{"percent":40,"resets_at":' + $reset + '}}'))
        $ev = [pscustomobject]@{ type = 'error'; session_id = 's1'; project = 'shop'; title = 'Ошибка'; preview = 'Claude usage limit reached. Your limit will reset at 5pm' }
        Test-NotifierLimitStop -Event $ev | Should -Be $true
        Test-NotifierLimitStop -Event ([pscustomobject]@{ type = 'error'; title = 'Ошибка'; preview = 'Overloaded' }) | Should -Be $false
        Register-NotifierLimitStop -Event $ev -DataRoot $root
        $w = Get-NotifierLimitWait -SessionId 's1' -DataRoot $root
        [Math]::Abs(($w.Resume - [DateTimeOffset]::FromUnixTimeSeconds($reset).UtcDateTime).TotalSeconds) | Should -BeLessThan 2
        # Шторка: в статусе — когда продолжит.
        $it = New-Object ClaudeNotifier.Ui.NotchItem
        Add-NotifierNotchItemExtras -Item $it -Session (New-Sess 's1' 'error')
        $it.StateText | Should -Match 'продолжу в'
        Mock Get-NotifierSessions { @((New-Sess 's1' 'error')) }
        Mock Send-NotifierSessionText { 'console' }
        Invoke-NotifierLimitResumeTick -Now ([DateTime]::UtcNow) -DataRoot $root
        Should -Invoke Send-NotifierSessionText -Times 0 -Exactly
        Invoke-NotifierLimitResumeTick -Now ([DateTime]::UtcNow.AddHours(2).AddMinutes(1)) -DataRoot $root
        Should -Invoke Send-NotifierSessionText -Times 1 -Exactly -ParameterFilter { $Text -eq 'Продолжай' }
        Get-NotifierLimitWait -SessionId 's1' -DataRoot $root | Should -BeNullOrEmpty
        # Продолжили сами (сеанс работает) — ожидание снимается без отправки.
        Register-NotifierLimitStop -Event $ev -DataRoot $root
        Mock Get-NotifierSessions { @((New-Sess 's1' 'working')) }
        Invoke-NotifierLimitResumeTick -Now ([DateTime]::UtcNow.AddHours(3)) -DataRoot $root
        Should -Invoke Send-NotifierSessionText -Times 1 -Exactly
        Get-NotifierLimitWait -SessionId 's1' -DataRoot $root | Should -BeNullOrEmpty
    }

    It 'доставка: ждёт ответа — через хук; в терминале без хука — в консоль; приложение и другое устройство — нет' {
        $root = New-Root 'deliver'
        Mock Write-NotifierReply { $true }
        Mock Set-NotifierSessionState { $true }
        Mock Send-NotifierConsoleText { $true }
        $script:Pending = @{ Permissions = @(); Replies = @{ 's1' = 1 }; Gone = @() }
        Send-NotifierSessionText -Session (New-Sess 's1' 'waiting') -Text 'Продолжай' | Should -Be 'reply'
        $script:Pending = @{ Permissions = @(); Replies = @{}; Gone = @() }
        Send-NotifierSessionText -Session (New-Sess 's1' 'waiting') -Text 'Продолжай' | Should -Be 'console'
        Send-NotifierSessionText -Session (New-Sess 's1' 'waiting' 'desktop') -Text 'Продолжай' | Should -Be ''
        $remote = New-Sess 's2' 'waiting'; $remote.device = 'mac'
        Send-NotifierSessionText -Session $remote -Text 'x' | Should -Be ''
    }
}

Describe 's_019_01 · изменения сеанса, таймлайн, отчёт недели' {
    It 'журнал: строки добавлены и убраны по файлам; список — новые сверху' {
        $root = New-Root 'chg'
        $tr = Join-Path $root 'j.jsonl'
        $lines = @(
            '{"type":"assistant","timestamp":"2026-11-20T10:00:00.000Z","message":{"content":[{"type":"tool_use","id":"t1","name":"Write","input":{"file_path":"C:\\w\\shop\\a.cs","content":"a\nb\nc\n"}}]}}',
            '{"type":"assistant","timestamp":"2026-11-20T10:01:00.000Z","message":{"content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"C:\\w\\shop\\b.cs","old_string":"x\ny","new_string":"x\ny\nz\nw"}}]}}'
        )
        [IO.File]::WriteAllText($tr, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        $st = Get-NotifierTranscriptStats -Path $tr -StateDir (Join-Path $root 'stats')
        $st.changed | Should -Be 2
        $st.added | Should -Be 7
        $st.removed | Should -Be 2
        $list = @(Get-NotifierTranscriptChanges -Path $tr -StateDir (Join-Path $root 'stats'))
        $list[0].path | Should -Match 'b\.cs$'
        $list[0].add | Should -Be 4
        $it = New-Object ClaudeNotifier.Ui.NotchItem
        Add-NotifierNotchItemExtras -Item $it -Session ([pscustomobject]@{ session_id = 'x'; device = ''; state = 'waiting'; stats = [pscustomobject]$st })
        $it.Changes | Should -Be "2 файла $([char]0x00B7) +7 $([char]0x2212)2"
    }

    It 'таймлайн: смены статуса → полосы проектов; строка для статистики' {
        $root = New-Root 'tl'
        $script:TimelineLast = @{}
        $now = [DateTime]::Now
        Mock Get-NotifierSessions { @([pscustomobject]@{ session_id = 'a' }) }
        $base = $now.AddMinutes(-40).ToUniversalTime()
        if ($base.ToLocalTime().Date -ne $now.Date) { $base = $now.Date.AddMinutes(1).ToUniversalTime() }
        Add-NotifierTimelineMark -Event ([pscustomobject]@{ type = 'working'; session_id = 'a'; project = 'shop' }) -Now $base
        Add-NotifierTimelineMark -Event ([pscustomobject]@{ type = 'working'; session_id = 'a'; project = 'shop' }) -Now $base.AddMinutes(5)   # тот же статус — не пишется
        Add-NotifierTimelineMark -Event ([pscustomobject]@{ type = 'done'; session_id = 'a'; project = 'shop' }) -Now $base.AddMinutes(30)
        @([IO.File]::ReadAllLines((Join-Path $root 'timeline.jsonl'))).Count | Should -Be 2
        $tl = Get-NotifierTimeline -Now $now
        @($tl.Lanes).Count | Should -Be 1
        $tl.Lanes[0].Project | Should -Be 'shop'
        [Math]::Round($tl.Worked / 60) | Should -BeIn @(29, 30)
        $row = New-NotifierTimelineRow -Now $now
        $row.Kind | Should -Be 'timeline'
        $row.Labels | Should -Be @('shop')
    }

    It 'отчёт недели: задачи прошлой недели; один раз в понедельник' {
        $root = New-Root 'report'
        $mon = [DateTime]::Now.Date.AddDays(-((([int][DateTime]::Now.DayOfWeek) + 6) % 7))
        $ev = @(
            [pscustomobject]@{ v = 1; type = 'done'; ts = $mon.AddDays(-3).ToUniversalTime().ToString('o'); taskSeconds = 600 },
            [pscustomobject]@{ v = 1; type = 'done'; ts = $mon.AddDays(-1).ToUniversalTime().ToString('o') },
            [pscustomobject]@{ v = 1; type = 'done'; ts = $mon.AddHours(1).ToUniversalTime().ToString('o') }
        )
        Mock Get-NotifierHistory { $ev }
        Mock Get-NotifierActivitySummary { @{ Days = @(); Week = @() } }
        $r = Get-NotifierWeekReport -Now $mon.AddHours(10)
        $r.Tasks | Should -Be 2
        $r.Longest | Should -Be 600
        Mock Test-NotifierNotchActive { $true }
        Mock Get-NotifierIdleSeconds { 0 }
        Mock Show-NotifierWeekReport { }
        $script:TrayNoOutput = $false
        try {
            Invoke-NotifierWeeklyReportTick -Now $mon.AddHours(10) -DataRoot $root
            Invoke-NotifierWeeklyReportTick -Now $mon.AddHours(11) -DataRoot $root
            Invoke-NotifierWeeklyReportTick -Now $mon.AddDays(1).AddHours(10) -DataRoot $root
        }
        finally { $script:TrayNoOutput = $true }
        Should -Invoke Show-NotifierWeekReport -Times 1 -Exactly
    }
}

Describe 's_019_01 · шторка: новые строки и страницы рисуются' {
    It 'таймлайн, отчёт, очередь и изменения на карточке, игра с мячиком' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'a'; $it.Title = 'shop'; $it.State = 'waiting'; $it.Project = 'shop'
            $it.Changes = '2 файла · +7 −2'; $it.Queued = 2; $it.CanQueue = $true
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $tl = New-Object ClaudeNotifier.Ui.NotchRow; $tl.Kind = 'timeline'; $tl.Title = 'Сегодня по часам'; $tl.Subtitle = 'x'
            $tl.Labels = [string[]]@('shop', 'api'); $tl.Values = [double[]]@(600); $tl.Actions = [string[]]@('0|480|530|working', '1|500|560|waiting', '0|540|545|error')
            $v.SetRows('stats', [ClaudeNotifier.Ui.NotchRow[]]@($tl))
            $info = New-Object ClaudeNotifier.Ui.NotchRow; $info.Kind = 'info'; $info.Title = 'Задач готово'; $info.Value = '12'
            $v.SetRows('report', [ClaudeNotifier.Ui.NotchRow[]]@($info))
            [ClaudeNotifier.Ui.NotchView]::IdleAfterSeconds = 0
            foreach ($page in @('home', 'stats', 'report')) {
                $f.SetExpanded($true, $page, $false); $v.Page = $page
                $sz = $f.SizeFor(); $f.ClientSize = $sz
                $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
                $v.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height)))
                $bmp.Dispose()
                if ($page -eq 'home') { ($v.HitIds() -contains 'page:changes') | Should -Be $true; ($v.HitIds() -contains 'page:queue') | Should -Be $true }
            }
        }
        finally { [ClaudeNotifier.Ui.NotchView]::IdleAfterSeconds = 90; $f.Dispose() }
    }
}
