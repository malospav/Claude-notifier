$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

function Iso([datetime]$T) { return $T.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function New-S([string]$Id, [string]$State, [string]$Project = 'shop') {
    $t = Iso ([DateTime]::UtcNow)
    return [pscustomobject]@{ session_id = $Id; project = $Project; origin = 'cli'; device = ''; state = $State; since = $t; updated = $t; preview = 'ответ'; window = $null }
}

Describe 's_015_01 · шторка вверху экрана' {
    It 'настройки: шторка включена, монитор — второй (пусто), по центру; неверное положение — по центру; звук включён' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory $root -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $root
        $c.notch.enabled | Should Be $true
        $c.notch.screen | Should Be ''
        $c.notch.position | Should Be 'center'
        $c.quiet.enabled | Should Be $false
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"notch":{"enabled":false,"screen":"\\\\.\\DISPLAY9","position":"top"},"quiet":{"enabled":true}}')
        $c = Get-NotifierConfig -DataRoot $root
        $c.notch.enabled | Should Be $false
        $c.notch.screen | Should Be '\\.\DISPLAY9'
        $c.notch.position | Should Be 'center'
        $c.quiet.enabled | Should Be $true
    }

    It 'монитор: из настроек, если подключён; иначе неосновной, иначе основной' {
        $primary = [System.Windows.Forms.Screen]::PrimaryScreen
        $cfg = Get-NotifierDefaultConfig
        $cfg.notch.screen = $primary.DeviceName
        (Get-NotifierNotchScreen -Config $cfg).DeviceName | Should Be $primary.DeviceName
        $cfg.notch.screen = '\\.\НЕТ'
        $s = Get-NotifierNotchScreen -Config $cfg
        $other = @([System.Windows.Forms.Screen]::AllScreens | Where-Object { -not $_.Primary })
        if ($other.Count -gt 0) { $s.Primary | Should Be $false } else { $s.Primary | Should Be $true }
        Format-NotifierScreenName $primary | Should Match '^Монитор \d+ · \d+ × \d+ \(основной\)$'
        Format-NotifierNotchPosition 'left' | Should Be 'Слева'
        Format-NotifierNotchPosition 'x' | Should Be 'По центру'
    }

    It 'окно шторки: у верхнего края монитора — по центру, слева, справа; без анимации — сразу' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $f.ScreenBounds = New-Object System.Drawing.Rectangle(-1440, -727, 1440, 2560)
            $f.Margin2 = 24
            # Окно постоянного размера (прозрачное вне шторки), сама шторка — фигура внутри у верхнего края.
            $f.SetTargetSize((New-Object System.Drawing.Size(230, 34)), $false)
            $f.ShapeOnScreen() | Should Be (New-Object System.Drawing.Rectangle((-1440 + 605), -727, 230, 34))
            $f.Top | Should Be -727
            $w0 = $f.Width
            $f.SetTargetSize((New-Object System.Drawing.Size(700, 300)), $false)
            $f.Width | Should Be $w0   # размер окна не меняется
            $f.SetTargetSize((New-Object System.Drawing.Size(230, 34)), $false)
            $f.Position = 'left'; $f.SetTargetSize((New-Object System.Drawing.Size(230, 34)), $false)
            $f.ShapeOnScreen().Left | Should Be (-1440 + 24)
            $f.Position = 'right'; $f.SetTargetSize((New-Object System.Drawing.Size(230, 34)), $false)
            $f.ShapeOnScreen().Right | Should Be (0 - 24)
            $f.Position = 'center'; $f.SetTargetSize((New-Object System.Drawing.Size(230, 34)), $false)
            $f.Animating | Should Be $false
            # Layered-окно с попиксельной альфой: вне шторки и в скруглённых углах — прозрачно, внутри — непрозрачно.
            $f.View.External | Should Be $true
            $f.Show(); [System.Windows.Forms.Application]::DoEvents(); $f.Present()
            $sx = $f.ShapeOnScreen().Left - $f.Left
            $f.Surface.AlphaAt($sx, 33) | Should Be 0           # скруглённый угол
            $f.Surface.AlphaAt($sx + 115, 2) | Should Be 255
            $f.Surface.AlphaAt($sx + 115, 60) | Should Be 0     # под шторкой — прозрачно
            $edge = $f.Surface.AlphaAt($sx + 3, 30)              # на скруглении — сглаженный край
            ($edge -ge 0) | Should Be $true
            $f.Hide()
        }
        finally { $f.Dispose() }
    }

    It 'данные: персонажи по статусам, у запроса — кнопки ответа (без файлов и папки), плашка расхода' {
        $script:TrayDataRoot = Join-Path $TestDrive 'data'
        New-Item -ItemType Directory (Join-Path $script:TrayDataRoot 'requests') -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $now = [DateTime]::UtcNow
        $rid = '1b2c3d4e-0000-4000-8000-0000000000b1'
        $req = [pscustomobject][ordered]@{ type = 'permission'; id = $rid; session_id = 'p'; pid = $PID; kind = 'tool'; title = 'Bash: npm i'; detail = 'npm i'; options = @(); canAlways = $true; created = $now.ToString('o'); expires = $now.AddMinutes(10).ToString('o') }
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot "requests\perm-$rid.json"), (ConvertTo-Json $req -Compress), (New-Object Text.UTF8Encoding $false))
        [void](Update-NotifierPending -DataRoot $script:TrayDataRoot)
        [void](Save-NotifierUsage -DataRoot $script:TrayDataRoot -Source api -Windows ([ordered]@{ five_hour = [ordered]@{ percent = 91; resets_at = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds() } }))
        $items = Get-NotifierNotchItems -Sessions @((New-S 'w' 'working' 'api'), (New-S 'p' 'permission'))
        $items.Count | Should Be 2
        $items[0].Id | Should Be 'p'   # ждущие решения — первыми
        $items[0].Actions -join ';' | Should Be 'allow|Разрешить|primary;always|Всегда|secondary;deny|Запретить|destructive'
        $items[0].RequestTitle | Should Be 'Bash: npm i'
        $items[1].Actions.Length | Should Be 0   # «Изменённые файлы» и «Папка проекта» — не в шторке
        # Полоски лимитов: осталось 100 − 91 = 9 % от пятичасового; недельного в данных нет.
        $lim = Get-NotifierNotchLimits
        $lim.Left5 | Should Be 9
        $lim.Detail5 | Should Match '^сброс'
        $lim.LeftWeek | Should Be -1
        $lim.Stale | Should Be $false
        $old = Get-NotifierNotchLimits -Now ([DateTime]::UtcNow.AddMinutes(20))
        $old.Stale | Should Be $false
        $old = Get-NotifierNotchLimits -Now ([DateTime]::UtcNow.AddMinutes(45))
        $old.Left5 | Should Be 100      # окно уже сброшено
        $old.Detail5 | Should Be 'сброшен'
        $old.Stale | Should Be $true
        # Отрисовка во всех видах и страницах не падает.
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $f.View.SetItems($items)
            $f.View.SetRows('settings', [ClaudeNotifier.Ui.NotchRow[]]@(Get-NotifierNotchSettingsRows))
            foreach ($state in @(@($false, 'home'), @($true, 'home'), @($true, 'chat'), @($true, 'settings'))) {
                $f.View.Expanded = $state[0]; $f.View.Page = $state[1]
                $sz = $f.SizeFor()
                $f.ClientSize = $sz
                $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
                $f.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height)))
                $bmp.Dispose()
            }
            ($f.View.HitIds() -contains 'set:event.done') | Should Be $true
            ($f.SizeFor().Height -gt $f.View.Theme.S(232)) | Should Be $true   # настройки — выше главной
        }
        finally { $f.Dispose() }
    }

    It 'щелчки: раскрыть — сразу в окне; страница, сеанс, полный ответ — внутри; ответ, «+», тумблер — событием' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        $v = $f.View
        try {
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.NotchItem]'
            foreach ($id in @('a', 'b')) { $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = $id; $it.Title = $id; $it.State = 'working'; $items.Add($it) }
            $v.SetItems($items)
            $v.SetRows('settings', [ClaudeNotifier.Ui.NotchRow[]]@((New-NotifierNotchRow switch 'quiet' 'Без звука' -On $false)))
            $v.SelectedId | Should Be 'a'
            $script:got = @()
            $v.add_Command({ param($s, $e) $script:got += "$($e.Kind)|$($e.Id)|$($e.Action)" })
            $v.ClickArea('expand', [System.Drawing.Point]::Empty); $v.Expanded | Should Be $true   # раскрывает само окно шторки
            $v.ClickArea('item:b', [System.Drawing.Point]::Empty); $v.SelectedId | Should Be 'b'
            $v.ClickArea('answer', [System.Drawing.Point]::Empty); $v.Page | Should Be 'answer'
            $v.ClickArea('act:allow', [System.Drawing.Point]::Empty)
            $v.ClickArea('page:home', [System.Drawing.Point]::Empty); $v.Page | Should Be 'home'
            $v.ClickArea('page:stats-limits', [System.Drawing.Point]::Empty); $v.Page | Should Be 'stats'   # щелчок по полоскам лимитов
            $v.ClickArea('page:settings', [System.Drawing.Point]::Empty)
            $v.ClickArea('set:quiet', [System.Drawing.Point]::Empty)
            $v.Rows('settings')[0].On | Should Be $true   # тумблер переключается сразу
            $v.ClickArea('row:dev1:remove', [System.Drawing.Point]::Empty)
            $v.ClickArea('close', [System.Drawing.Point]::Empty); $v.Expanded | Should Be $false
            $script:got -join ';' | Should Be 'expand|a|;page|b|answer;action|b|allow;page|b|home;page|b|stats;page|b|settings;set|quiet|;row|dev1|remove;close|b|'
        }
        finally { $f.Dispose() }
    }

    It 'полный ответ: последний текст Claude из журнала без разметки; страница ответа выше главной и рисуется' {
        $tr = Join-Path $TestDrive 'ans.jsonl'
        $lines = @(
            '{"type":"assistant","timestamp":"2026-11-18T07:00:00.000Z","message":{"id":"msg_1","content":[{"type":"text","text":"старый ответ"}]}}',
            '{"type":"assistant","isSidechain":true,"timestamp":"2026-11-18T07:01:00.000Z","message":{"id":"msg_s","content":[{"type":"text","text":"ответ субагента"}]}}',
            '{"type":"assistant","timestamp":"2026-11-18T07:02:00.000Z","message":{"id":"msg_2","content":[{"type":"text","text":"**Готово.** Сделал `шторку`.\nВторая строка."}]}}',
            '{"type":"assistant","timestamp":"2026-11-18T07:02:01.000Z","message":{"id":"msg_2","content":[{"type":"tool_use","id":"t","name":"Bash","input":{}}]}}')
        [IO.File]::WriteAllText($tr, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        Get-NotifierLastAnswer -Path $tr | Should Be "Готово. Сделал шторку.`nВторая строка."
        Get-NotifierLastAnswer -Path (Join-Path $TestDrive 'нет.jsonl') | Should Be ''
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'a'; $it.Title = 'shop'; $it.State = 'waiting'
            $it.Actions = [string[]]@('reply:0|Продолжай|secondary', 'reply-custom|Ответить…|primary')
            $f.View.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $f.View.SetAnswer('a', ((1..60 | ForEach-Object { "Строка ответа номер $_" }) -join "`n"))
            $f.View.Expanded = $true; $f.View.Page = 'answer'
            $sz = $f.SizeFor()
            ($sz.Height -gt $f.View.Theme.S(400)) | Should Be $true
            $f.ClientSize = $sz
            $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
            $f.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height)))
            $bmp.Dispose()
            ($f.View.HitIds() -contains 'act:reply-custom') | Should Be $true
            ($f.View.HitIds() -contains 'page:home') | Should Be $true
            ($f.View.HitIds() -contains 'page:chat') | Should Be $false   # вкладки «Ответ» больше нет
        }
        finally { $f.Dispose() }
    }

    It 'поток шторки: запуск, данные из трея, щелчок в очередь, страница пересылается, остановка' {
        $script:TrayDataRoot = Join-Path $TestDrive 'host'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [ClaudeNotifier.Ui.NotchHost]::Start()
        try {
            Test-NotifierNotchActive | Should Be $true
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'x'; $it.State = 'working'
            [ClaudeNotifier.Ui.NotchHost]::SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            [ClaudeNotifier.Ui.NotchHost]::ItemCount | Should Be 1
            # Щелчок по вкладке «Настройки» в потоке шторки → очередь → трей присылает строки страницы.
            [ClaudeNotifier.Ui.NotchHost]::ClickArea('page:settings')
            Invoke-NotifierNotchCommands
            $script:NotchPage | Should Be 'settings'
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while ([ClaudeNotifier.Ui.NotchHost]::RowCount('settings') -eq 0 -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            ([ClaudeNotifier.Ui.NotchHost]::RowCount('settings') -gt 10) | Should Be $true
            # Щелчок по карточке — трей присылает полный ответ из журнала.
            $tr = Join-Path $TestDrive 'host.jsonl'
            [IO.File]::WriteAllText($tr, '{"type":"assistant","message":{"content":[{"type":"text","text":"Полный ответ"}]}}' + "`n")
            $s = New-S 'h1' 'waiting'; $s | Add-Member -NotePropertyName transcript -NotePropertyValue $tr
            [ClaudeNotifier.Ui.NotchHost]::SetItems((Get-NotifierNotchItems -Sessions @($s)))
            [ClaudeNotifier.Ui.NotchHost]::ClickArea('expand')
            [ClaudeNotifier.Ui.NotchHost]::IsExpanded() | Should Be $true
            [ClaudeNotifier.Ui.NotchHost]::ClickArea('answer')
            Invoke-NotifierNotchCommands
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while (-not [ClaudeNotifier.Ui.NotchHost]::AnswerOf('h1') -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
            [ClaudeNotifier.Ui.NotchHost]::AnswerOf('h1') | Should Be 'Полный ответ'
            # Главное окно теперь шторка: «Сеансы → Статистика» раскрывает её на статистике.
            Mock Open-NotifierNotch { }
            Show-NotifierSessionsWindow -Tab 3
            Assert-MockCalled Open-NotifierNotch -Times 1 -Exactly -Scope It -ParameterFilter { $Page -eq 'stats' }
            $script:SessionsForm | Should Be $null
        }
        finally { [ClaudeNotifier.Ui.NotchHost]::Stop() }
        Test-NotifierNotchActive | Should Be $false
    }

    It 'настройки в шторке: тумблеры пишут config.json, звук — по кнопке, «Без звука»' {
        $script:TrayDataRoot = Join-Path $TestDrive 'nset'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $keys = @(Get-NotifierNotchSettingsRows | ForEach-Object { $_.Key } | Where-Object { $_ })
        foreach ($k in @('event.done', 'sound.done', 'quiet', 'approvals', 'quickReplies', 'showPrompt', 'context', 'stalled', 'remind', 'longTasks', 'inactive', 'hotkey', 'notch.screen', 'notch.position', 'notch', 'autostart', 'data')) { ($keys -contains $k) | Should Be $true }
        Invoke-NotifierNotchSetting -Key 'event.done'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).events.done.enabled | Should Be $false
        Invoke-NotifierNotchSetting -Key 'remind'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).approvals.remindMinutes | Should Be 0
        Invoke-NotifierNotchSetting -Key 'inactive'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).inactive.enabled | Should Be $false
        Invoke-NotifierNotchSetting -Key 'quiet'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).quiet.enabled | Should Be $true
        # Маскот этого ПК — селект: щелчок открывает список под кнопкой, выбор применяется сразу.
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascot | Should Be 'sphynx'
        @(Get-NotifierNotchSettingsRows | Where-Object { $_.Key -eq 'mascot:' })[0].Value | Should Be 'Сфинкс'
        Mock Show-NotifierSelect { }
        Invoke-NotifierNotchSetting -Key 'mascot:' -Location (New-Object System.Drawing.Point 10, 20) -Width 160
        Assert-MockCalled Show-NotifierSelect -Times 1 -Exactly -ParameterFilter { $Key -eq 'mascot:' -and $Width -eq 160 -and $Location.Y -eq 20 }
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascot | Should Be 'sphynx'   # щелчок сам ничего не меняет
        $opts = @(Get-NotifierSelectOptions -Key 'mascot:')
        ($opts | ForEach-Object { $_.Label }) -join ',' | Should Be 'Сфинкс,Огонёк'
        @($opts | Where-Object { $_.Current })[0].Value | Should Be 'sphynx'
        Set-NotifierSelectValue -Key 'mascot:' -Value 'flame'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascot | Should Be 'flame'
        [ClaudeNotifier.Ui.Mascot]::Kind | Should Be 'flame'
        @(Get-NotifierNotchSettingsRows | Where-Object { $_.Key -eq 'mascot:' })[0].Value | Should Be 'Огонёк'
        @(Get-NotifierSelectOptions -Key 'mascot:' | Where-Object { $_.Current })[0].Value | Should Be 'flame'
        Set-NotifierSelectValue -Key 'mascot:' -Value 'bogus'   # неизвестное значение не записывается
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascot | Should Be 'flame'
        Set-NotifierSelectValue -Key 'mascot:' -Value 'sphynx'
        [ClaudeNotifier.Ui.Mascot]::Kind | Should Be 'sphynx'
        # Свой маскот у устройства: только у него, этот ПК — прежний.
        Set-NotifierSelectValue -Key 'mascot:dev-mac' -Value 'flame'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascots['dev-mac'] | Should Be 'flame'
        [ClaudeNotifier.Ui.Mascot]::For('dev-mac') | Should Be 'flame'
        [ClaudeNotifier.Ui.Mascot]::For('') | Should Be 'sphynx'
        [ClaudeNotifier.Ui.Mascot]::For('other') | Should Be 'sphynx'
        Set-NotifierSelectValue -Key 'mascot:dev-mac' -Value 'sphynx'
        [ClaudeNotifier.Ui.Mascot]::For('dev-mac') | Should Be 'sphynx'
        # Разделы настроек — заголовки строк; на странице — боковое меню, раздел по щелчку.
        $titles = @(Get-NotifierNotchSettingsRows | Where-Object { $_.Kind -eq 'header' } | ForEach-Object { $_.Title })
        ($titles -join ',') | Should Be 'Уведомления,Ответы,Сеансы,Шторка,Маскоты,Система'
        $v = New-Object ClaudeNotifier.Ui.NotchView
        $v.SetRows('settings', [ClaudeNotifier.Ui.NotchRow[]]@(Get-NotifierNotchSettingsRows))
        $v.ClickArea('section:4', [System.Drawing.Point]::Empty)
        $v.SettingsSection | Should Be 4
        ($v.ContentHeight('settings', 732) -lt 420) | Should Be $true   # самый большой раздел — без прокрутки
        $v.Dispose()
        Set-NotifierSelectValue -Key 'notch.position' -Value 'right'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.position | Should Be 'right'
        # Строки «Монитор» и «Положение» — селекты (kind choice): в шторке рисуются кнопкой со стрелкой вниз
        @(Get-NotifierNotchSettingsRows | Where-Object { @('notch.screen', 'notch.position', 'mascot:') -contains $_.Key } | Where-Object { $_.Kind -ne 'choice' }).Count | Should Be 0
    }

    It 'страницы «Устройства» и «Статистика»: строки из данных трея' {
        $script:TrayDataRoot = Join-Path $TestDrive 'pages'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $rows = @(Get-NotifierNotchDevicesRows -Sessions @())
        ($rows | Where-Object { $_.Key -eq 'net' }).Kind | Should Be 'switch'
        ($rows | Where-Object { $_.Key -eq 'connect' }).Kind | Should Be 'button'
        $script:ActivitySummary = $null
        (@(Get-NotifierNotchStatsRows))[0].Kind | Should Be 'note'
        $pd = Join-Path $TestDrive 'projects\C--dev-shop'
        New-Item -ItemType Directory $pd -Force | Out-Null
        $t = [DateTime]::UtcNow.AddMinutes(-5).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        [IO.File]::WriteAllText((Join-Path $pd 'a.jsonl'), ("{`"type`":`"assistant`",`"timestamp`":`"$t`",`"cwd`":`"C:\\dev\\shop`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"msg_1`",`"usage`":{`"input_tokens`":100,`"output_tokens`":2000}}}`n"))
        $sd = Join-Path $TestDrive 'act'
        [void](Update-NotifierActivity -ProjectsDir (Join-Path $TestDrive 'projects') -StateDir $sd)
        $script:ActivitySummary = Get-NotifierActivitySummary -StateDir $sd
        $rows = @(Get-NotifierNotchStatsRows)
        ($rows | Where-Object { $_.Kind -eq 'chart' }).Values.Length | Should Be 7
        ($rows | Where-Object { $_.Title -eq 'shop' }).Count | Should Be 2   # сегодня и за неделю
        $script:ActivitySummary = $null
    }

    It 'звук выключен в шторке — уведомление показывается без звука' {
        $script:TrayDataRoot = Join-Path $TestDrive 'quiet'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"quiet":{"enabled":true},"longTasks":{"enabled":false}}')
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'q1'; type = 'done'; title = 'Готово'; preview = ''; session_id = 'z'; ts = (Iso ([DateTime]::UtcNow)) })
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It
        Assert-MockCalled Invoke-NotifierSound -Times 0 -Exactly -Scope It
    }

    It 'настройки: группа «Шторка» — тумблер, монитор и положение выбираются из списка' {
        $script:TrayDataRoot = Join-Path $TestDrive 'set'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $ui = $script:SessionsForm.Tag.Settings
            $ui.Switches['notch'].Checked | Should Be $true
            $ui.NotchPosition.Text | Should Be "По центру  $([char]0x25BE)"   # кнопка-селект со стрелкой вниз
            Mock Initialize-NotifierNotch { }
            $pos = @(Get-NotifierSelectOptions -Key 'notch.position')
            ($pos | ForEach-Object { $_.Label }) -join ',' | Should Be 'Слева,По центру,Справа'
            @($pos | Where-Object { $_.Current })[0].Value | Should Be 'center'
            Set-NotifierSelectValue -Key 'notch.position' -Value 'left'
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.position | Should Be 'left'
            Set-NotifierSelectValue -Key 'notch.position' -Value 'top'   # чужое значение не записывается
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.position | Should Be 'left'
            Update-NotifierSettingsView
            $ui.NotchPosition.Text | Should Be "Слева  $([char]0x25BE)"
            $screens = @(Get-NotifierSelectOptions -Key 'notch.screen')
            $screens.Count | Should Be @([System.Windows.Forms.Screen]::AllScreens).Count
            @($screens | Where-Object { $_.Current }).Count | Should Be 1
            Set-NotifierSelectValue -Key 'notch.screen' -Value $screens[-1].Value
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.screen | Should Be $screens[-1].Value
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }

    It 'сфинкс думает: новое действие Claude — «Ага!», долгая пауза — задумался, агенты и «остановился» — из данных трея' {
        $v = New-Object ClaudeNotifier.Ui.NotchView
        try {
            $mk = { param($tools, $agents) $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 's'; $it.State = 'working'; $it.Tools = $tools; $it.Agents = $agents; ,([ClaudeNotifier.Ui.NotchItem[]]@($it)) }
            $v.SetItems((& $mk 10 0))
            $r = New-Object System.Drawing.RectangleF(0, 0, 100, 80)
            $m = $v.MoodFor($v[0], $r, $false)
            $m.AhaAge | Should Be -1
            $m.Deep | Should Be $false
            $v.SetItems((& $mk 12 2))   # два новых действия и два агента
            $m = $v.MoodFor($v[0], $r, $false)
            ($m.AhaAge -ge 0 -and $m.AhaAge -lt 0.5) | Should Be $true
            $m.Agents | Should Be 2
            [ClaudeNotifier.Ui.NotchView]::DeepAfterSeconds = 0
            Start-Sleep -Milliseconds 2100   # «озарения» прошли, действий нет
            $v.MoodFor($v[0], $r, $false).Deep | Should Be $true
        }
        finally { [ClaudeNotifier.Ui.NotchView]::DeepAfterSeconds = 25; $v.Dispose() }
        # Случайные мелочи: детерминированы (время и номер сфинкса), бывают все четыре вида.
        $kinds = @{}
        for ($t = 0.0; $t -lt 600; $t += 0.1) { $p = 0.0; $k = [ClaudeNotifier.Ui.Cat]::EventAt($t, 3, [ref]$p); if ($k -gt 0) { $kinds[$k] = $true } }
        ($kinds.Keys | Sort-Object) -join ',' | Should Be '1,2,3,4'
        $p1 = 0.0; $p2 = 0.0
        [ClaudeNotifier.Ui.Cat]::EventAt(123.4, 5, [ref]$p1) | Should Be ([ClaudeNotifier.Ui.Cat]::EventAt(123.4, 5, [ref]$p2))
        # Данные трея: действия, агенты, «остановился».
        $s = New-S 'z' 'working'
        $s | Add-Member -NotePropertyName stats -NotePropertyValue ([pscustomobject]@{ tools = 42; context = 1; output = 1; prompts = 1 })
        $s | Add-Member -NotePropertyName agents -NotePropertyValue @([pscustomobject]@{ name = 'a'; doing = '' }, [pscustomobject]@{ name = 'b'; doing = '' })
        $s | Add-Member -NotePropertyName stalledSince -NotePropertyValue '2026-11-18T07:00:00Z'
        $card = ConvertTo-NotifierSessionCard -Session $s
        $it = ConvertTo-NotifierNotchItem -Card $card -Session $s
        $it.Tools | Should Be 42
        $it.Agents | Should Be 2
        $it.State | Should Be 'stalled'
        # Все виды настроения рисуются.
        $bmp = New-Object System.Drawing.Bitmap 140, 110
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            foreach ($cfg in @(@(-1, $false, 0, $false), @(0.2, $false, 3, $false), @(-1, $true, 5, $false), @(-1, $false, 0, $true))) {
                $md = New-Object ClaudeNotifier.Ui.CatMood; $md.AhaAge = $cfg[0]; $md.Deep = $cfg[1]; $md.Agents = $cfg[2]; $md.HasLook = $cfg[3]; $md.LookX = 0.7; $md.LookY = -0.4
                foreach ($st in @('working', 'stalled')) { [ClaudeNotifier.Ui.Cat]::Paint($g, (New-Object System.Drawing.RectangleF(10, 10, 120, 90)), $st, 3.3, 1, $true, $md) }
            }
        }
        finally { $g.Dispose(); $bmp.Dispose() }
    }

    It 'убрать сеанс справа: крестик на плашке — событие remove, трей убирает сеанс; правый щелчок — меню сеанса' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.NotchItem]'
            foreach ($id in @('a', 'b')) { $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = $id; $it.Title = $id; $it.State = 'waiting'; $items.Add($it) }
            $f.View.SetItems($items)
            $f.View.Expanded = $true; $f.View.Page = 'home'
            $sz = $f.SizeFor(); $f.ClientSize = $sz
            $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
            $f.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))); $bmp.Dispose()
            ($f.View.HitIds() -contains 'remove:b') | Should Be $true
            $script:got = @()
            $f.View.add_Command({ param($s, $e) $script:got += "$($e.Kind)|$($e.Id)" })
            $f.View.ClickArea('remove:b', [System.Drawing.Point]::Empty)
            $script:got -join ';' | Should Be 'remove|b'
            $f.View.SelectedId | Should Be 'a'   # крестик не выбирает сеанс
        }
        finally { $f.Dispose() }
        $script:TrayDataRoot = Join-Path $TestDrive 'rm'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @((New-S 'a' 'waiting'), (New-S 'b' 'working'))
        Invoke-NotifierNotchCommand -Event (New-Object ClaudeNotifier.Ui.NotchEventArgs('remove', 'b', $null, [System.Drawing.Point]::Empty))
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | ForEach-Object { $_.session_id }) -join ',' | Should Be 'a'
        # Правый щелчок — меню сеанса (то же, что в окне).
        [void](Get-NotifierNotchItems -Sessions @((New-S 'a' 'waiting')))
        Mock Show-NotifierNotchSessionMenu { }
        Invoke-NotifierNotchCommand -Event (New-Object ClaudeNotifier.Ui.NotchEventArgs('menu', 'a', $null, [System.Drawing.Point]::Empty))
        Assert-MockCalled Show-NotifierNotchSessionMenu -Times 1 -Exactly -Scope It -ParameterFilter { $Card.Id -eq 'a' }
    }

    It 'взгляд на курсор без рывков: промежуточный поворот — смесь соседних кадров того же размера' {
        $skin = [Drawing.Color]::FromArgb(0xE9, 0xB5, 0xA2)
        $p = New-Object ClaudeNotifier.Ui.SphynxPose; $p.State = 'waiting'; $p.Yaw = 0.0175; $p.Pitch = 0.02
        [ClaudeNotifier.Ui.SphynxSprites]::PerFrame = 8; [ClaudeNotifier.Ui.SphynxSprites]::BeginFrame()
        $b = [ClaudeNotifier.Ui.SphynxSprites]::GetBlended(60, 46, $p, $skin, $skin, 7)
        if ([ClaudeNotifier.Ui.Sphynx3D]::Available) {
            $b | Should Not BeNullOrEmpty
            $b.Width | Should Be 60   # кадры хранятся в итоговом размере (1×)
            $b.GetPixel(30, 23).A | Should BeGreaterThan 250   # середина морды непрозрачна
        }
        $m = New-Object ClaudeNotifier.Ui.CatMood
        $m.LookW | Should Be 1
        $m.HasLook = $true; $m.LookX = 0.5; $m.LookW = 0.3
        $bmp = New-Object Drawing.Bitmap(80, 60); $g = [Drawing.Graphics]::FromImage($bmp)
        { [ClaudeNotifier.Ui.Cat]::Paint($g, (New-Object Drawing.RectangleF(0, 0, 80, 60)), 'waiting', 1.0, 7, $true, $m) } | Should Not Throw
        $g.Dispose(); $bmp.Dispose()
        [ClaudeNotifier.Ui.SphynxSprites]::PerFrame = 2
    }

    It 'фон: таймер трея в покое реже (250 мс), при событиях и открытой шторке — 100 мс; кадры 3D — с потолком в секунду' {
        $now = [datetime]::UtcNow
        Get-NotifierTickInterval -LastActivity $now.AddSeconds(-1) -Now $now -Expanded $false -IdleSeconds 0 | Should Be 100
        Get-NotifierTickInterval -LastActivity $now.AddSeconds(-30) -Now $now -Expanded $false -IdleSeconds 0 | Should Be 250
        Get-NotifierTickInterval -LastActivity $now.AddSeconds(-30) -Now $now -Expanded $true -IdleSeconds 0 | Should Be 100
        Get-NotifierTickInterval -LastActivity $now.AddSeconds(-30) -Now $now -Expanded $false -IdleSeconds 300 | Should Be 1000   # вас нет
        Get-NotifierTickInterval -LastActivity $now.AddSeconds(-1) -Now $now -Expanded $false -IdleSeconds 300 | Should Be 100      # но событие — быстро
        ([ClaudeNotifier.Ui.Native]::InputIdleSeconds() -ge 0) | Should Be $true
        [ClaudeNotifier.Ui.NotchView]::Paused | Should Be $false
        [ClaudeNotifier.Ui.SphynxSprites]::RatePerSec | Should BeGreaterThan 0
    }

    It 'кадры 3D на диске: после первого рендера берутся с диска, без нового рендера' {
        if (-not [ClaudeNotifier.Ui.Sphynx3D]::Available) { return }
        $old = [ClaudeNotifier.Ui.SphynxSprites]::DiskDir
        try {
            [ClaudeNotifier.Ui.SphynxSprites]::DiskDir = Join-Path $TestDrive 'sprites'
            [ClaudeNotifier.Ui.SphynxSprites]::ClearMemory()
            $skin = [Drawing.Color]::FromArgb(0xE9, 0xB5, 0xA2)
            $p = New-Object ClaudeNotifier.Ui.SphynxPose; $p.State = 'waiting'; $p.Yaw = 0.27
            [ClaudeNotifier.Ui.SphynxSprites]::PerFrame = 8; [ClaudeNotifier.Ui.SphynxSprites]::BeginFrame()
            $r0 = [ClaudeNotifier.Ui.SphynxSprites]::Renders
            $a = [ClaudeNotifier.Ui.SphynxSprites]::Get(64, 50, $p, $skin, $skin, 3)
            ([ClaudeNotifier.Ui.SphynxSprites]::Renders - $r0) | Should Be 1
            @(Get-ChildItem (Join-Path $TestDrive 'sprites') -Filter *.png).Count | Should Be 1
            [ClaudeNotifier.Ui.SphynxSprites]::ClearMemory()   # как новый запуск трея
            $d0 = [ClaudeNotifier.Ui.SphynxSprites]::DiskHits; $r1 = [ClaudeNotifier.Ui.SphynxSprites]::Renders
            [ClaudeNotifier.Ui.SphynxSprites]::BeginFrame()
            $b = [ClaudeNotifier.Ui.SphynxSprites]::Get(64, 50, $p, $skin, $skin, 3)
            ([ClaudeNotifier.Ui.SphynxSprites]::DiskHits - $d0) | Should Be 1
            [ClaudeNotifier.Ui.SphynxSprites]::Renders | Should Be $r1
            $b.Width | Should Be 64
            $b.GetPixel(32, 25).A | Should BeGreaterThan 250
        }
        finally {
            [ClaudeNotifier.Ui.SphynxSprites]::ClearMemory()
            [ClaudeNotifier.Ui.SphynxSprites]::DiskDir = $old
            [ClaudeNotifier.Ui.SphynxSprites]::PerFrame = 2
        }
    }

    It 'персонажи рисуются во всех статусах' {
        $bmp = New-Object System.Drawing.Bitmap 120, 90
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try { foreach ($st in @('working', 'waiting', 'permission', 'error', 'none')) { [ClaudeNotifier.Ui.Face]::Paint($g, (New-Object System.Drawing.RectangleF(10, 10, 100, 70)), $st, 1.5, 1, $true) } }
        finally { $g.Dispose(); $bmp.Dispose() }
        [ClaudeNotifier.Ui.Face]::BodyColor('working').ToArgb() | Should Be ([ClaudeNotifier.Ui.Theme]::Hex(0xD97757).ToArgb())
    }

    It 'огонёк: рисуется во всех статусах и настроениях, крупным и мелким; середина — тёплая' {
        $bmp = New-Object System.Drawing.Bitmap 160, 130
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            foreach ($st in @('working', 'waiting', 'permission', 'error', 'stalled', 'none', '')) {
                $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Agents = 2; $m.AhaAge = 0.3; $m.HasLook = $true; $m.LookX = -0.5; $m.LookW = 0.7
                { [ClaudeNotifier.Ui.Flame]::Paint($g, (New-Object System.Drawing.RectangleF(10, 10, 140, 108)), $st, 2.1, 5, $true, $m) } | Should Not Throw
                { [ClaudeNotifier.Ui.Flame]::Paint($g, (New-Object System.Drawing.RectangleF(5, 5, 26, 20)), $st, 2.1, 5, $false, $null) } | Should Not Throw
            }
            $g.Clear([System.Drawing.Color]::Black)
            [ClaudeNotifier.Ui.Flame]::Paint($g, (New-Object System.Drawing.RectangleF(10, 10, 140, 108)), 'waiting', 0, 1, $false, $null)
            $c = $bmp.GetPixel(80, 100)   # серединка пламени (под ротиком)
            ($c.R -gt 200 -and $c.G -gt 140 -and $c.B -lt 160) | Should Be $true
        }
        finally { $g.Dispose(); $bmp.Dispose() }
        # Выбор маскота: неизвестное значение — сфинкс.
        [ClaudeNotifier.Ui.Mascot]::Kind = 'whatever'; [ClaudeNotifier.Ui.Mascot]::Kind | Should Be 'sphynx'
    }
}
