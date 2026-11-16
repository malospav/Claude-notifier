$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Sessions.psm1') -Force
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

Describe 's_008_01 · окно сеансов: карточки' {
    It 'карточки: порядок, статус, где идёт, сколько, превью; подзаголовок' {
        $cards = New-Object ClaudeNotifier.Ui.CardList
        $sessions = @(
            [pscustomobject]@{ session_id = 'a'; project = 'alpha'; origin = 'desktop'; state = 'working'; since = '2026-11-16T11:55:00Z'; updated = '2026-11-16T11:55:00Z'; preview = '' },
            [pscustomobject]@{ session_id = 'b'; project = ''; origin = 'cli'; state = 'permission'; since = '2026-11-16T11:59:30Z'; updated = '2026-11-16T11:59:30Z'; preview = 'p' }
        )
        $text = Update-NotifierSessionsView -Cards $cards -Sessions $sessions -Now ([datetime]::Parse('2026-11-16T12:00:00Z').ToUniversalTime())
        $cards.Count | Should Be 2
        $cards[0].Title | Should Be 'Без проекта'
        $cards[0].State | Should Be 'permission'
        $cards[0].StateText | Should Be 'Нужно разрешение'
        $cards[0].Meta | Should Be 'Терминал'
        $cards[0].Preview | Should Be 'p'
        $cards[1].Title | Should Be 'alpha'
        $cards[1].Right | Should Be '5 мин'
        $cards[1].Meta | Should Be 'Приложение'
        $text | Should Be "2 активных $([char]0x00B7) требуют внимания: 1"
        Update-NotifierSessionsView -Cards $cards -Sessions @() | Should Be 'Нет активных сеансов'
        Format-NotifierSessionsSubtitle -Sessions @([pscustomobject]@{ state = 'waiting' }) | Should Be '1 активный'
        $cards.Dispose()
    }

    It 'выделение сохраняется после обновления; клавиши и колесо не падают' {
        $cards = New-Object ClaudeNotifier.Ui.CardList
        $cards.Size = New-Object System.Drawing.Size(400, 120)
        $mk = { param($id) $c = New-Object ClaudeNotifier.Ui.CardItem; $c.Id = $id; $c.Title = $id; $c.State = 'waiting'; $c }
        $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
        foreach ($id in 'a', 'b', 'c', 'd') { $list.Add((& $mk $id)) }
        $cards.SetItems($list)
        $cards.Select(2)
        $cards.SelectedItem.Id | Should Be 'c'
        $list2 = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
        foreach ($id in 'x', 'c') { $list2.Add((& $mk $id)) }
        $cards.SetItems($list2)
        $cards.SelectedItem.Id | Should Be 'c'
        $script:actions = @()
        $cards.add_ItemAction({ param($s, $e) $script:actions += $e.Action })
        $bmp = New-Object System.Drawing.Bitmap 400, 120
        $cards.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 400, 120)))
        $bmp.Dispose()
        $cards.Dispose()
    }

    It 'окно: заголовок, вкладки, карточки, меню карточки' {
        $f = New-NotifierSessionsForm
        try {
            $f.Text | Should Be 'Claude Notifier'
            $f.Tag.Title.Text | Should Be 'Сеансы'
            $f.Tag.Cards.EmptyTitle | Should Be 'Активных сеансов нет'
            $f.Tag.Menu.Items.Count | Should Be 2
        }
        finally { $f.Dispose() }
    }

    It 'действия с карточкой: Del убирает сеанс, переход без окна — подсказка под заголовком' {
        $root = Join-Path $TestDrive 'selected'
        $script:TrayDataRoot = $root
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 'a'; project = 'alpha'; state = 'waiting'; since = ''; updated = [DateTime]::UtcNow.ToString('o'); preview = ''; window = $null },
            [pscustomobject]@{ session_id = 'b'; project = 'beta'; state = 'working'; since = ''; updated = [DateTime]::UtcNow.ToString('o'); preview = ''; window = $null }
        ) -DataRoot $root
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            [void](Invoke-NotifierSessionsRefresh)
            $cards = $script:SessionsForm.Tag.Cards
            $cards.Count | Should Be 2
            Invoke-NotifierSelectedSession -Action remove   # ничего не выделено → ничего не происходит
            @(Get-NotifierSessions -DataRoot $root).Count | Should Be 2
            $cards.Select(0)
            Invoke-NotifierSelectedSession -Action focus
            $script:SessionsForm.Tag.Subtitle.Text | Should Be 'Окно этого сеанса не определено'
            Invoke-NotifierSelectedSession -Action remove
            $left = @(Get-NotifierSessions -DataRoot $root)
            $left.Count | Should Be 1
            $left[0].session_id | Should Be 'b'
            $cards.Count | Should Be 1
            $script:NoticeUntil = [datetime]::MinValue
            [void](Invoke-NotifierSessionsRefresh)
            $script:SessionsForm.Tag.Subtitle.Text | Should Be '1 активный'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}

Describe 's_008_01 · обновление и переход к окну' {
    It 'обновление убирает мёртвые сеансы из файла' {
        $root = Join-Path $TestDrive 'refresh'
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 'live'; updated = [DateTime]::UtcNow.ToString('o'); window = $null },
            [pscustomobject]@{ session_id = 'dead'; updated = [DateTime]::UtcNow.ToString('o'); window = [pscustomobject]@{ hwnd = 0; pid = 999999 } }
        ) -DataRoot $root
        $live = Invoke-NotifierSessionsRefresh -DataRoot $root
        @($live).Count | Should Be 1
        @(Get-NotifierSessions -DataRoot $root).Count | Should Be 1
    }

    It 'переход к окну: нет hwnd → unknown; окно закрыто → сеанс убирается' {
        $root = Join-Path $TestDrive 'focus'
        $s = [pscustomobject]@{ session_id = 'z'; updated = [DateTime]::UtcNow.ToString('o'); window = [pscustomobject]@{ hwnd = 555; pid = 0 } }
        Save-NotifierSessions -Sessions @($s) -DataRoot $root
        Invoke-NotifierSessionFocus -Session ([pscustomobject]@{ session_id = 'z'; window = $null }) -DataRoot $root | Should Be 'unknown'
        Mock Set-SessionWindowFocus { 'closed' }
        Invoke-NotifierSessionFocus -Session $s -DataRoot $root | Should Be 'closed'
        @(Get-NotifierSessions -DataRoot $root).Count | Should Be 0
    }

    It 'Test-SessionsRefreshDue' {
        $t = [datetime]'2026-11-16T12:00:00'
        Test-SessionsRefreshDue -Dirty $true -LastRefresh $t -Now $t | Should Be $true
        Test-SessionsRefreshDue -Dirty $false -LastRefresh $t -Now $t.AddSeconds(1) | Should Be $false
        Test-SessionsRefreshDue -Dirty $false -LastRefresh $t -Now $t.AddSeconds(6) | Should Be $true
    }
}

Describe 's_008_01 · точка статуса в трее' {
    It 'общий статус: разрешение > ошибка > работает > ждёт > нет' {
        function S([string[]]$States) { @($States | ForEach-Object { [pscustomobject]@{ state = $_ } }) }
        Get-NotifierTrayState -Sessions (S 'waiting', 'working', 'permission', 'error') | Should Be 'permission'
        Get-NotifierTrayState -Sessions (S 'waiting', 'error', 'working') | Should Be 'error'
        Get-NotifierTrayState -Sessions (S 'waiting', 'working') | Should Be 'working'
        Get-NotifierTrayState -Sessions (S 'waiting') | Should Be 'waiting'
        Get-NotifierTrayState -Sessions @() | Should Be 'none'
    }

    It 'подсказка: числа по статусам, не длиннее 63 символов' {
        $s = @('permission', 'working', 'working', 'waiting') | ForEach-Object { [pscustomobject]@{ state = $_ } }
        $tip = Format-NotifierTrayTooltip -Sessions $s
        $dot = [char]0x00B7
        $tip | Should Be "Claude $dot 1 ждёт разрешения $dot 2 работает $dot 1 ждёт ответа"
        $tip.Length | Should BeLessThan 64
        Format-NotifierTrayTooltip -Sessions @() | Should Be "Claude $dot сеансов нет"
        $many = 1..30 | ForEach-Object { [pscustomobject]@{ state = @('permission', 'error', 'working', 'waiting')[$_ % 4] } }
        (Format-NotifierTrayTooltip -Sessions $many).Length | Should BeLessThan 64
    }

    It 'точка <State>: цвет в центре, прозрачный угол' -TestCases @(
        @{ State = 'permission'; Rgb = '255,159,10' },
        @{ State = 'error'; Rgb = '255,69,58' },
        @{ State = 'working'; Rgb = '10,132,255' },
        @{ State = 'waiting'; Rgb = '48,209,88' }
    ) {
        param($State, $Rgb)
        $bmp = [ClaudeNotifier.Ui.TrayDot]::Render($State, 32)
        try {
            $c = $bmp.GetPixel(16, 16)
            ('{0},{1},{2}' -f $c.R, $c.G, $c.B) | Should Be $Rgb
            $c.A | Should Be 255
            $bmp.GetPixel(0, 0).A | Should Be 0
        }
        finally { $bmp.Dispose() }
    }

    It '«нет сеансов»: пустое кольцо, центр прозрачный' {
        $bmp = [ClaudeNotifier.Ui.TrayDot]::Render('none', 32)
        try { $bmp.GetPixel(16, 16).A | Should Be 0 } finally { $bmp.Dispose() }
    }

    It 'иконка трея меняется со статусом; иконки кэшируются' {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        try {
            $script:TrayStateShown = $null
            Update-NotifierTrayStatus -Icon $icon -Sessions @([pscustomobject]@{ state = 'working' }) | Should Be 'working'
            [object]::ReferenceEquals($icon.Icon, (Get-NotifierDotIcon 'working')) | Should Be $true
            $icon.Text | Should Match 'работает'
            Update-NotifierTrayStatus -Icon $icon -Sessions @() | Should Be 'none'
            [object]::ReferenceEquals($icon.Icon, (Get-NotifierDotIcon 'none')) | Should Be $true
        }
        finally { $icon.Dispose() }
    }
}

Describe 's_008_01 · диалог' {
    It 'поле ввода возвращает текст, OK → Ok' {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.add_Tick({
                $this.Stop()
                $f = @([System.Windows.Forms.Application]::OpenForms)[-1]
                $box = $f.Tag.Box
                $box.Text = 'Новое имя'
                $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            })
        $timer.Start()
        try { $r = Show-NotifierDialog -Title 'Переименовать' -Message 'Текст' -InputValue 'Старое' }
        finally { $timer.Dispose() }
        $r.Ok | Should Be $true
        $r.Value | Should Be 'Новое имя'
    }

    It 'отмена → Ok = $false' {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.add_Tick({ $this.Stop(); @([System.Windows.Forms.Application]::OpenForms)[-1].DialogResult = [System.Windows.Forms.DialogResult]::Cancel })
        $timer.Start()
        try { $r = Show-NotifierDialog -Title 'Отключить?' -Message 'Текст' -Primary 'Отключить' }
        finally { $timer.Dispose() }
        $r.Ok | Should Be $false
        $r.Value | Should Be $null
    }
}

Describe 's_008_01 · элементы в стиле Apple' {
    It 'ease-out cubic-bezier(0.23, 1, 0.32, 1): 0 → 0, 1 → 1, быстрый старт, монотонно' {
        [ClaudeNotifier.Ui.Motion]::EaseOut(0) | Should Be 0
        [ClaudeNotifier.Ui.Motion]::EaseOut(1) | Should Be 1
        [ClaudeNotifier.Ui.Motion]::EaseOut(0.25) | Should BeGreaterThan 0.6
        $prev = 0
        foreach ($x in 1..20) { $v = [ClaudeNotifier.Ui.Motion]::EaseOut($x / 20); $v | Should Not BeLessThan $prev; $prev = $v }
    }

    It 'анимация выключена в Windows → значение меняется сразу' {
        [ClaudeNotifier.Ui.Motion]::Force($false)
        try {
            $tw = New-Object ClaudeNotifier.Ui.Tween 0
            $tw.Animate(1, 200)
            $tw.Value | Should Be 1
            $tw.Dispose()
        }
        finally { [ClaudeNotifier.Ui.Motion]::Force($null) }
    }

    It 'анимация прерывается и продолжается с текущего значения' {
        [ClaudeNotifier.Ui.Motion]::Force($true)
        try {
            $tw = New-Object ClaudeNotifier.Ui.Tween 0
            $tw.Animate(1, 400)
            $sw = [Diagnostics.Stopwatch]::StartNew()
            while ($sw.ElapsedMilliseconds -lt 120) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            $mid = $tw.Value
            $mid | Should BeGreaterThan 0
            $mid | Should BeLessThan 1
            $tw.Animate(0, 200)   # разворот — с текущего места, без скачка
            [System.Windows.Forms.Application]::DoEvents()
            $tw.Value | Should Not BeGreaterThan ($mid + 0.05)
            $tw.Target | Should Be 0
            $tw.Dispose()
        }
        finally { [ClaudeNotifier.Ui.Motion]::Force($null) }
    }

    It 'тумблер: Toggle меняет состояние и вызывает событие; SetChecked — без события' {
        [ClaudeNotifier.Ui.Motion]::Force($false)
        try {
            $sw = New-Object ClaudeNotifier.Ui.Switch
            $script:changes = 0
            $sw.add_CheckedChanged({ $script:changes++ })
            $sw.Toggle()
            $sw.Checked | Should Be $true
            $script:changes | Should Be 1
            $sw.SetChecked($false)
            $sw.Checked | Should Be $false
            $script:changes | Should Be 1
            $sw.Dispose()
        }
        finally { [ClaudeNotifier.Ui.Motion]::Force($null) }
    }

    It 'сегменты: выбор меняет индекс и вызывает событие один раз' {
        $tabs = New-Object ClaudeNotifier.Ui.Tabs
        $tabs.SetTitles('Сеансы', 'Устройства')
        $script:tabChanges = 0
        $tabs.add_SelectedIndexChanged({ $script:tabChanges++ })
        $tabs.SelectedIndex = 1
        $tabs.SelectedIndex = 1
        $tabs.SelectedIndex = 5
        $tabs.SelectedIndex | Should Be 1
        $script:tabChanges | Should Be 1
        $tabs.Dispose()
    }

    It 'список: группы по устройствам — сначала группа с самым срочным сеансом' {
        $script:Net = $null
        $cards = New-Object ClaudeNotifier.Ui.CardList
        $now = [DateTime]::UtcNow.ToString('o')
        [void](Update-NotifierSessionsView -Cards $cards -Sessions @(
            [pscustomobject]@{ session_id = 'l1'; project = 'a'; device = ''; state = 'working'; since = $now; updated = $now; preview = '' },
            [pscustomobject]@{ session_id = 'r1'; project = 'b'; device = 'dX'; state = 'permission'; since = $now; updated = $now; preview = '' },
            [pscustomobject]@{ session_id = 'l2'; project = 'c'; device = ''; state = 'waiting'; since = $now; updated = $now; preview = '' }
        ))
        (0..2 | ForEach-Object { $cards[$_].Id }) -join ',' | Should Be 'r1,l2,l1'
        $cards[0].Section | Should Be 'Отключено'
        $cards[1].Section | Should Be 'Этот ПК'
        $cards.Dispose()
    }

    It 'ячейки кода и подписи рисуются без ошибок' {
        $t = Get-NotifierTheme
        $pin = New-Object ClaudeNotifier.Ui.PinView
        $pin.ApplyTheme($t); $pin.Width = 300; $pin.Text = '123 456'
        $bmp = New-Object System.Drawing.Bitmap 300, $pin.Height
        $pin.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 300, $pin.Height)))
        $bmp.Dispose(); $pin.Dispose()
        $l = New-NotifierLabel -Theme $t -Text 'Ожидаю' -Dot 'none' -Width 200
        $l.Center = $true
        $bmp = New-Object System.Drawing.Bitmap 200, $l.Height
        $l.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 200, $l.Height)))
        $bmp.Dispose(); $l.Dispose()
    }
}

Describe 's_008_01 · кэш сборки интерфейса' {
    It 'новый процесс: сборка компилируется в кэш, старые версии удаляются, ничего не ждёт ввода' {
        $cache = Join-Path $TestDrive 'uicache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $cache 'ClaudeNotifier.Ui.0000000000000000.dll'), 'old')
        $module = Join-Path $repoRoot 'src\lib\Ui.psm1'
        $p = Start-Process -FilePath powershell -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', "Import-Module '$module'; exit ([int]((Import-NotifierUi -CacheDir '$cache') -ne 'compiled'))") -PassThru -WindowStyle Hidden
        [void]$p.Handle
        $p.WaitForExit(90000) | Should Be $true
        $p.ExitCode | Should Be 0
        $names = @(Get-ChildItem $cache -Filter 'ClaudeNotifier.Ui.*.dll' | ForEach-Object { $_.Name })
        $names.Count | Should Be 1
        $names[0] | Should Not Be 'ClaudeNotifier.Ui.0000000000000000.dll'
    }
}
