BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Import-Module (Join-Path $repoRoot 'src\lib\Settings.psm1') -Force -WarningAction SilentlyContinue
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
    [ClaudeNotifier.Ui.Motion]::Force($true)

    function New-It([string]$Id, [string]$State, [string[]]$Actions = @(), [string]$Project = '') {
        $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = $Id; $it.Title = $Id; $it.State = $State; $it.Actions = [string[]]$Actions; $it.Project = $Project
        return $it
    }
    function Invoke-Draw($Form) {
        $sz = $Form.SizeFor(); $Form.ClientSize = $sz
        $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
        try { $Form.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))) } finally { $bmp.Dispose() }
    }
    function New-Root([string]$Name) { $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory $d -Force | Out-Null; return $d }
    function New-Ev([string]$Type, [string]$Project, [datetime]$At = [DateTime]::UtcNow, [hashtable]$Extra = @{}) {
        $e = [pscustomobject]@{ v = 1; id = [guid]::NewGuid().ToString(); ts = $At.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"); type = $Type; session_id = "s-$Project"; project = $Project; title = "Готово $([char]0x00B7) $Project"; preview = 'текст' }
        foreach ($k in $Extra.Keys) { $e | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }
        return $e
    }
}

AfterAll { [ClaudeNotifier.Ui.Motion]::Force($null); [ClaudeNotifier.Ui.MascotColor]::Mode = 'none'; [ClaudeNotifier.Ui.NotchView]::DayMood = '' }

Describe 's_018_05 · сеансы в шторке: ждёт, закреплён, разрешить все, лента, файлы' {
    It 'сколько ждёт: подпись и нарастающая тревожность' {
        [ClaudeNotifier.Ui.NotchView]::WaitText(0) | Should -Be ''
        [ClaudeNotifier.Ui.NotchView]::WaitText(12) | Should -Be '12 мин'
        [ClaudeNotifier.Ui.NotchView]::WaitText(125) | Should -Be '2 ч 05 мин'
        [ClaudeNotifier.Ui.NotchView]::WaitUrgency(1) | Should -Be 0
        ([ClaudeNotifier.Ui.NotchView]::WaitUrgency(16) -gt 0.4 -and [ClaudeNotifier.Ui.NotchView]::WaitUrgency(16) -lt 0.6) | Should -Be $true
        [ClaudeNotifier.Ui.NotchView]::WaitUrgency(90) | Should -Be 1
        $it = New-It 'a' 'permission'; $it.WaitSince = [DateTime]::UtcNow.AddMinutes(-7).Ticks
        [ClaudeNotifier.Ui.NotchView]::WaitMinutes($it, [DateTime]::UtcNow) | Should -Be 7
        [ClaudeNotifier.Ui.NotchView]::WaitMinutes((New-It 'b' 'working'), [DateTime]::UtcNow) | Should -Be -1
    }

    It '«Разрешить все»: от двух запросов одного проекта; первое нажатие — подтверждение, второе — команда' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $script:got = New-Object System.Collections.ArrayList
            $v.add_Command({ param($s, $e) [void]$script:got.Add("$($e.Kind)|$($e.Id)|$($e.Action)") })
            $acts = @('allow|Разрешить|primary', 'deny|Запретить|destructive')
            $a = New-It 'a' 'permission' $acts 'shop'; $a.WaitSince = [DateTime]::UtcNow.AddMinutes(-20).Ticks; $a.Pinned = $true
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($a, (New-It 'b' 'permission' $acts 'shop'), (New-It 'c' 'permission' $acts 'other'), (New-It 'd' 'working')))
            $v.SelectedId = 'a'
            $v.AllowAllCount($v.Selected) | Should -Be 2
            $v.AllowAllCount((New-It 'c' 'permission' $acts 'other')) | Should -Be 0
            $f.SetExpanded($true, 'home'); $v.Page = 'home'
            Invoke-Draw $f
            @($v.HitIds()) -contains 'allowall' | Should -Be $true
            $v.ClickArea('allowall', [System.Drawing.Point]::Empty)
            $v.AllowAllArmed($v.Selected) | Should -Be $true
            $script:got.Count | Should -Be 0
            Invoke-Draw $f
            $v.ClickArea('allowall', [System.Drawing.Point]::Empty)
            ($script:got -join ';') | Should -Be 'allowall|a|shop'
        }
        finally { $f.Dispose() }
    }

    It 'лента сеанса под ответом: добавляет высоту и рисуется' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $it = New-It 'a' 'waiting'
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it)); $v.SelectedId = 'a'
            $h0 = $v.AnswerContentHeight(900)
            $it.Feed = [string[]]@('you|10:01|Почини тесты', 'tool|10:02|Edit: Notch.cs · 3 с', 'claude|10:03|Готово, тесты зелёные')
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            ($v.AnswerContentHeight(900) - $h0) | Should -BeGreaterThan 60
            $f.SetExpanded($true, 'answer'); $v.Page = 'answer'
            Invoke-Draw $f
        }
        finally { $f.Dispose() }
    }

    It 'лента из журнала сеанса: вид|время|текст, время инструмента' {
        $s = [pscustomobject]@{ session_id = 's'; stats = [pscustomobject]@{ feed = @(
                    [pscustomobject]@{ ts = '2026-11-19T10:00:00Z'; k = 'you'; text = 'Привет|мир'; ms = -1 },
                    [pscustomobject]@{ ts = '2026-11-19T10:00:05Z'; k = 'tool'; text = 'Bash: npm test'; ms = 75000 },
                    [pscustomobject]@{ ts = 'bad'; k = 'claude'; text = 'Ок'; ms = -1 }) } }
        $f = @(Get-NotifierNotchFeed -Session $s)
        $f.Count | Should -Be 3
        $f[0] | Should -Match '^you\|\d\d:\d\d\|Привет мир$'
        $f[1] | Should -Match 'Bash: npm test · 1 мин 15 с$'
        $f[2] | Should -Be 'claude||Ок'
        @(Get-NotifierNotchFeed -Session ([pscustomobject]@{ session_id = 'x' })).Count | Should -Be 0
    }

    It 'сеанс другого устройства: лента и полный ответ — из событий его хуков' {
        $root = New-Root 'remote'
        $long = ('Первая строка ответа' + "`n`n") + ('x' * 900)
        Add-NotifierRemoteFeed -SessionId 'mac-1' -Kind prompt -Json '{"session_id":"mac-1","prompt":"Почини сборку на маке"}' -Ts '2026-11-19T10:00:00Z' -DataRoot $root
        Add-NotifierRemoteFeed -SessionId 'mac-1' -Kind stop -Json (ConvertTo-Json @{ session_id = 'mac-1'; last_assistant_message = $long } -Compress) -Ts '2026-11-19T10:05:00Z' -DataRoot $root
        Add-NotifierRemoteFeed -SessionId 'mac-1' -Kind prompt -Json '{"session_id":"mac-1","prompt":"Below is a conversation log from a Claude Code coding session"}' -DataRoot $root
        Add-NotifierRemoteFeed -SessionId 'mac-1' -Kind notification -Json '{"message":"x"}' -DataRoot $root
        $r = Get-NotifierRemoteFeed -SessionId 'mac-1' -DataRoot $root
        $r.answer | Should -Be $long
        @($r.feed).Count | Should -Be 2
        $s = [pscustomobject]@{ session_id = 'mac-1'; device = 'dev-mac'; stats = [pscustomobject]@{ feed = @() } }
        $f = @(Get-NotifierNotchFeed -Session $s -DataRoot $root)
        $f.Count | Should -Be 2
        $f[0] | Should -Match '^you\|\d\d:\d\d\|Почини сборку на маке$'
        $f[1] | Should -Match '^claude\|\d\d:\d\d\|Первая строка ответа$'
        Add-NotifierRemoteFeed -SessionId 'mac-1' -Kind sessionend -Json '{}' -DataRoot $root
        (Get-NotifierRemoteFeed -SessionId 'mac-1' -DataRoot $root).answer | Should -Be ''
        Add-NotifierRemoteFeed -SessionId '../evil' -Kind stop -Json '{"last_assistant_message":"x"}' -DataRoot $root
        Test-Path (Join-Path $root 'evil.json') | Should -Be $false   # из id остаются только безопасные символы
        Test-Path (Join-Path (Join-Path $root 'remote') 'evil.json') | Should -Be $true
    }

    It 'файлы на сеанс: пути (с пробелами — в кавычках) уходят командой files' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $script:got = New-Object System.Collections.ArrayList
            $v.add_Command({ param($s, $e) [void]$script:got.Add("$($e.Kind)|$($e.Id)|$($e.Action)") })
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting')))
            $v.DropFiles('a', [string[]]@('C:\a.txt', 'C:\My Docs\b.png'), [System.Drawing.Point]::Empty)
            ($script:got -join ';') | Should -Be 'files|a|C:\a.txt "C:\My Docs\b.png"'
        }
        finally { $f.Dispose() }
    }

    It 'сообщение внизу раскрытой шторки живёт заданное время' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $f.View.Notice('Скопировано', 600)
            $f.View.NoticeText | Should -Be 'Скопировано'
            $f.SetExpanded($true, 'home'); $f.View.Page = 'home'; Invoke-Draw $f
            Start-Sleep -Milliseconds 700
            $f.View.NoticeText | Should -BeNullOrEmpty
        }
        finally { $f.Dispose() }
    }
}

Describe 's_018_05 · уведомления: правила проектов, умная тишина, голос' {
    It 'правило проекта: важные — без «Готово», выключено — ничего; хранится в config.json' {
        $root = New-Root 'rules'
        $script:TrayDataRoot = $root
        Set-NotifierProjectRule -Project 'shop' -Rule important -DataRoot $root
        Set-NotifierProjectRule -Project 'blog' -Rule off -DataRoot $root
        $c = Get-NotifierConfig -DataRoot $root
        Get-NotifierProjectRule -Config $c -Project 'shop' | Should -Be 'important'
        Get-NotifierProjectRule -Config $c -Project 'none' | Should -Be 'all'
        Test-NotifierProjectAllows -Event (New-Ev done shop) -Config $c | Should -Be $false
        Test-NotifierProjectAllows -Event (New-Ev permission shop) -Config $c | Should -Be $true
        Test-NotifierProjectAllows -Event (New-Ev error blog) -Config $c | Should -Be $false
        Test-NotifierProjectAllows -Event (New-Ev done other) -Config $c | Should -Be $true
        Set-NotifierProjectRule -Project 'shop' -Rule all -DataRoot $root
        (Get-NotifierConfig -DataRoot $root).projects.ContainsKey('shop') | Should -Be $false
        '{ "projects": { "x": "loud", "y": "off" }, "voice": { "enabled": true, "idle": 999 } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $c = Get-NotifierConfig -DataRoot $root
        $c.projects.ContainsKey('x') | Should -Be $false
        $c.projects['y'] | Should -Be 'off'
        $c.voice.idle | Should -Be 5
        $c.smartQuiet.enabled | Should -Be $true
    }

    It 'умная тишина: сводка отложенного — самый важный тип, счёт по типам, проекты' {
        $s = New-NotifierHeldSummary -Events @((New-Ev done shop), (New-Ev done blog), (New-Ev permission shop))
        $s.type | Should -Be 'permission'
        $s.title | Should -Match 'событий: 3'
        $s.preview | Should -Match 'запросы: 1'
        $s.preview | Should -Match 'готово: 2'
        $s.preview | Should -Match 'shop, blog'
        New-NotifierHeldSummary -Events @() | Should -BeNullOrEmpty
        [ClaudeNotifier.Win32]::UserNotificationState() -is [int] | Should -Be $true
        Get-NotifierBusyReason -Now ([DateTime]::UtcNow.AddMinutes(5)) -Force | Should -BeIn @('', 'fullscreen', 'presentation', 'call')
        Get-NotifierBusyReason | Should -Be ''   # в тестах экран не проверяется
        [ClaudeNotifier.Win32]::ForegroundFullscreen() -is [bool] | Should -Be $true
    }

    It 'тишина закончилась — одна сводка и очередь пуста' {
        $script:HeldEvents.Clear()
        Add-NotifierHeldEvent -Event (New-Ev done shop)
        Add-NotifierHeldEvent -Event (New-Ev error shop)
        Mock Get-NotifierBusyReason { '' }
        Mock Test-NotifierNotchInline { $false }
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $script:TrayNoOutput = $false
        Invoke-NotifierHeldTick -DataRoot (New-Root 'held')
        Should -Invoke Show-NotifierToast -Times 1 -Exactly -ParameterFilter { $Event.type -eq 'error' -and $Event.summary }
        $script:HeldEvents.Count | Should -Be 0
        Invoke-NotifierHeldTick -DataRoot (New-Root 'held')
        Should -Invoke Show-NotifierToast -Times 1 -Exactly
    }

    It 'голос: фраза по событию; только если включено и вас нет дольше порога' {
        Get-NotifierSpeechText -Event (New-Ev done shop) | Should -Be 'Claude закончил: shop'
        Get-NotifierSpeechText -Event (New-Ev permission '') | Should -Be 'Claude просит разрешения'
        Get-NotifierSpeechText -Event ([pscustomobject]@{ type = 'working' }) | Should -Be ''
        $cfg = Get-NotifierDefaultConfig
        Test-NotifierVoiceDue -Event (New-Ev done shop) -Config $cfg -IdleSeconds 9999 | Should -Be $false
        $cfg.voice.enabled = $true
        Test-NotifierVoiceDue -Event (New-Ev done shop) -Config $cfg -IdleSeconds 60 | Should -Be $false
        Test-NotifierVoiceDue -Event (New-Ev done shop) -Config $cfg -IdleSeconds 600 | Should -Be $true
    }
}

Describe 's_018_05 · маскот: дружба, настроение дня, цвет' {
    It 'уровни дружбы открывают бантик, искры и корону' {
        @([ClaudeNotifier.Ui.MascotStyle]::Unlocked(10)).Count | Should -Be 0
        @([ClaudeNotifier.Ui.MascotStyle]::Unlocked(45)) -join ',' | Should -Be 'bow'
        @([ClaudeNotifier.Ui.MascotStyle]::Unlocked(95)) -join ',' | Should -Be 'bow,sparks,crown'
    }

    It 'цвет: «как есть» не меняет, сдвиг оттенка меняет, ч/б — серый' {
        $c = [System.Drawing.Color]::FromArgb(255, 200, 80, 40)
        $n = [ClaudeNotifier.Ui.MascotColor]::Apply($c, 'none')
        "$($n.R),$($n.G),$($n.B)" | Should -Be '200,80,40'
        $h = [ClaudeNotifier.Ui.MascotColor]::Apply($c, 'h120')
        ($h.G -gt $h.R) | Should -Be $true
        $m = [ClaudeNotifier.Ui.MascotColor]::Apply($c, 'mono')
        ([Math]::Abs($m.R - $m.G) -le 1 -and [Math]::Abs($m.G - $m.B) -le 1) | Should -Be $true
        [ClaudeNotifier.Ui.MascotColor]::Mode = 'bogus'
        [ClaudeNotifier.Ui.MascotColor]::Mode | Should -Be 'none'
    }

    It 'главный маскот с короной, колпачком, чаем и своим цветом рисуется' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $f.View.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting')))
            [ClaudeNotifier.Ui.NotchView]::Affection = 95
            foreach ($mood in @('cheer', 'tea', '')) { [ClaudeNotifier.Ui.NotchView]::DayMood = $mood; Invoke-Draw $f }
            [ClaudeNotifier.Ui.MascotColor]::Mode = 'h180'
            $f.SetExpanded($true, 'home'); Invoke-Draw $f
        }
        finally { $f.Dispose(); [ClaudeNotifier.Ui.MascotColor]::Mode = 'none'; [ClaudeNotifier.Ui.NotchView]::DayMood = ''; [ClaudeNotifier.Ui.NotchView]::Affection = 0 }
    }

    It 'настроение дня по истории: много ошибок — чай; вечером много «Готово» — праздник' {
        $root = New-Root 'mood'
        $now = [DateTime]::Today.AddHours(19)
        foreach ($i in 1..3) { [void](Add-NotifierHistory -Event (New-Ev error p $now.AddMinutes(-$i)) -DataRoot $root) }
        Get-NotifierDayMood -Now $now -DataRoot $root -Force | Should -Be 'tea'
        $root2 = New-Root 'mood2'
        foreach ($i in 1..5) { [void](Add-NotifierHistory -Event (New-Ev done p $now.AddMinutes(-$i)) -DataRoot $root2) }
        Get-NotifierDayMood -Now $now -DataRoot $root2 -Force | Should -Be 'cheer'
        Get-NotifierDayMood -Now $now.Date.AddHours(12) -DataRoot $root2 -Force | Should -Be ''
    }
}

Describe 's_018_05 · статистика недели' {
    It 'задачи по дням и самые долгие задачи из истории' {
        $root = New-Root 'week'
        $today = [DateTime]::Today.AddHours(12)
        [void](Add-NotifierHistory -Event (New-Ev done shop $today -Extra @{ taskSeconds = 1800 }) -DataRoot $root)
        [void](Add-NotifierHistory -Event (New-Ev done blog $today.AddDays(-1) -Extra @{ taskSeconds = 300 }) -DataRoot $root)
        [void](Add-NotifierHistory -Event (New-Ev done api $today.AddDays(-1) -Extra @{ taskSeconds = 30 }) -DataRoot $root)
        [void](Add-NotifierHistory -Event (New-Ev error api $today) -DataRoot $root)
        $dates = @(6..0 | ForEach-Object { $today.Date.AddDays(-$_).ToString('yyyy-MM-dd') })
        $w = Get-NotifierWeekTasks -Dates $dates -DataRoot $root
        $w.Counts[6] | Should -Be 1
        $w.Counts[5] | Should -Be 2
        @($w.Longest | ForEach-Object { $_.Title }) -join ',' | Should -Be 'shop,blog'
        $w.Longest[0].Sid | Should -Be 's-shop'
    }

    It 'длительность задачи: от начала работы сеанса до «Готово»' {
        $start = [DateTime]::UtcNow.AddMinutes(-10)
        $s = [pscustomobject]@{ state = 'working'; since = $start.ToString('o') }
        $e = [pscustomobject]@{ type = 'done'; ts = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
        $sec = Get-NotifierTaskSeconds -Session $s -Event $e
        ($sec -ge 595 -and $sec -le 605) | Should -Be $true
        Get-NotifierTaskSeconds -Session $null -Event $e | Should -Be 0
    }

    It 'график недели: подписи по формату, сегодня выделено' {
        $r = New-NotifierWeekChart -Values ([double[]]@(0, 1.5, 0.25)) -Labels ([string[]]@('Пн', 'Вт', 'Сегодня')) -Format { param($v) if ($v -le 0) { '' } else { "$v ч" } }
        $r.Kind | Should -Be 'chart'
        ($r.ValueLabels -join '|') | Should -Be '|1.5 ч|0.25 ч'
        $r.Highlight | Should -Be 2
    }
}

Describe 's_018_05 · обновление из шторки и самопроверка' {
    It 'что нового: из коммитов (новые сверху) и из описания выпуска' {
        $json = '{"status":"ahead","ahead_by":2,"commits":[{"sha":"' + ('a' * 40) + '","commit":{"message":"feat: первое\n\nтело"}},{"sha":"' + ('b' * 40) + '","commit":{"message":"fix: второе"}}]}'
        $r = ConvertFrom-NotifierCompare -Json $json
        ($r.Notes -join '|') | Should -Be 'fix: второе|feat: первое'
        $rel = '{"tag_name":"v1.2","name":"","body":"## Что нового\n- Шторка быстрее\n* Новые маскоты\ncommit: ' + ('c' * 40) + '","assets":[{"browser_download_url":"https://github.com/o/r/releases/download/v1.2/a.zip"},{"browser_download_url":"https://github.com/o/r/releases/download/v1.2/a.zip.sha256"}]}'
        $x = ConvertFrom-NotifierRelease -Json $rel -Repo 'o/r'
        ($x.Notes -join '|') | Should -Be 'Что нового|Шторка быстрее|Новые маскоты'
    }

    It 'страница «Обновление»: кнопка «Обновить сейчас» и список изменений; без обновления — пояснение' {
        $rows = @(Get-NotifierNotchUpdateRows -Info @{ Count = 2; Message = 'x'; Notes = @('a', 'b'); Sha = ('a' * 40) })
        @($rows | Where-Object Kind -eq 'button' | ForEach-Object Key) -join ',' | Should -Be 'update-now'
        @($rows | Where-Object Kind -eq 'info' | ForEach-Object Title) -join ',' | Should -Be 'a,b'
        $none = @(Get-NotifierNotchUpdateRows -Info $null)
        $none[0].Kind | Should -Be 'note'
    }

    It 'самопроверка при запуске: неполадки — одно сообщение, один раз' {
        Mock Get-NotifierDiagnostics { @(@{ Level = 'error'; Title = 'Приём событий'; Detail = 'порт занят' }, @{ Level = 'warn'; Title = 'Автозапуск'; Detail = 'x' }) }
        Mock Test-NotifierNotchActive { $false }
        Mock Show-NotifierToast { $true }
        $script:TrayNoOutput = $false
        $script:StartupCheckDone = $false; $script:StartupCheckAt = [DateTime]::UtcNow.AddSeconds(-1)
        Invoke-NotifierStartupCheck
        Invoke-NotifierStartupCheck
        Should -Invoke Show-NotifierToast -Times 1 -Exactly -ParameterFilter { $Event.preview -match 'Приём событий' -and $Event.preview -notmatch 'Автозапуск' }
    }
}

Describe 's_018_05 · быстрый мост хуков' {
    It 'с exe — SessionStart и PermissionRequest через него, остальное как было; хуки узнаются и удаляются' {
        $app = Join-Path $TestDrive 'claude-notifier\app'
        New-Item -ItemType Directory $app -Force | Out-Null
        $exe = Join-Path $app 'claude-notifier-hook.exe'; Set-Content $exe 'x'
        $s = [pscustomobject]@{}
        Add-NotifierHooks -Settings $s -AppRoot $app -Port 47611 -Secret 'abc' -HookExe $exe
        $ss = @($s.hooks.SessionStart)[0].hooks[0]
        $ss.command | Should -Be $exe
        ($ss.args -join ' ') | Should -Match '^sessionstart --bridge .*hook-bridge\.ps1 --port 47611 --secret abc$'
        @($s.hooks.PermissionRequest)[0].hooks[0].command | Should -Be $exe
        @($s.hooks.Stop | ForEach-Object { $_.hooks[0].command }) -contains $exe | Should -Be $false
        Test-NotifierHook $ss | Should -Be $true
        (Remove-NotifierHooks -Settings $s) | Should -Be 8
        $s3 = [pscustomobject]@{}
        Add-NotifierHooks -Settings $s3 -AppRoot $app -Port 47611 -Secret 'abc' -HookExe ''
        @($s3.hooks.SessionStart)[0].hooks[0].command | Should -Match 'powershell\.exe$'
    }

    It 'Smart App Control включён — exe не собирается, хуки на PowerShell' {
        $app = New-Root 'app-sac'
        New-Item -ItemType Directory (Join-Path $app 'hookexe') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'src\hookexe\HookExe.cs') (Join-Path $app 'hookexe')
        New-NotifierHookExe -AppRoot $app -SmartAppControl 1 6>$null | Should -Be ''
        Test-Path (Join-Path $app 'claude-notifier-hook.exe') | Should -Be $false
    }

    It 'без Smart App Control: exe собирается, проходит самопроверку и сразу отвечает на запрос без ожидания' {
        if ((Get-NotifierSmartAppControlState) -in @(1, 2)) { Set-ItResult -Skipped -Because 'Smart App Control на этом ПК не даёт запускать свежесобранные программы'; return }
        $app = New-Root 'app-ok'
        New-Item -ItemType Directory (Join-Path $app 'hookexe') -Force | Out-Null
        Copy-Item (Join-Path $repoRoot 'src\hookexe\HookExe.cs') (Join-Path $app 'hookexe')
        $exe = New-NotifierHookExe -AppRoot $app -SmartAppControl 0
        $exe | Should -Be (Join-Path $app 'claude-notifier-hook.exe')
        $env:CLAUDE_NOTIFIER_HOME = New-Root 'home-ok'
        try {
            $sw = [Diagnostics.Stopwatch]::StartNew()
            $out = '{"session_id":"x","tool_name":"Bash"}' | & $exe permreq --bridge (Join-Path $app 'missing.ps1') --port 1 --secret x
            $sw.Stop()
            $LASTEXITCODE | Should -Be 0
            "$out" | Should -Be ''
            Write-Host "      hook exe permreq ms: $($sw.ElapsedMilliseconds)"
        }
        finally { Remove-Item Env:\CLAUDE_NOTIFIER_HOME }
    }
}
