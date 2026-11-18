$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

function Iso([datetime]$T) { return $T.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function New-S([string]$Id, [string]$State, [string]$Project = 'shop', [int]$AgoMin = 1, [string]$Preview = '') {
    return [pscustomobject]@{ session_id = $Id; project = $Project; origin = 'cli'; device = ''; state = $State; since = (Iso ([DateTime]::UtcNow.AddMinutes(-$AgoMin))); updated = (Iso ([DateTime]::UtcNow.AddMinutes(-$AgoMin))); preview = $Preview; window = $null }
}

Describe 's_014_01 · удобство: текст без разметки, таблица, плашки, поиск, число на точке, кнопки в уведомлениях' {
    It 'превью без разметки Markdown: жирный, курсив, код, заголовки, цитаты, ссылки, списки' {
        ConvertTo-NotifierPlainText 'Вот **Порядок** и *курсив*, `код` и [ссылка](http://x.y/z)' | Should Be 'Вот Порядок и курсив, код и ссылка'
        ConvertTo-NotifierPlainText "## Заголовок`n- пункт`n> цитата" | Should Be "Заголовок`n• пункт`nцитата"
        ConvertTo-NotifierPlainText '2*3*4 и snake_case_name' | Should Be '2*3*4 и snake_case_name'
        ConvertTo-NotifierPlainText '' | Should Be ''
        ConvertTo-NotifierPlainText 'видны `**Порядок в списке** 1. **Старые' | Should Be 'видны Порядок в списке 1. Старые'
        $card = ConvertTo-NotifierSessionCard -Session (New-S 'p' 'waiting' -Preview '**Готово**: `npm test` прошёл')
        $card.Preview | Should Be 'Готово: npm test прошёл'
    }

    It 'короткие пути: папка пользователя → ~, середина длинного пути → …' {
        Format-NotifierShortText 'Get-Content C:\Users\Someone\.claude\settings.json' | Should Be 'Get-Content ~\.claude\settings.json'
        Format-NotifierShortText 'cd "C:/Users/ABC~1/AppData/Local/Temp/claude/x/scratchpad; ls' | Should Be 'cd "~/AppData/…/x/scratchpad; ls'
        Format-NotifierShortText 'C:\dev\Tools\claude-notifier\src\lib\Ui.cs' | Should Be 'C:\dev\…\lib\Ui.cs'
        Format-NotifierShortText 'npm run build' | Should Be 'npm run build'
        Format-NotifierShortText ('x' * 50) -Max 10 | Should Be ('x' * 9 + '…')
    }

    It 'карточка: подробности — таблица «подпись<Tab>значение», плашки, команда коротко; таблица рисуется' {
        $s = New-S 'c' 'working'
        $s | Add-Member -NotePropertyName stats -NotePropertyValue ([pscustomobject]@{ context = 420000; window = 1000000; percent = 42; output = 9000; tools = 12; prompts = 3; files = 21; recentFiles = @('a.ts'); cost = 12.4; agentsCost = 0; commands = @('cat C:\Users\Someone\proj\src\deep\more\file.txt') })
        $card = ConvertTo-NotifierSessionCard -Session $s
        ($card.Chips -join ',') | Should Be 'контекст 42 %,≈ $12,40,изменено 21 файл'
        $card.Details | Should Match "(?m)^Контекст`t42 %"
        $card.Details | Should Match "(?m)^Команда`tcat ~\\proj\\…\\more\\file\.txt$"
        $list = New-Object ClaudeNotifier.Ui.CardList
        try {
            $list.Size = New-Object System.Drawing.Size(520, 600)
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
            $card.SubLines = [string[]]@('Сайт A — Bash: npm test')
            $items.Add($card)
            $list.SetItems($items); $list.Select(0)
            $bmp = New-Object System.Drawing.Bitmap 520, 600
            $list.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 520, 600)))
            $bmp.Dispose()
        }
        finally { $list.Dispose() }
        # Страница телефона: Tab → «: ».
        $root = Join-Path $TestDrive 'api'
        New-Item -ItemType Directory $root -Force | Out-Null
        Save-NotifierSessions -DataRoot $root -Sessions @($s)
        $p = Get-NotifierSessionsPayload -Ctx @{ Network = (Get-NotifierNetwork -DataRoot $root); DataRoot = $root; PcName = 'PC' }
        $p.sessions[0].details | Should Match '(?m)^Контекст: 42 %'
        $p.sessions[0].details | Should Not Match "`t"
    }

    It 'повторный щелчок по раскрытой карточке сворачивает её, в том числе раскрытую запросом; новый запрос раскрывает снова' {
        $list = New-Object ClaudeNotifier.Ui.CardList
        try {
            $list.Size = New-Object System.Drawing.Size(500, 600)
            $mk = { param($id) $c = New-Object ClaudeNotifier.Ui.CardItem; $c.Id = $id; $c.Title = $id; $c.State = 'waiting'; $c }
            $a = & $mk 'a'
            $b = & $mk 'b'; $b.ForceExpand = $true; $b.RequestTitle = 'Быстрый ответ'; $b.Actions = [string[]]@('reply:0|Да|secondary')
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
            $items.Add($a); $items.Add($b)
            $list.SetItems($items)
            $list.IsRowExpanded(0) | Should Be $false
            $list.ClickRow(0); $list.IsRowExpanded(0) | Should Be $true    # раскрыть
            $list.ClickRow(0); $list.IsRowExpanded(0) | Should Be $false   # повторный щелчок — свернуть
            $list.SelectedItem | Should Be $null
            $list.IsRowExpanded(1) | Should Be $true                       # раскрыта запросом
            $list.ClickRow(1); $list.IsRowExpanded(1) | Should Be $false
            $list.ClickRow(1); $list.IsRowExpanded(1) | Should Be $true
            $list.ClickRow(1); $list.IsRowExpanded(1) | Should Be $false
            # Обновление списка с тем же запросом — остаётся свёрнутой; новый запрос — раскрыта снова.
            $list.SetItems($items); $list.IsRowExpanded(1) | Should Be $false
            $b2 = & $mk 'b'; $b2.ForceExpand = $true; $b2.RequestTitle = 'Нужно разрешение'; $b2.Actions = [string[]]@('allow|Разрешить|primary')
            $items2 = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
            $items2.Add($a); $items2.Add($b2)
            $list.SetItems($items2); $list.IsRowExpanded(1) | Should Be $true
        }
        finally { $list.Dispose() }
    }

    It 'пружина: доходит до цели с небольшим перелётом и останавливается' {
        $s = [float[]]@(0, 0)
        $max = 0.0; $t = 0
        while (-not [ClaudeNotifier.Ui.CardList]::SpringStep($s, 100, 0.005) -and $t -lt 400) { $max = [Math]::Max($max, $s[0]); $t++ }
        $s[0] | Should Be 100
        ($t * 0.005 -lt 1.2) | Should Be $true           # успокаивается быстрее чем за 1,2 с
        ($max -gt 100 -and $max -lt 112) | Should Be $true   # «stiff»: лёгкий перелёт, без болтанки
    }

    It 'карточка в показанном окне раскрывается пружиной; без анимации в Windows — сразу' {
        $form = New-Object System.Windows.Forms.Form
        $form.ShowInTaskbar = $false; $form.StartPosition = 'Manual'; $form.Location = New-Object System.Drawing.Point(-3000, -3000)
        $form.Size = New-Object System.Drawing.Size(520, 600)
        $list = New-Object ClaudeNotifier.Ui.CardList
        $list.Dock = 'Fill'
        $form.Controls.Add($list)
        try {
            [ClaudeNotifier.Ui.Motion]::Force($true)
            $form.Show(); [System.Windows.Forms.Application]::DoEvents()
            $mk = { param($id) $c = New-Object ClaudeNotifier.Ui.CardItem; $c.Id = $id; $c.Title = $id; $c.State = 'waiting'; $c.Preview = 'ответ'; $c.Details = "Контекст`t42 %`nРабота`tзапросов 3"; $c }
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
            $items.Add((& $mk 'a')); $items.Add((& $mk 'b'))
            $list.SetItems($items)
            $list.Animating | Should Be $false   # первое заполнение — без анимации
            $list.ClickRow(0)
            $list.Animating | Should Be $true
            $deadline = [DateTime]::UtcNow.AddSeconds(3)
            while ($list.Animating -and [DateTime]::UtcNow -lt $deadline) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 10 }
            $list.Animating | Should Be $false
            $list.IsRowExpanded(0) | Should Be $true
            [ClaudeNotifier.Ui.Motion]::Force($false)
            $list.ClickRow(0)
            $list.Animating | Should Be $false   # эффекты анимации выключены — сразу
        }
        finally { [ClaudeNotifier.Ui.Motion]::Force($null); $form.Close(); $form.Dispose() }
    }

    It 'строки-группы: число сеансов серым (не цвет статуса)' {
        $mk = { param($id, $st) $c = New-Object ClaudeNotifier.Ui.CardItem; $c.Id = $id; $c.Section = 'Этот ПК'; $c.State = $st; $c.Tag = (New-S $id $st); $c }
        $l = Get-NotifierGroupedCards -Cards @((& $mk 'a' 'working'), (& $mk 'b' 'working'), (& $mk 'c' 'waiting'), (& $mk 'd' 'working')) -MinSessions 4 -Expanded @{}
        $l[0].IsGroup | Should Be $true
        $l[0].NeutralState | Should Be $true
    }

    It 'точка в трее: число ждущих вас (разрешение, ошибка, свежее «Ждёт ответа»); с двух — на иконке' {
        $script:TrayDataRoot = Join-Path $TestDrive 'dot'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $sessions = @((New-S 'a' 'permission'), (New-S 'b' 'waiting'), (New-S 'c' 'waiting' -AgoMin 300), (New-S 'd' 'working'), (New-S 'e' 'error'))
        Get-NotifierWaitingCount -Sessions $sessions | Should Be 3
        $icon = New-Object System.Windows.Forms.NotifyIcon
        try {
            $script:TrayStateShown = ''; $script:TrayCountShown = 0
            [void](Update-NotifierTrayStatus -Sessions $sessions -Icon $icon)
            $script:TrayCountShown | Should Be 3
            [object]::ReferenceEquals($icon.Icon, (Get-NotifierDotIcon 'permission' -Count 3)) | Should Be $true
            [object]::ReferenceEquals((Get-NotifierDotIcon 'permission' -Count 1), (Get-NotifierDotIcon 'permission')) | Should Be $true
            $bmp = [ClaudeNotifier.Ui.TrayDot]::Render('permission', 32, 12)
            $bmp.Width | Should Be 32
            $bmp.Dispose()
        }
        finally { $icon.Dispose() }
    }

    It 'поиск и фильтр: по имени, проекту, ответу; «Ждут меня» и «Работают»; Ctrl+F показывает строку поиска' {
        $sessions = @((New-S 'a' 'working' 'shop' -Preview 'Правлю корзину'), (New-S 'b' 'waiting' 'api'), (New-S 'c' 'permission' 'docs'))
        (@(Select-NotifierFilteredSessions -Sessions $sessions -Filter @{ Text = 'КОРЗ'; Mode = 'all' }) | ForEach-Object { $_.session_id }) -join ',' | Should Be 'a'
        (@(Select-NotifierFilteredSessions -Sessions $sessions -Filter @{ Text = ''; Mode = 'me' }) | ForEach-Object { $_.session_id }) -join ',' | Should Be 'b,c'
        (@(Select-NotifierFilteredSessions -Sessions $sessions -Filter @{ Text = 'api'; Mode = 'work' })).Count | Should Be 0
        Test-NotifierFilterActive @{ Text = ' '; Mode = 'all' } | Should Be $false
        Test-NotifierFilterActive @{ Text = ''; Mode = 'me' } | Should Be $true
        $script:TrayDataRoot = Join-Path $TestDrive 'search'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions $sessions
        $script:SessionFilter = @{ Text = ''; Mode = 'all' }
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            [void](Invoke-NotifierSessionsRefresh)
            $script:SearchOpen | Should Be $false   # 3 сеанса — строка поиска не нужна
            Show-NotifierSearch
            $script:SearchOpen | Should Be $true
            Set-NotifierSessionFilterMode me
            $script:SessionsForm.Tag.Cards.Count | Should Be 2
            $script:SessionsForm.Tag.Subtitle.Text | Should Be 'Показано 2 из 3'
            $script:SessionsForm.Tag.Search.Buttons['me'].Style | Should Be 'primary'
            $script:SessionsForm.Tag.Search.Box.Text = 'нет-такого'
            $script:SessionsForm.Tag.Cards.Count | Should Be 0
            $script:SessionsForm.Tag.Cards.EmptyTitle | Should Be 'Ничего не найдено'
            $script:SessionsForm.Tag.Search.Box.Text = ''
            Set-NotifierSessionFilterMode all
            $script:SessionsForm.Tag.Cards.Count | Should Be 3
            $script:SessionsForm.Tag.Cards.EmptyTitle | Should Be 'Активных сеансов нет'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null; $script:SessionFilter = @{ Text = ''; Mode = 'all' } }
    }

    It 'полосы лимитов: нет данных — одна строка «Лимиты Claude»; есть — обе полосы' {
        $t = Get-NotifierTheme
        $u = New-NotifierUsagePanel -Theme $t
        $full = $u.Panel.Height
        Set-NotifierUsageCompact -Usage $u -Compact $true
        $u.Week.Visible | Should Be $false
        $u.Five.Label | Should Be 'Лимиты Claude'
        ($u.Panel.Height -lt $full) | Should Be $true
        Set-NotifierUsageCompact -Usage $u -Compact $false
        $u.Panel.Height | Should Be $full
        $u.Five.Label | Should Be '5 часов'
    }

    It 'уведомление: кнопки в XML; запрос — решения из файла запроса, «Готово» — быстрые ответы' {
        $xml = New-NotifierToastXml -Event ([pscustomobject]@{ title = 'T'; preview = '' }) -Actions @(@{ Content = 'Разрешить'; Arguments = 'cn|s|r|allow' }, @{ Content = 'A&B'; Arguments = 'x' })
        $xml | Should Match '<actions><action content="Разрешить" arguments="cn\|s\|r\|allow" activationType="foreground"/><action content="A&amp;B"'
        (New-NotifierToastXml -Event ([pscustomobject]@{ title = 'T'; preview = '' })) | Should Not Match '<actions>'
        $script:TrayDataRoot = Join-Path $TestDrive 'tb'
        New-Item -ItemType Directory (Join-Path $script:TrayDataRoot 'requests') -Force | Out-Null
        $now = [DateTime]::UtcNow
        $req = [pscustomobject][ordered]@{ type = 'permission'; id = '1b2c3d4e-0000-4000-8000-000000000001'; session_id = 'b'; pid = $PID; kind = 'tool'; title = 'Bash'; detail = 'npm i'; options = @(); canAlways = $true; created = $now.ToString('o'); expires = $now.AddMinutes(10).ToString('o') }
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'requests\perm-1b2c3d4e-0000-4000-8000-000000000001.json'), (ConvertTo-Json $req -Compress), (New-Object Text.UTF8Encoding $false))
        $cfg = Get-NotifierDefaultConfig
        $ev = [pscustomobject]@{ type = 'permission'; session_id = 'b'; request_id = '1b2c3d4e-0000-4000-8000-000000000001'; title = 'x'; preview = '' }
        (@(Get-NotifierToastButtons -Event $ev -Config $cfg -Request) | ForEach-Object { "$($_.Content)=$($_.Arguments)" }) -join ';' | Should Be 'Разрешить=cn|b|1b2c3d4e-0000-4000-8000-000000000001|allow;Всегда=cn|b|1b2c3d4e-0000-4000-8000-000000000001|always;Запретить=cn|b|1b2c3d4e-0000-4000-8000-000000000001|deny'
        @(Get-NotifierToastButtons -Event ([pscustomobject]@{ type = 'done'; session_id = 'b'; preview = 'Сделал. Запустить тесты?' }) -Config $cfg).Count | Should Be 3
        # Claude ничего не спросил — в уведомлении «Готово» кнопок быстрого ответа нет
        @(Get-NotifierToastButtons -Event ([pscustomobject]@{ type = 'done'; session_id = 'b'; preview = 'Готово, всё работает.' }) -Config $cfg).Count | Should Be 0
        # Вопрос определяется по концу ответа в журнале: начало без вопроса, конец — с вопросом
        $tj = Join-Path $TestDrive 'ask.jsonl'
        $txt = 'Сделал шторку.\n\nВсё проверил.\n\nЗакоммитить и отправить?'
        [IO.File]::WriteAllText($tj, '{"type":"assistant","message":{"content":[{"type":"text","text":"' + $txt + '"}]}}' + "`n", (New-Object Text.UTF8Encoding $false))
        @(Get-NotifierToastButtons -Event ([pscustomobject]@{ type = 'done'; session_id = 'b'; preview = 'Сделал шторку.'; transcript = $tj }) -Config $cfg).Count | Should Be 3
        Test-NotifierAnswerAsks "Готово.`nСсылка: https://x.example/?a=1" | Should Be $false   # «?» в ссылке — не вопрос
        Test-NotifierAnswerAsks "Готово.`nЗапустил ``ls -la ?``" | Should Be $false            # и в коде
        Test-NotifierAnswerAsks "Какой вариант выбрать?`n`n" | Should Be $true
        Test-NotifierAnswerAsks '' | Should Be $false
        @(Get-NotifierToastButtons -Event ([pscustomobject]@{ type = 'done'; session_id = 'b'; device = 'mac' }) -Config $cfg).Count | Should Be 0
        $cfg.quickReplies.enabled = $false
        @(Get-NotifierToastButtons -Event ([pscustomobject]@{ type = 'done'; session_id = 'b' }) -Config $cfg).Count | Should Be 0
    }

    It 'нажатие кнопки уведомления: решение записывается, сеанс «Работает»; чужие аргументы игнорируются' {
        $script:TrayDataRoot = Join-Path $TestDrive 'press'
        New-Item -ItemType Directory (Join-Path $script:TrayDataRoot 'requests') -Force | Out-Null
        $now = [DateTime]::UtcNow
        $req = [pscustomobject][ordered]@{ type = 'permission'; id = '1b2c3d4e-0000-4000-8000-000000000002'; session_id = 'b'; pid = $PID; kind = 'tool'; title = 'Bash'; detail = 'npm i'; options = @(); canAlways = $false; created = $now.ToString('o'); expires = $now.AddMinutes(10).ToString('o') }
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'requests\perm-1b2c3d4e-0000-4000-8000-000000000002.json'), (ConvertTo-Json $req -Compress), (New-Object Text.UTF8Encoding $false))
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @((New-S 'b' 'permission'))
        Invoke-NotifierToastButton -Arguments 'evil|b|1b2c3d4e-0000-4000-8000-000000000002|allow' | Should Be ''
        Invoke-NotifierToastButton -Arguments 'cn|b|1b2c3d4e-0000-4000-8000-000000000002|rm -rf' | Should Be ''
        Invoke-NotifierToastButton -Arguments 'cn|zz|1b2c3d4e-0000-4000-8000-000000000002|allow' | Should Be 'Сеанс уже завершён'
        [ClaudeNotifier.Ui.ToastHook]::Queue.Enqueue('cn|b|1b2c3d4e-0000-4000-8000-000000000002|allow')
        Invoke-NotifierToastButtons
        [ClaudeNotifier.Ui.ToastHook]::Queue.IsEmpty | Should Be $true
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should Be 'working'
        Invoke-NotifierToastButton -Arguments 'cn|b|1b2c3d4e-0000-4000-8000-000000000002|deny' | Should Be 'Запрос уже решён в Claude'
    }

    It 'подписка на нажатие уведомления WinRT не падает' {
        $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
        $doc.LoadXml('<toast><visual><binding template="ToastGeneric"><text>x</text></binding></visual></toast>')
        $toast = New-Object Windows.UI.Notifications.ToastNotification $doc
        { [ClaudeNotifier.Ui.ToastHook]::Attach($toast) } | Should Not Throw
    }
}
