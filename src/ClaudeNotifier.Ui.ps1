<#
.SYNOPSIS
Интерфейс трея claude-notifier: окно «Сеансы» (карточки, вкладки), точка статуса в трее, диалоги.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source и работает в его области видимости ($script:…).
Отрисовка — элементы ClaudeNotifier.Ui.* из lib\ui\*.cs: тема как в Windows (светлая/тёмная), Segoe UI Variable.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Ui.psm1')

$script:NoticeUntil = [datetime]::MinValue
$script:DotIcons = @{}
$script:TrayCountShown = 0   # число на точке в трее: сколько сеансов ждут вас
$script:SessionFilter = @{ Text = ''; Mode = 'all' }   # поиск и фильтр списка сеансов (только в окне)
$script:SearchOpen = $false   # строку поиска открыли (Ctrl+F); закрывается Esc в пустом поле
$script:TrayStateShown = $null

function Get-NotifierTheme {
    <# .SYNOPSIS Тема по настройке Windows и масштаб экрана (DPI / 96). #>
    [void](Import-NotifierUi)
    $theme = [ClaudeNotifier.Ui.Theme]::Current()
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $theme.Scale = [float]($g.DpiX / 96) } finally { $g.Dispose() }
    return $theme
}

# --- Точка статуса в трее ---

function Get-NotifierDotIcon {
    <# .SYNOPSIS Иконка-точка для статуса (кэшируется на время работы трея). #>
    param([Parameter(Mandatory = $true)][string]$State, [int]$Count = 0)
    if ($Count -lt 2) { $Count = 0 }
    $key = "$State|$Count"
    if (-not $script:DotIcons.ContainsKey($key)) {
        [void](Import-NotifierUi)
        $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        $script:DotIcons[$key] = [ClaudeNotifier.Ui.TrayDot]::Create($State, $size, $Count)
    }
    return $script:DotIcons[$key]
}

function Get-NotifierWaitingCount {
    <#
    .SYNOPSIS
    Сколько сеансов ждут вас: нужно разрешение, ошибка или «Ждёт ответа» не дольше порога «Неактивные»
    (давние сеансы число не раздувают). На точке в трее число видно с двух.
    #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [datetime]$Now = [DateTime]::UtcNow)
    $hours = 2
    if ($script:TrayDataRoot) { $cfg = Get-NotifierConfig -DataRoot $script:TrayDataRoot; $hours = 0; if ($cfg.inactive.enabled) { $hours = [int]$cfg.inactive.hours } }
    $n = 0
    foreach ($s in $Sessions) {
        $st = [string]$s.state
        if ($st -eq 'permission' -or $st -eq 'error') { $n++; continue }
        if ($st -ne 'waiting') { continue }
        $since = ConvertTo-NotifierUtc ([string]$s.since)
        if ($hours -le 0 -or $null -eq $since -or ($Now - $since).TotalHours -lt $hours) { $n++ }
    }
    return $n
}

function Update-NotifierTrayStatus {
    <# .SYNOPSIS Меняет точку в трее и подсказку по списку живых сеансов. Возвращает показанный статус. #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), $Icon = $script:TrayState.Icon)
    $state = Get-NotifierTrayState -Sessions $Sessions
    $count = Get-NotifierWaitingCount -Sessions $Sessions
    if ($Icon) {
        if ($state -ne $script:TrayStateShown -or $count -ne $script:TrayCountShown) { $Icon.Icon = Get-NotifierDotIcon $state -Count $count }
        $Icon.Text = Format-NotifierTrayTooltip -Sessions $Sessions
    }
    $script:TrayStateShown = $state
    $script:TrayCountShown = $count
    return $state
}

# --- Карточки сеансов ---

function ConvertTo-NotifierSessionCard {
    <# .SYNOPSIS Сеанс → карточка: проект, статус цветом, где идёт, сколько, превью ответа. #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow, [hashtable]$Prefs = @{}, [int]$ContextWarn = 85)
    $card = New-Object ClaudeNotifier.Ui.CardItem
    $card.Id = [string]$Session.session_id
    $card.Title = Get-NotifierSessionName -Session $Session -Prefs $Prefs
    $card.State = [string]$Session.state
    $card.StateText = Get-NotifierSessionStateText ([string]$Session.state)
    $agentsText = Get-NotifierAgentsStateText $Session
    if ($agentsText) { $card.StateText = $agentsText }
    $card.Meta = 'Терминал'
    if ([string]$Session.origin -eq 'desktop') { $card.Meta = 'Приложение' }
    # Сеанс переименован — имя проекта остаётся видно во второй строке.
    if ($card.Title -ne [string]$Session.project -and [string]$Session.project -ne '') { $card.Meta += " $([char]0x00B7) $([string]$Session.project)" }
    if ($Prefs.ContainsKey($card.Id)) { $card.Pinned = [bool]$Prefs[$card.Id].pinned; $card.Muted = [bool]$Prefs[$card.Id].muted }
    $card.ContextWarn = $ContextWarn
    if ($Session.PSObject.Properties['stats'] -and $Session.stats -and $Session.stats.PSObject.Properties['window']) { $card.ContextPercent = [int]$Session.stats.percent }
    $deviceId = ''
    if ($Session.PSObject.Properties['device']) { $deviceId = [string]$Session.device }
    $card.Section = Get-NotifierDeviceName $deviceId   # группа списка — устройство, как в Настройках iOS
    $card.Right = Format-NotifierElapsed -Ts ([string]$Session.since) -Now $Now
    # «Работает», но журнал давно молчит — красная точка и сколько уже тишина.
    if ([string]$Session.state -eq 'working' -and $Session.PSObject.Properties['stalledSince'] -and [string]$Session.stalledSince -ne '') {
        $card.State = 'error'
        $card.StateText = 'Похоже, остановился'
        $card.Right = Format-NotifierElapsed -Ts ([string]$Session.stalledSince) -Now $Now
    }
    $card.Preview = ConvertTo-NotifierPlainText ([string]$Session.preview)   # без **, `, # и ссылок
    $card.Tag = $Session
    $card.Details = Format-NotifierSessionDetails -Session $Session -Now $Now -NoAgents
    if ([string]$Session.state -eq 'working') { $card.SubLines = [string[]]@(Format-NotifierAgentLines $Session 3) }   # агенты — подстроками
    $card.Chips = [string[]]@(Get-NotifierSessionChips $Session)
    if ($deviceId -eq '') { Add-NotifierCardRequest -Card $card -Session $Session }   # ответы — для сеансов этого ПК
    # Без запроса — кнопки изменённых файлов и папки проекта (видны, когда карточка раскрыта).
    if ($deviceId -eq '' -and $card.Actions.Length -eq 0) {
        $acts = @()
        $n = @(Get-NotifierSessionFiles $Session).Count
        # Всего изменено (в меню — последние 15).
        if ($n -gt 0 -and $Session.stats.PSObject.Properties['files'] -and [int]$Session.stats.files -gt $n) { $n = [int]$Session.stats.files }
        if ($n -gt 0) { $acts += "files|Изменённые файлы $([char]0x00B7) $n|secondary" }
        if ((Get-NotifierSessionFolder $Session) -ne '') { $acts += 'folder|Папка проекта|secondary' }
        $card.Actions = [string[]]$acts
    }
    return $card
}

function Format-NotifierFilesCount([int]$N) {
    $w = 'файлов'
    if ($N % 10 -eq 1 -and $N % 100 -ne 11) { $w = 'файл' }
    elseif (@(2, 3, 4) -contains ($N % 10) -and @(12, 13, 14) -notcontains ($N % 100)) { $w = 'файла' }
    return "$N $w"
}

function Get-NotifierSessionChips {
    <# .SYNOPSIS Плашки раскрытой карточки: заполненность контекста, стоимость, сколько файлов изменено. #>
    param($Session)
    $chips = @()
    if ($null -eq $Session -or -not $Session.PSObject.Properties['stats'] -or $null -eq $Session.stats) { return $chips }
    $st = $Session.stats
    if ($st.PSObject.Properties['window'] -and [int64]$st.window -gt 0) { $chips += "контекст $([int]$st.percent) %" }
    $cost = 0.0
    foreach ($k in @('cost', 'agentsCost')) { if ($st.PSObject.Properties[$k]) { $cost += [double]$st.$k } }
    if ($cost -gt 0) { $chips += "$([char]0x2248) $(Format-NotifierCost $cost)" }
    if ($st.PSObject.Properties['files'] -and [int]$st.files -gt 0) { $chips += "изменено $(Format-NotifierFilesCount ([int]$st.files))" }
    return $chips
}

function Select-NotifierFilteredSessions {
    <#
    .SYNOPSIS
    Поиск и фильтр списка: Mode — all | me (ждут вас: разрешение, ошибка, ждёт ответа) | work (работают);
    Text — часть имени, проекта, последнего ответа или вашего запроса (без учёта регистра).
    #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [hashtable]$Filter, [hashtable]$Prefs = @{})
    if ($null -eq $Filter) { return $Sessions }
    $text = ([string]$Filter.Text).Trim()
    $mode = [string]$Filter.Mode
    $out = @()
    foreach ($s in $Sessions) {
        $st = [string]$s.state
        if ($mode -eq 'me' -and @('permission', 'error', 'waiting') -notcontains $st) { continue }
        if ($mode -eq 'work' -and $st -ne 'working') { continue }
        if ($text -ne '') {
            $hay = @((Get-NotifierSessionName -Session $s -Prefs $Prefs), [string]$s.project, [string]$s.preview)
            if ($s.PSObject.Properties['prompt']) { $hay += [string]$s.prompt }
            if (-not (@($hay | Where-Object { $_ -and $_.IndexOf($text, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count)) { continue }
        }
        $out += $s
    }
    return $out
}

function Test-NotifierFilterActive([hashtable]$Filter) {
    return ($null -ne $Filter -and (([string]$Filter.Text).Trim() -ne '' -or [string]$Filter.Mode -ne 'all'))
}

function New-NotifierSearchBar {
    <#
    .SYNOPSIS
    Строка над списком сеансов: поле поиска (Ctrl+F, Esc — очистить) и фильтры «Все · Ждут меня · Работают».
    Видна, когда сеансов больше 5 или фильтр включён. Возвращает @{ Panel; Box; Hint; Buttons }.
    #>
    param([Parameter(Mandatory = $true)]$Theme)
    $t = $Theme
    $bar = New-Object System.Windows.Forms.Panel
    $bar.Dock = [System.Windows.Forms.DockStyle]::Top
    $bar.Height = $t.S(44)
    $bar.BackColor = $t.Window
    $bar.Visible = $false
    $field = New-NotifierGroupPanel -Theme $t -Height 32
    $glyph = New-Object System.Windows.Forms.Label
    $glyph.Text = [string][char]0xE721
    $glyph.Font = [ClaudeNotifier.Ui.IconButton]::IconFont(9)
    $glyph.ForeColor = $t.Muted; $glyph.BackColor = $t.Surface
    $glyph.TextAlign = 'MiddleCenter'
    $glyph.SetBounds($t.S(6), 0, $t.S(24), $t.S(32))
    $box = New-Object System.Windows.Forms.TextBox
    $box.BorderStyle = 'None'
    $box.BackColor = $t.Surface; $box.ForeColor = $t.Text
    $box.Font = [ClaudeNotifier.Ui.Fonts]::Text(10)
    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = 'Поиск по сеансам'
    $hint.Font = $box.Font
    $hint.ForeColor = $t.Muted; $hint.BackColor = $t.Surface
    $hint.AutoSize = $true
    $hint.add_Click({ $this.Parent.Controls[2].Focus() })
    $field.Controls.Add($glyph); $field.Controls.Add($hint); $field.Controls.Add($box)
    $box.add_TextChanged({
            $script:SessionFilter.Text = $this.Text
            $this.Parent.Controls[1].Visible = ($this.Text -eq '')
            [void](Invoke-NotifierSessionsRefresh)
        })
    $box.add_KeyDown({
            param($s, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) {
                if ($s.Text -eq '') { $script:SearchOpen = $false; $script:SessionsForm.Tag.Cards.Focus(); [void](Invoke-NotifierSessionsRefresh) }
                $s.Text = ''; $e.Handled = $true; $e.SuppressKeyPress = $true
            }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Down) { $script:SessionsForm.Tag.Cards.Focus(); $e.Handled = $true }
        })
    $bar.Controls.Add($field)
    $buttons = @{}
    foreach ($m in @(@('all', 'Все'), @('me', 'Ждут меня'), @('work', 'Работают'))) {
        $b = New-Object ClaudeNotifier.Ui.Button2
        $b.ApplyTheme($t)
        $b.Text = $m[1]
        $b.Tag = $m[0]
        $b.Style = @('secondary', 'primary')[[int]($m[0] -eq 'all')]
        $b.FitWidth()
        $b.Height = $t.S(30)
        $b.add_Click({ Set-NotifierSessionFilterMode ([string]$this.Tag) })
        $bar.Controls.Add($b)
        $buttons[$m[0]] = $b
    }
    $bar.Tag = @{ Theme = $t; Field = $field; Box = $box; Hint = $hint; Glyph = $glyph; Buttons = $buttons }
    $bar.add_Layout({
            $tg = $this.Tag; $th = $tg.Theme
            $x = $this.ClientSize.Width
            foreach ($k in @('work', 'me', 'all')) {
                $b = $tg.Buttons[$k]
                $x -= $b.Width
                $b.Location = New-Object System.Drawing.Point($x, [int](($th.S(32) - $b.Height) / 2))
                $x -= $th.S(6)
            }
            $tg.Field.SetBounds(0, 0, [Math]::Max($th.S(80), $x - $th.S(4)), $th.S(32))
            $tg.Box.SetBounds($th.S(32), [int](($th.S(32) - $tg.Box.Height) / 2), [Math]::Max($th.S(40), $tg.Field.Width - $th.S(40)), $tg.Box.Height)
            $tg.Hint.Location = New-Object System.Drawing.Point($th.S(31), [int](($th.S(32) - $tg.Hint.Height) / 2))
        })
    return @{ Panel = $bar; Box = $box; Hint = $hint; Buttons = $buttons }
}

function Set-NotifierSessionFilterMode {
    param([ValidateSet('all', 'me', 'work')][string]$Mode)
    $script:SessionFilter.Mode = $Mode
    $form = $script:SessionsForm
    if ($form -and -not $form.IsDisposed -and $form.Tag.Search) {
        foreach ($k in @($form.Tag.Search.Buttons.Keys)) { $form.Tag.Search.Buttons[$k].Style = @('secondary', 'primary')[[int]($k -eq $Mode)] }
    }
    [void](Invoke-NotifierSessionsRefresh)
}

function Show-NotifierSearch {
    <# .SYNOPSIS Ctrl+F в окне: показать строку поиска и поставить курсор в поле. #>
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed -or $form.Tag.Tabs.SelectedIndex -ne 0) { return }
    $script:SearchOpen = $true
    $form.Tag.Search.Panel.Visible = $true
    [void]$form.Tag.Search.Box.Focus()
}

function Update-NotifierSessionsView {
    <#
    .SYNOPSIS
    Заполняет список карточек сеансов (порядок: ждут вас → работают). Возвращает подзаголовок окна.
    #>
    param(
        [Parameter(Mandatory = $true)]$Cards,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [datetime]$Now = [DateTime]::UtcNow,
        [hashtable]$Filter = $null   # поиск и фильтр (окно); $null — все сеансы (мини-окно)
    )
    # Группы по устройствам: сначала группа, где самый «срочный» сеанс; внутри группы — порядок срочности.
    # foreach, а не конвейер: Get-NotifierSortedSessions возвращает массив одним объектом.
    $prefs = @{}
    $warn = 85
    if ($script:TrayDataRoot) {
        $prefs = Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot
        $cfg = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $warn = [int]$cfg.context.warnPercent
        $script:RemindMinutes = [int]$cfg.approvals.remindMinutes
    }
    $minGroup = 4
    $inactiveHours = 2
    if ($script:TrayDataRoot) {
        $minGroup = 0; if ($cfg.groups.enabled) { $minGroup = [int]$cfg.groups.minSessions }
        $inactiveHours = 0; if ($cfg.inactive.enabled) { $inactiveHours = [int]$cfg.inactive.hours }
    }
    $pinned = @($prefs.Keys | Where-Object { $prefs[$_].pinned })
    $all = $Sessions
    $filtered = Test-NotifierFilterActive $Filter
    if ($filtered) {
        $Sessions = @(Select-NotifierFilteredSessions -Sessions $Sessions -Filter $Filter -Prefs $prefs)
        $Cards.EmptyTitle = 'Ничего не найдено'; $Cards.EmptyHint = 'Измените запрос или выберите «Все».'
    }
    elseif ($Cards.EmptyTitle -eq 'Ничего не найдено') {
        $Cards.EmptyTitle = 'Активных сеансов нет'
        $Cards.EmptyHint = 'Сеанс появится здесь, как только вы начнёте работу в Claude Code — на этом ПК или на подключённом Mac.'
    }
    $cardsSorted = @(foreach ($x in (Get-NotifierSortedSessions -Sessions $Sessions -Pinned $pinned)) { ConvertTo-NotifierSessionCard -Session $x -Now $Now -Prefs $prefs -ContextWarn $warn })
    $Cards.SetItems((Get-NotifierGroupedCards -Cards $cardsSorted -MinSessions $minGroup -InactiveHours $inactiveHours -Now $Now))
    if ($filtered) { return "Показано $(@($Sessions).Count) из $(@($all).Count)" }
    return (Format-NotifierSessionsSubtitle -Sessions $Sessions)
}

function Get-NotifierCardSession {
    <# .SYNOPSIS Сеанс карточки (у карточки с запросом Tag = @{ Session; Request }); у строки-группы — $null. #>
    param([Parameter(Mandatory = $true)]$Card)
    $s = $Card.Tag
    if ($s -is [hashtable]) { if ($s.ContainsKey('Session')) { return $s.Session }; return $null }
    return $s
}

function Format-NotifierSessionCount([int]$N) {
    $w = 'сеансов'
    if ($N % 10 -eq 1 -and $N % 100 -ne 11) { $w = 'сеанс' }
    elseif (@(2, 3, 4) -contains ($N % 10) -and @(12, 13, 14) -notcontains ($N % 100)) { $w = 'сеанса' }
    return "$N $w"
}

function New-NotifierGroupCard {
    <# .SYNOPSIS Строка-группа: проект, сколько сеансов и в каких статусах; точка — самый срочный статус. #>
    param([string]$Key, [string]$Section, [string]$Project, [object[]]$Members, [bool]$Open)
    $g = New-Object ClaudeNotifier.Ui.CardItem
    $g.Id = "group:$Key"
    $g.Section = $Section
    $g.Title = $Project
    $g.IsGroup = $true
    $g.GroupOpen = $Open
    $g.NeutralState = $true
    $g.Tag = @{ Group = $Key }
    $states = @($Members | ForEach-Object { [string]$_.State })
    foreach ($st in @('permission', 'error', 'waiting', 'working')) { if ($states -contains $st) { $g.State = $st; break } }
    $g.StateText = Format-NotifierSessionCount $Members.Count
    $parts = @()
    foreach ($st in @('permission', 'error', 'waiting', 'working')) {
        $n = @($Members | Where-Object { [string]$_.State -eq $st }).Count
        if ($n -gt 0) { $parts += "$(Get-NotifierSessionStateText $st) $n" }
    }
    $g.Meta = $parts -join " $([char]0x00B7) "
    return $g
}

function Get-NotifierGroupedCards {
    <#
    .SYNOPSIS
    Карточки по группам-устройствам; если сеансов не меньше MinSessions, сеансы одного проекта на одном устройстве
    сворачиваются в строку-группу. Свёрнутая группа всё равно показывает сеансы, которые ждут решения (запрос, ошибка);
    закреплённые сеансы в группы не попадают. MinSessions = 0 — без групп.
    Сеансы «Ждёт ответа» дольше InactiveHours часов (0 — не собирать) — в конце своей группы-устройства строкой
    «Неактивные»; раскрытая, она показывает их и кнопку «Убрать все из списка».
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Cards, [int]$MinSessions = 4, [hashtable]$Expanded = $script:ExpandedGroups,
        [double]$InactiveHours = 0, [datetime]$Now = [DateTime]::UtcNow)
    if ($null -eq $Expanded) { $Expanded = @{} }
    $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
    $order = New-Object System.Collections.ArrayList
    foreach ($c in $Cards) { if (-not $order.Contains($c.Section)) { [void]$order.Add($c.Section) } }
    # Неактивные: ждут ответа давно, не закреплены и без запроса.
    $idle = @{}
    if ($InactiveHours -gt 0) {
        foreach ($c in $Cards) {
            $s = Get-NotifierCardSession $c
            if ($null -eq $s -or $c.Pinned -or $c.ForceExpand -or [string]$c.State -ne 'waiting') { continue }
            $since = ConvertTo-NotifierUtc ([string]$s.since)
            if ($null -ne $since -and ($Now - $since).TotalHours -ge $InactiveHours) { $idle[$c.Id] = $true }
        }
    }
    $all = $Cards
    $Cards = @($Cards | Where-Object { -not $idle.ContainsKey($_.Id) })
    $grouping = $MinSessions -gt 0 -and $Cards.Count -ge $MinSessions
    $keyOf = { param($c) $s = Get-NotifierCardSession $c; if ($null -eq $s -or $c.Pinned -or [string]$s.project -eq '') { return '' }; return "$($c.Section)|$([string]$s.project)" }
    $members = @{}
    if ($grouping) {
        foreach ($c in $Cards) {
            $k = & $keyOf $c
            if ($k -eq '') { continue }
            if (-not $members.ContainsKey($k)) { $members[$k] = New-Object System.Collections.ArrayList }
            [void]$members[$k].Add($c)
        }
    }
    foreach ($section in $order) {
        $done = @{}
        foreach ($c in $Cards) {
            if ($c.Section -ne $section) { continue }
            $k = ''
            if ($grouping) { $k = & $keyOf $c }
            if ($k -eq '' -or $members[$k].Count -lt 2) { $list.Add($c); continue }
            if ($done.ContainsKey($k)) { continue }
            $done[$k] = $true
            $open = $Expanded.ContainsKey($k)
            $list.Add((New-NotifierGroupCard -Key $k -Section $section -Project ([string](Get-NotifierCardSession $c).project) -Members @($members[$k]) -Open $open))
            foreach ($m in $members[$k]) {
                $needs = $m.ForceExpand -or @('permission', 'error') -contains [string]$m.State
                if ($open -or $needs) { $m.Child = $true; $list.Add($m) }
            }
        }
        $sectionIdle = @($all | Where-Object { $_.Section -eq $section -and $idle.ContainsKey($_.Id) })
        if ($sectionIdle.Count -gt 0) {
            $k = "inactive|$section"
            $open = $Expanded.ContainsKey($k)
            $g = New-Object ClaudeNotifier.Ui.CardItem
            $g.Id = "group:$k"; $g.Section = $section; $g.Title = 'Неактивные'
            $g.IsGroup = $true; $g.GroupOpen = $open; $g.HollowDot = $true; $g.State = 'waiting'; $g.NeutralState = $true
            $g.StateText = Format-NotifierSessionCount $sectionIdle.Count
            $g.Meta = "ждут ответа дольше $InactiveHours ч"
            $g.Tag = @{ Group = $k; Ids = @($sectionIdle | ForEach-Object { $_.Id }) }
            if ($open) { $g.ForceExpand = $true; $g.Actions = [string[]]@('clear|Убрать все из списка|destructive') }
            $list.Add($g)
            if ($open) { foreach ($m in $sectionIdle) { $m.Child = $true; $list.Add($m) } }
        }
    }
    return , $list
}

function Switch-NotifierSessionGroup {
    <# .SYNOPSIS Щелчок по строке-группе: раскрыть или свернуть. #>
    param([Parameter(Mandatory = $true)]$Item)
    $k = [string]$Item.Tag.Group
    if ($script:ExpandedGroups.ContainsKey($k)) { $script:ExpandedGroups.Remove($k) } else { $script:ExpandedGroups[$k] = $true }
}

function Format-NotifierSessionsSubtitle {
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $n = @($Sessions).Count
    if ($n -eq 0) { return 'Нет активных сеансов' }
    $need = @($Sessions | Where-Object { $_.state -eq 'permission' -or $_.state -eq 'error' }).Count
    $word = 'активных'
    if ($n % 10 -eq 1 -and $n % 100 -ne 11) { $word = 'активный' }
    $text = "$n $word"
    if ($need -gt 0) { $text += " $([char]0x00B7) требуют внимания: $need" }
    return $text
}

function Show-NotifierNotice {
    <# .SYNOPSIS Временная подсказка под заголовком окна (4 с). #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $form.Tag.Subtitle.Text = $Text
    $script:NoticeUntil = [datetime]::UtcNow.AddSeconds(4)
}

function Invoke-NotifierSessionsRefresh {
    <#
    .SYNOPSIS
    Перечитывает sessions.json, убирает завершившиеся сеансы, обновляет точку в трее и открытое окно.
    Возвращает список живых сеансов.
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    try { [void](Update-NotifierPending -DataRoot $DataRoot) } catch { }
    $all = @(Get-NotifierSessions -DataRoot $DataRoot)
    $live = Select-NotifierLiveSessions -Sessions $all   # уже массив; @() вложил бы его в ещё один
    if ($live.Count -ne $all.Count) { Save-NotifierSessions -Sessions $live -DataRoot $DataRoot }
    try { Invoke-NotifierReminders -Sessions $live -DataRoot $DataRoot } catch { Write-NotifierLog -Level WARN -Message "tray: напоминания: $($_.Exception.Message)" -DataRoot $DataRoot }
    $script:SessionsDirty = $false
    $script:SessionsRefreshedAt = [datetime]::UtcNow
    try { [void](Update-NotifierTrayStatus -Sessions $live) } catch { }
    try { Update-NotifierPopover -Sessions $live } catch { }
    try { Update-NotifierNotch -Sessions $live } catch { Write-NotifierLog -Level WARN -Message "tray: шторка: $($_.Exception.Message)" -DataRoot $DataRoot }
    try { Update-NotifierUsageViews } catch { }
    $form = $script:SessionsForm
    if ($form -and -not $form.IsDisposed) {
        $subtitle = Update-NotifierSessionsView -Cards $form.Tag.Cards -Sessions $live -Filter $script:SessionFilter
        if ($form.Tag.Search) {
            $show = $form.Tag.Tabs.SelectedIndex -eq 0 -and ($live.Count -gt 5 -or (Test-NotifierFilterActive $script:SessionFilter) -or $script:SearchOpen)
            if ($form.Tag.Search.Panel.Visible -ne $show) { $form.Tag.Search.Panel.Visible = $show }
        }
        if ($form.Tag.Net) {
            Update-NotifierDevicesView -Ui $form.Tag.Net -Sessions $live
            if ($form.Tag.Tabs.SelectedIndex -eq 1) { $subtitle = Format-NotifierDevicesSubtitle }
            if ($form.Tag.Tabs.SelectedIndex -eq 2) { $subtitle = 'Уведомления, ответы из приложения и запуск' }
            if ($form.Tag.Tabs.SelectedIndex -eq 3) { $subtitle = Format-NotifierStatsSubtitle }
        }
        if ([datetime]::UtcNow -ge $script:NoticeUntil) { $form.Tag.Subtitle.Text = $subtitle }
    }
    return , $live
}

function Remove-NotifierSession {
    <# .SYNOPSIS Убирает сеанс из sessions.json по session_id. #>
    param([Parameter(Mandatory = $true)][string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    $rest = @(Get-NotifierSessions -DataRoot $DataRoot | Where-Object { [string]$_.session_id -ne $SessionId })
    Save-NotifierSessions -Sessions $rest -DataRoot $DataRoot
    $script:SessionsDirty = $true
}

function Invoke-NotifierSessionFocus {
    <#
    .SYNOPSIS
    Выводит на передний план окно сеанса. Если окно закрыто — сеанс убирается из списка.

    .OUTPUTS
    'focused' | 'flashed' | 'closed' | 'unknown' (окно сеанса не определено).
    #>
    param([Parameter(Mandatory = $true)]$Session, [string]$DataRoot = $script:TrayDataRoot)
    $hwnd = [int64]0
    $win = $Session.PSObject.Properties['window']
    if ($win -and $win.Value -and $win.Value.PSObject.Properties['hwnd']) { $hwnd = [int64]$win.Value.hwnd }
    if ($hwnd -eq 0) { return 'unknown' }
    $result = Set-SessionWindowFocus -Hwnd $hwnd
    if ($result -eq 'closed') { Remove-NotifierSession -SessionId ([string]$Session.session_id) -DataRoot $DataRoot }
    return $result
}

function Invoke-NotifierSelectedSession {
    # Действие над выделенной карточкой: focus | remove.
    param([Parameter(Mandatory = $true)][ValidateSet('focus', 'remove')][string]$Action)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $item = $form.Tag.Cards.SelectedItem
    if ($null -eq $item) { return }
    $session = $item.Tag
    if ($session -is [hashtable]) { $session = $session.Session }   # у карточки с запросом Tag = @{ Session; Request }
    if ($Action -eq 'remove') { Remove-NotifierSession -SessionId ([string]$session.session_id) }
    elseif ($session.PSObject.Properties['device'] -and [string]$session.device -ne '') {
        Show-NotifierNotice "Этот сеанс идёт на устройстве «$(Get-NotifierDeviceName ([string]$session.device))»"
        return
    }
    else {
        $result = Invoke-NotifierSessionFocus -Session $session
        if ($result -eq 'unknown') { Show-NotifierNotice 'Окно этого сеанса не определено'; return }
        if ($result -eq 'closed') { Show-NotifierNotice 'Окно сеанса закрыто — сеанс убран из списка' }
    }
    [void](Invoke-NotifierSessionsRefresh)
}

# --- Общие элементы окна ---

function New-NotifierMenu {
    <# .SYNOPSIS Контекстное меню в цветах темы. Items: @(@('Текст', { действие }), '-', …). #>
    param([Parameter(Mandatory = $true)]$Theme, [object[]]$Items = @())
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object ClaudeNotifier.Ui.MenuRenderer($Theme)
    $menu.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
    $menu.ShowImageMargin = $false
    $menu.Padding = New-Object System.Windows.Forms.Padding(0, $Theme.S(4), 0, $Theme.S(4))
    # Меню и выпадающие списки — выше шторки (она тоже «поверх всех»).
    $menu.add_Opened({ [ClaudeNotifier.Ui.Native]::RoundPopup($this.Handle); [ClaudeNotifier.Ui.Native]::BringToTop($this.Handle) })
    foreach ($i in $Items) {
        if ($i -is [string] -and $i -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem $i[0]
        $mi.Padding = New-Object System.Windows.Forms.Padding($Theme.S(8), $Theme.S(5), $Theme.S(8), $Theme.S(5))
        if ($i[1]) { $mi.add_Click($i[1]) }
        [void]$menu.Items.Add($mi)
    }
    return $menu
}

function New-NotifierLabel {
    <# .SYNOPSIS Подпись в цветах темы фиксированной ширины; высота — по тексту. #>
    param(
        [Parameter(Mandatory = $true)]$Theme,
        [AllowEmptyString()][string]$Text = '',
        [System.Drawing.Font]$Font,
        [int]$Width = 0,
        [switch]$Muted,
        [switch]$Wrap,
        [string]$Dot
    )
    $l = New-Object ClaudeNotifier.Ui.Label2
    $l.ApplyTheme($Theme)
    if ($Font) { $l.Font = $Font }
    $l.MutedText = [bool]$Muted
    $l.Wrap = [bool]$Wrap
    if ($Dot) { $l.DotState = $Dot }
    $l.Text = $Text
    if ($Width -le 0) { $Width = $l.GetPreferredSize([System.Drawing.Size]::Empty).Width + 2 }
    $l.Size = New-Object System.Drawing.Size($Width, ($l.GetPreferredSize((New-Object System.Drawing.Size($Width, 0))).Height + 2))
    return $l
}

function New-NotifierButton {
    <# .SYNOPSIS Кнопка-капсула: -Primary (акцент), -Plain (текст акцента), -Destructive (красный текст) или обычная. #>
    param([Parameter(Mandatory = $true)]$Theme, [Parameter(Mandatory = $true)][string]$Text, [switch]$Primary, [switch]$Plain, [switch]$Destructive, [scriptblock]$OnClick, [int]$Width = 0)
    $b = New-Object ClaudeNotifier.Ui.Button2
    $style = 'secondary'
    if ($Primary) { $style = 'primary' } elseif ($Plain) { $style = 'plain' } elseif ($Destructive) { $style = 'destructive' }
    $b.Style = $style
    $b.ApplyTheme($Theme)
    $b.Text = $Text
    $b.FitWidth()
    if ($Width -gt 0) { $b.Width = $Width }
    if ($OnClick) { $b.add_Click($OnClick) }
    return $b
}

function New-NotifierIconButton {
    <# .SYNOPSIS Круглая кнопка-иконка (Segoe Fluent Icons) с подсказкой. #>
    param([Parameter(Mandatory = $true)]$Theme, [Parameter(Mandatory = $true)][string]$Glyph, [string]$Tip = '', [scriptblock]$OnClick)
    $b = New-Object ClaudeNotifier.Ui.IconButton
    $b.ApplyTheme($Theme)
    $b.Glyph = $Glyph
    $b.BackColor = $Theme.Window
    if ($Tip) { $tt = New-Object System.Windows.Forms.ToolTip; $tt.SetToolTip($b, $Tip); $b.Tag = $tt }
    if ($OnClick) { $b.add_Click($OnClick) }
    return $b
}

function Switch-NotifierPage {
    <# .SYNOPSIS Иконка в заголовке: открыть страницу; повторный щелчок — вернуться к сеансам. #>
    param([Parameter(Mandatory = $true)][int]$Index)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    if ($form.Tag.Tabs.SelectedIndex -eq $Index) { $form.Tag.Tabs.SelectedIndex = 0 } else { $form.Tag.Tabs.SelectedIndex = $Index }
}

function New-NotifierUsagePanel {
    <#
    .SYNOPSIS
    Карточка внизу окна: две полосы расхода — пятичасовой и недельный лимиты. Возвращает @{ Panel; Five; Week }.
    #>
    param([Parameter(Mandatory = $true)]$Theme, [switch]$Compact)
    $t = $Theme
    $outer = New-Object System.Windows.Forms.Panel
    $outer.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $outer.BackColor = $t.Window
    $outer.Padding = New-Object System.Windows.Forms.Padding(0, $t.S(14), 0, 0)
    $card = New-NotifierGroupPanel -Theme $t -Height 96
    $card.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Padding = New-Object System.Windows.Forms.Padding($t.S(16), $t.S(12), $t.S(16), $t.S(10))
    $five = New-Object ClaudeNotifier.Ui.UsageBar
    $five.ApplyTheme($t); $five.Label = '5 часов'; $five.BackColor = $t.Surface; $five.Dock = [System.Windows.Forms.DockStyle]::Top
    $gap = New-Object System.Windows.Forms.Panel
    $gap.Height = $t.S(8); $gap.Dock = [System.Windows.Forms.DockStyle]::Top; $gap.BackColor = $t.Surface
    $week = New-Object ClaudeNotifier.Ui.UsageBar
    $week.ApplyTheme($t); $week.Label = 'Неделя'; $week.BackColor = $t.Surface; $week.Dock = [System.Windows.Forms.DockStyle]::Top
    $card.Controls.Add($week); $card.Controls.Add($gap); $card.Controls.Add($five)
    $outer.Controls.Add($card)
    $outer.Height = $t.S(14) + $t.S(12) + $five.Height + $gap.Height + $week.Height + $t.S(12)
    return @{ Panel = $outer; Five = $five; Week = $week; Gap = $gap; Theme = $t; Compact = $false }
}

function Set-NotifierUsageCompact {
    <# .SYNOPSIS Нет данных о расходе — одна строка «Лимиты Claude» вместо двух пустых полос; есть данные — обе полосы. #>
    param([Parameter(Mandatory = $true)]$Usage, [bool]$Compact)
    if ($Usage.Compact -eq $Compact) { return }
    $Usage.Compact = $Compact
    $t = $Usage.Theme
    $Usage.Week.Visible = -not $Compact
    $Usage.Gap.Visible = -not $Compact
    $Usage.Five.Label = @('5 часов', 'Лимиты Claude')[[int]$Compact]
    $h = $t.S(14) + $t.S(12) + $Usage.Five.Height + $t.S(12)
    if (-not $Compact) { $h += $Usage.Gap.Height + $Usage.Week.Height }
    $Usage.Panel.Height = $h
}

function Update-NotifierUsageViews {
    <# .SYNOPSIS Обновляет полосы расхода в окне и мини-окне из usage.json. #>
    $usage = Get-NotifierUsage -DataRoot $script:TrayDataRoot
    $targets = @()
    if ($script:SessionsForm -and -not $script:SessionsForm.IsDisposed -and $script:SessionsForm.Tag.Usage) { $targets += $script:SessionsForm.Tag.Usage }
    if ($script:Popover -and -not $script:Popover.IsDisposed -and $script:Popover.Tag.Usage) { $targets += $script:Popover.Tag.Usage }
    foreach ($u in $targets) {
        $f = Format-NotifierUsageWindow -Usage $usage -Window five_hour
        $w = Format-NotifierUsageWindow -Usage $usage -Window seven_day
        if ($null -eq $usage) { $f.Detail = 'нет данных — войдите в Claude Code CLI'; $w.Detail = 'нет данных' }
        if ($u.ContainsKey('Gap')) { Set-NotifierUsageCompact -Usage $u -Compact ($null -eq $usage) }
        $u.Five.SetValue([double]$f.Percent, [string]$f.Detail)
        $u.Week.SetValue([double]$w.Percent, [string]$w.Detail)
    }
}

function Get-NotifierAppScreen {
    <#
    .SYNOPSIS
    Монитор, где сейчас приложение: шторки (если она работает), иначе окна «Сеансы» (если открыто), иначе тот,
    где курсор. Сюда открываются диалоги и окна приложения.
    #>
    try {
        if (Test-NotifierNotchActive) { return (Get-NotifierNotchScreen -Config (Get-NotifierConfig -DataRoot $script:TrayDataRoot)) }
    }
    catch { }
    if ($script:SessionsForm -and -not $script:SessionsForm.IsDisposed -and $script:SessionsForm.Visible) { return [System.Windows.Forms.Screen]::FromControl($script:SessionsForm) }
    return [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
}

function Set-NotifierFormPlacement {
    <#
    .SYNOPSIS
    Где открыть окно (при Load, размер уже известен): над видимым окном-владельцем, иначе по центру монитора
    приложения (Get-NotifierAppScreen). Окно не выходит за рабочую область монитора.
    #>
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form, $Screen = $null)
    $o = $Form.Owner
    if ($o -and -not $o.IsDisposed -and $o.Visible -and $o.WindowState -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        $wa = [System.Windows.Forms.Screen]::FromControl($o).WorkingArea
        $cx = $o.Left + ($o.Width - $Form.Width) / 2; $cy = $o.Top + ($o.Height - $Form.Height) / 2
    }
    else {
        if ($null -eq $Screen) { $Screen = Get-NotifierAppScreen }
        $wa = $Screen.WorkingArea
        $cx = $wa.X + ($wa.Width - $Form.Width) / 2; $cy = $wa.Y + ($wa.Height - $Form.Height) / 3   # чуть выше центра, как системные диалоги
    }
    $x = [int][Math]::Max($wa.X, [Math]::Min($cx, $wa.Right - $Form.Width))
    $y = [int][Math]::Max($wa.Y, [Math]::Min($cy, $wa.Bottom - $Form.Height))
    $Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $Form.Location = New-Object System.Drawing.Point($x, $y)
}

function Show-NotifierFileDialog {
    <#
    .SYNOPSIS
    Окно выбора файла (Open/SaveFileDialog) на мониторе приложения. Без владельца Windows открывает его на основном
    мониторе, поэтому владелец — невидимое окно по центру монитора приложения (или переданный Owner).
    #>
    param([Parameter(Mandatory = $true)][System.Windows.Forms.CommonDialog]$Dialog, [System.Windows.Forms.IWin32Window]$Owner)
    if ($Owner) { return $Dialog.ShowDialog($Owner) }
    $wa = (Get-NotifierAppScreen).WorkingArea
    $anchor = New-Object System.Windows.Forms.Form
    $anchor.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $anchor.ShowInTaskbar = $false
    $anchor.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $anchor.Opacity = 0
    $anchor.TopMost = $true   # выбор файла — поверх шторки
    $anchor.Bounds = New-Object System.Drawing.Rectangle(($wa.X + [int]($wa.Width / 2) - 1), ($wa.Y + [int]($wa.Height / 3)), 2, 2)
    try { $anchor.Show(); return $Dialog.ShowDialog($anchor) }
    finally { $anchor.Dispose() }
}

function New-NotifierForm {
    <# .SYNOPSIS Окно в цветах темы: фон, заголовок Windows 11 в тон, иконка-точка. #>
    param([Parameter(Mandatory = $true)]$Theme, [AllowEmptyString()][string]$Title = '', [int]$Width = 520, [int]$Height = 600, [switch]$Chrome)
    if ($Chrome) {
        # Свой заголовок в стиле macOS: системная полоса убрана, рамка, тень и Snap остаются.
        $f = New-Object ClaudeNotifier.Ui.ChromeForm
        $f.CaptionHeight = $Theme.S(40)
    }
    else { $f = New-Object System.Windows.Forms.Form }
    $f.Text = $Title
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.BackColor = $Theme.Window
    $f.ForeColor = $Theme.Text
    $f.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
    $f.ClientSize = New-Object System.Drawing.Size($Theme.S($Width), $Theme.S($Height))
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    # Окно — там же, где приложение (монитор шторки), а не на основном мониторе (так ставит Windows без видимого владельца).
    $f.add_Load({ Set-NotifierFormPlacement -Form $this })
    $appIcon = Join-Path $PSScriptRoot 'assets\icon.ico'
    if (Test-Path -LiteralPath $appIcon) { $f.Icon = New-Object System.Drawing.Icon $appIcon }   # иконка приложения в заголовке и на панели задач
    $f.Tag = @{ Theme = $Theme }
    $f.add_HandleCreated({ [ClaudeNotifier.Ui.Native]::StyleWindow($this.Handle, $this.Tag.Theme) })
    [ClaudeNotifier.Ui.Native]::FadeIn($f, 180)   # окно открывают редко — плавное появление уместно
    return $f
}

function Show-NotifierDialog {
    <#
    .SYNOPSIS
    Диалог в стиле алерта Apple: заголовок и текст по центру, необязательное поле ввода,
    кнопки одинаковой ширины (отмена слева, действие справа). -Destructive — действие красным.
    Возвращает @{ Ok = $true/$false; Value = <текст поля> }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [AllowEmptyString()][string]$Message = '',
        [string]$Primary = 'OK',
        [string]$Secondary = 'Отмена',
        $InputValue = $null,   # без типа: [string] превратил бы $null в '' и показал бы поле ввода
        [switch]$Destructive,
        [System.Windows.Forms.IWin32Window]$Owner
    )
    $t = Get-NotifierTheme
    $w = 360
    $f = New-NotifierForm -Theme $t -Title '' -Width $w -Height 200
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.ShowIcon = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $pad = $t.S(24); $inner = $t.S($w) - 2 * $pad
    $y = $t.S(8)
    $head = New-NotifierLabel -Theme $t -Text $Title -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(12)) -Width $inner -Wrap
    $head.Center = $true
    $head.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($head); $y += $head.Height + $t.S(6)
    if ($Message) {
        $msg = New-NotifierLabel -Theme $t -Text $Message -Width $inner -Wrap -Muted
        $msg.Center = $true
        $msg.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($msg); $y += $msg.Height + $t.S(4)
    }
    $box = $null
    if ($null -ne $InputValue) {
        $y += $t.S(10)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Text = [string]$InputValue
        $box.Font = [ClaudeNotifier.Ui.Fonts]::Text(11)
        $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $box.BackColor = $t.Surface; $box.ForeColor = $t.Text
        # Поле в скруглённой «капсуле»: TextBox без рамки внутри панели, которая рисует фон.
        $field = New-Object System.Windows.Forms.Panel
        $field.Size = New-Object System.Drawing.Size($inner, $t.S(38))
        $field.BackColor = $t.Window
        $field.Tag = $t
        $field.add_Paint({
                param($sender, $e)
                $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                [ClaudeNotifier.Ui.Draw]::Card($e.Graphics, (New-Object System.Drawing.RectangleF(0.5, 0.5, ($sender.Width - 1), ($sender.Height - 1))), $sender.Tag.S(9), $sender.Tag.Surface, $sender.Tag.Border)
            })
        $box.Width = $inner - $t.S(24)
        $box.Location = New-Object System.Drawing.Point($t.S(12), [int](($field.Height - $box.PreferredHeight) / 2))
        $field.Controls.Add($box)
        $field.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($field); $y += $field.Height
    }
    $y += $t.S(20)
    $gap = $t.S(10)
    $btnW = $inner
    if ($Secondary) { $btnW = [int](($inner - $gap) / 2) }
    if ($Destructive) { $ok = New-NotifierButton -Theme $t -Text $Primary -Destructive -Width $btnW }
    else { $ok = New-NotifierButton -Theme $t -Text $Primary -Primary -Width $btnW }
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(($pad + $inner - $ok.Width), $y)
    $f.Controls.Add($ok)
    if ($Secondary) {
        $cancel = New-NotifierButton -Theme $t -Text $Secondary -Width $btnW
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $cancel.Location = New-Object System.Drawing.Point($pad, $y)
        $f.Controls.Add($cancel)
        $f.CancelButton = $cancel
    }
    $f.AcceptButton = $ok
    $f.ClientSize = New-Object System.Drawing.Size($t.S($w), ($y + $ok.Height + $t.S(20)))
    $f.TopMost = $true   # поверх мини-окна у трея
    $f.Tag.Box = $box
    if ($box) { $f.add_Shown({ $this.Tag.Box.SelectAll(); [void]$this.Tag.Box.Focus() }) }
    try {
        $result = $f.ShowDialog($Owner)
        $value = $null
        if ($box) { $value = $box.Text }
        return @{ Ok = ($result -eq [System.Windows.Forms.DialogResult]::OK); Value = $value }
    }
    finally { $f.Dispose() }
}

# --- Окно «Сеансы» ---

function New-NotifierSessionsForm {
    <# .SYNOPSIS Окно: заголовок, подзаголовок, вкладки «Сеансы» / «Устройства», карточки. #>
    $t = Get-NotifierTheme
    $form = New-NotifierForm -Theme $t -Title 'Claude Notifier' -Width 560 -Height 660 -Chrome
    $form.MinimumSize = New-Object System.Drawing.Size($t.S(420), $t.S(440))
    $form.Padding = New-Object System.Windows.Forms.Padding(0)

    # Строка заголовка в стиле Windows 11: слева «Назад», «Устройства», «Настройки»; справа кнопки окна
    # «Свернуть / Развернуть / Закрыть»; пустое место перетаскивает окно.
    $caption = New-Object ClaudeNotifier.Ui.CaptionPanel
    $caption.Dock = [System.Windows.Forms.DockStyle]::Top
    $caption.Height = $t.S(40)
    $caption.BackColor = $t.Window
    $winButtons = New-Object ClaudeNotifier.Ui.CaptionButtons
    $winButtons.ApplyTheme($t, $caption.Height)
    $winButtons.BackColor = $t.Window
    $winButtons.Dock = [System.Windows.Forms.DockStyle]::Right
    $back = New-NotifierIconButton -Theme $t -Glyph ([string][char]0xE72B) -Tip 'Назад к сеансам' -OnClick { $script:SessionsForm.Tag.Tabs.SelectedIndex = 0 }
    $btnStats = New-NotifierIconButton -Theme $t -Glyph ([string][char]0xE9D2) -Tip 'Статистика' -OnClick { Switch-NotifierPage 3 }
    $btnDevices = New-NotifierIconButton -Theme $t -Glyph ([string][char]0xE772) -Tip 'Устройства' -OnClick { Switch-NotifierPage 1 }
    $btnSettings = New-NotifierIconButton -Theme $t -Glyph ([string][char]0xE713) -Tip 'Настройки' -OnClick { Switch-NotifierPage 2 }
    $y = [int](($caption.Height - $btnDevices.Height) / 2)
    $back.Location = New-Object System.Drawing.Point($t.S(8), $y)
    $back.Visible = $false
    $btnStats.Location = New-Object System.Drawing.Point($t.S(8), $y)
    $btnDevices.Location = New-Object System.Drawing.Point(($btnStats.Right + $t.S(4)), $y)
    $btnSettings.Location = New-Object System.Drawing.Point(($btnDevices.Right + $t.S(4)), $y)
    $caption.Controls.AddRange(@($back, $btnStats, $btnDevices, $btnSettings, $winButtons))
    $caption.Tag = @{ Back = $back; Stats = $btnStats; Devices = $btnDevices; Settings = $btnSettings; Theme = $t }
    # Стрелка «Назад» появляется слева на подстраницах — иконки сдвигаются вправо.
    $back.add_VisibleChanged({
            $tg = $this.Parent.Tag
            $x = $tg.Theme.S(8)
            if ($this.Visible) { $x = $this.Right + $tg.Theme.S(4) }
            $tg.Stats.Left = $x
            $tg.Devices.Left = $tg.Stats.Right + $tg.Theme.S(4)
            $tg.Settings.Left = $tg.Devices.Right + $tg.Theme.S(4)
        })

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = $t.S(82)
    $header.BackColor = $t.Window
    $header.Padding = New-Object System.Windows.Forms.Padding($t.S(4), 0, 0, 0)
    # Крупный заголовок (Large Title) и подзаголовок — иерархия весом, размером и цветом.
    $title = New-NotifierLabel -Theme $t -Text 'Сеансы' -Font ([ClaudeNotifier.Ui.Fonts]::Display(22)) -Width $t.S(480)
    $title.Location = New-Object System.Drawing.Point($t.S(4), 0)
    $subtitle = New-NotifierLabel -Theme $t -Text '' -Muted -Width $t.S(480)
    $subtitle.Location = New-Object System.Drawing.Point($t.S(4), ($title.Bottom))
    $subtitle.Anchor = 'Top, Left, Right'
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)

    # Страницы переключают иконки в заголовке; Tabs остаётся невидимым носителем номера страницы.
    $tabs = New-Object ClaudeNotifier.Ui.Tabs
    $tabs.SetTitles('Сеансы', 'Устройства', 'Настройки', 'Статистика')

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = [System.Windows.Forms.DockStyle]::Top
    $spacer.Height = $t.S(18)
    $spacer.BackColor = $t.Window

    $cards = New-Object ClaudeNotifier.Ui.CardList
    $cards.ApplyTheme($t)
    $cards.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cards.EmptyTitle = 'Активных сеансов нет'
    $cards.EmptyHint = 'Сеанс появится здесь, как только вы начнёте работу в Claude Code — на этом ПК или на подключённом Mac.'
    $menu = New-NotifierSessionMenu -Theme $t
    $cards.add_ItemAction({
            param($sender, $e)
            switch ($e.Action) {
                { $_ -like 'act:*' } {
                    if (Invoke-NotifierExtraCardAction -Item $e.Item -ActionId $e.Action.Substring(4) -Control $sender -Location $e.Location) { [void](Invoke-NotifierSessionsRefresh); return }
                    $notice = Invoke-NotifierCardAction -Item $e.Item -ActionId $e.Action.Substring(4)
                    if ($notice) { Show-NotifierNotice $notice }
                    [void](Invoke-NotifierSessionsRefresh)
                }
                'open' {
                    if ($e.Item.IsGroup) { Switch-NotifierSessionGroup -Item $e.Item; [void](Invoke-NotifierSessionsRefresh) }
                    else { Invoke-NotifierSelectedSession -Action focus }
                }
                'delete' { if (-not $e.Item.IsGroup) { Invoke-NotifierSelectedSession -Action remove } }
                'context' { if (-not $e.Item.IsGroup) { Show-NotifierSessionMenu -Menu $script:SessionsForm.Tag.Menu -Cards $sender -Item $e.Item -Location $e.Location } }
            }
        })

    $pages = New-Object System.Windows.Forms.Panel
    $pages.Dock = [System.Windows.Forms.DockStyle]::Fill
    $pages.BackColor = $t.Window
    $pages.Controls.Add($cards)
    $search = New-NotifierSearchBar -Theme $t
    $pages.Controls.Add($search.Panel)   # после карточек: пристыковывается сверху, карточки — под ней
    $netUi = $null
    if ($script:Net) {
        $netUi = New-NotifierDevicesPage -Theme $t
        $netUi.Page.Visible = $false
        $pages.Controls.Add($netUi.Page)
    }
    $settingsUi = $null
    if ($script:TrayDataRoot) {
        $settingsUi = New-NotifierSettingsPage -Theme $t
        $settingsUi.Page.Visible = $false
        $pages.Controls.Add($settingsUi.Page)
    }
    $statsUi = New-NotifierStatsPage -Theme $t
    $statsUi.Page.Visible = $false
    $pages.Controls.Add($statsUi.Page)
    $tabs.add_SelectedIndexChanged({
            $tag = $script:SessionsForm.Tag
            $i = $this.SelectedIndex
            $tag.Cards.Visible = ($i -eq 0)
            if ($i -ne 0) { $tag.Search.Panel.Visible = $false }
            if ($tag.Net) { $tag.Net.Page.Visible = ($i -eq 1) }
            if ($tag.Settings) { $tag.Settings.Page.Visible = ($i -eq 2); if ($i -eq 2) { Update-NotifierSettingsView } }
            $tag.Stats.Page.Visible = ($i -eq 3)
            if ($i -eq 3) { Update-NotifierStatsView; [void](Start-NotifierActivityScan) }
            $tag.Title.Text = @('Сеансы', 'Устройства', 'Настройки', 'Статистика')[$i]
            $tag.Back.Visible = ($i -ne 0)
            $tag.DevicesButton.Checked = ($i -eq 1); $tag.DevicesButton.Invalidate()
            $tag.SettingsButton.Checked = ($i -eq 2); $tag.SettingsButton.Invalidate()
            $tag.StatsButton.Checked = ($i -eq 3); $tag.StatsButton.Invalidate()
            $tag.Usage.Panel.Visible = ($i -eq 0)
            [void](Invoke-NotifierSessionsRefresh)
        })

    # Порядок добавления задаёт порядок пристыковки: последний Top — самый верхний.
    $usage = New-NotifierUsagePanel -Theme $t
    # Содержимое — с полями по краям; заголовок окна — во всю ширину, кнопки окна у самого края.
    $body = New-Object System.Windows.Forms.Panel
    $body.Dock = [System.Windows.Forms.DockStyle]::Fill
    $body.BackColor = $t.Window
    $body.Padding = New-Object System.Windows.Forms.Padding($t.S(20), $t.S(4), $t.S(20), $t.S(16))
    $body.Controls.Add($pages)
    $body.Controls.Add($usage.Panel)
    $body.Controls.Add($spacer)
    $body.Controls.Add($header)
    $form.Controls.Add($body)
    $form.Controls.Add($caption)
    $form.Tag = @{ Theme = $t; Cards = $cards; Title = $title; Subtitle = $subtitle; Tabs = $tabs; Net = $netUi; Settings = $settingsUi; Stats = $statsUi; Menu = $menu
        Back = $back; DevicesButton = $btnDevices; SettingsButton = $btnSettings; StatsButton = $btnStats; Usage = $usage; WindowButtons = $winButtons; Search = $search }
    $form.KeyPreview = $true
    $form.add_KeyDown({
            param($s, $e)
            if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::F) { Show-NotifierSearch; $e.Handled = $true; $e.SuppressKeyPress = $true }
        })
    $form.add_FormClosed({ $script:SessionsForm = $null; $script:SearchOpen = $false })
    $form.add_Shown({ $this.Tag.Cards.Focus() })
    return $form
}

function Show-NotifierSessionsWindow {
    <# .SYNOPSIS Открывает окно «Сеансы» или выводит уже открытое на передний план. -Tab 1 — «Устройства». #>
    param([int]$Tab = -1)
    # Шторка — главное окно: вместо окна «Сеансы» раскрывается она на нужной странице.
    if (Test-NotifierNotchActive) {
        $page = 'home'
        if ($script:NotchPages.ContainsKey($Tab)) { $page = $script:NotchPages[$Tab] }
        Open-NotifierNotch -Page $page
        return
    }
    try {
        if ($null -eq $script:SessionsForm -or $script:SessionsForm.IsDisposed) {
            $script:SessionsForm = New-NotifierSessionsForm
            [void](Invoke-NotifierSessionsRefresh)
            $script:SessionsForm.Show()
        }
        else {
            [void](Invoke-NotifierSessionsRefresh)
            if ($script:SessionsForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $script:SessionsForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
        }
        if ($Tab -ge 0) { $script:SessionsForm.Tag.Tabs.SelectedIndex = $Tab }
        $script:SessionsForm.Activate()
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: окно сеансов: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

function Test-SessionsRefreshDue {
    <# .SYNOPSIS Пора ли обновить сеансы (точку в трее и окно): пришли события или прошло RefreshMs. #>
    param([bool]$Dirty, [datetime]$LastRefresh, [datetime]$Now, [int]$RefreshMs = $script:SessionsRefreshMs)
    return $Dirty -or (($Now - $LastRefresh).TotalMilliseconds -ge $RefreshMs)
}
