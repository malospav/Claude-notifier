<#
.SYNOPSIS
Шторка вверху экрана — главное окно приложения: персонажи сеансов, ответы Claude, статистика, устройства, настройки.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Окно и отрисовка — ClaudeNotifier.Ui.NotchHost (lib\ui\Notch.cs):
своё окно в своём потоке, поэтому анимация не зависит от работы трея. Трей передаёт данные вызовами NotchHost
(Post в поток шторки), а щелчки забирает из очереди NotchHost.Commands в своём таймере.
Монитор, положение и маскот — config.json: notch.screen (имя монитора; '' — второй, если есть), notch.position,
notch.mascot (sphynx — 3D-сфинкс, flame — огонёк).
Шторка выключена — работает прежнее окно «Сеансы» и мини-окно у трея.
#>

$script:NotchCards = @{}          # id сеанса → карточка (для кнопок ответа)
$script:NotchPage = 'home'        # страница шторки (по командам из неё): home | answer | stats | devices | settings
$script:NotchAnswerId = ''        # сеанс, чей полный ответ открыт
$script:NotchExpanded = $false
$script:NotchPlacement = ''
$script:NotchSessions = @()
$script:NotchPages = @{ 0 = 'home'; 1 = 'devices'; 2 = 'settings'; 3 = 'stats' }   # вкладка прежнего окна → страница
$script:NotchReplyActions = '^(allow|always|deny|answer:\d+|answer-custom|reply:\d+|reply-custom|focus)$'

function Test-NotifierNotchActive {
    <# .SYNOPSIS Шторка работает (тогда она — главное окно вместо «Сеансов»). #>
    return [bool](('ClaudeNotifier.Ui.NotchHost' -as [type]) -and [ClaudeNotifier.Ui.NotchHost]::Running)
}

function Get-NotifierNotchScreen {
    <# .SYNOPSIS Монитор шторки: из настроек (если подключён), иначе первый неосновной, иначе основной. #>
    param([Parameter(Mandatory = $true)]$Config)
    $all = @([System.Windows.Forms.Screen]::AllScreens)
    $name = [string]$Config.notch.screen
    if ($name) { foreach ($s in $all) { if ($s.DeviceName -eq $name) { return $s } } }
    foreach ($s in $all) { if (-not $s.Primary) { return $s } }
    return [System.Windows.Forms.Screen]::PrimaryScreen
}

function Format-NotifierScreenName {
    <# .SYNOPSIS «Монитор 2 · 1440 × 2560» (основной — с пометкой). #>
    param([Parameter(Mandatory = $true)]$Screen, [switch]$Short)   # -Short — «Монитор 2» (для кнопки-селекта)
    $all = @([System.Windows.Forms.Screen]::AllScreens)
    $i = 1
    for ($k = 0; $k -lt $all.Count; $k++) { if ($all[$k].DeviceName -eq $Screen.DeviceName) { $i = $k + 1 } }
    if ($Short) { return "Монитор $i" }
    $text = "Монитор $i $([char]0x00B7) $($Screen.Bounds.Width) $([char]0x00D7) $($Screen.Bounds.Height)"
    if ($Screen.Primary) { $text += ' (основной)' }
    return $text
}

$script:NotchMascots = @('sphynx', 'flatsphynx', 'flame', 'boxcat', 'penguin', 'kitty', 'ghost', 'mochi')   # порядок — как в списке настроек
function Format-NotifierMascot([string]$Mascot) {
    switch ($Mascot) {
        'flatsphynx' { return 'Плоский сфинкс' }
        'flame' { return 'Огонёк' }
        'boxcat' { return 'Котик в коробке' }
        'penguin' { return 'Пингвин' }
        'kitty' { return 'Белый котик' }
        'ghost' { return 'Привидение' }
        'mochi' { return 'Моти' }
        default { return 'Сфинкс' }
    }
}

function Set-NotifierMascot {
    <# .SYNOPSIS Применить маскотов из настроек: этого ПК и каждого устройства (шторка, окно сеансов, мини-окно). #>
    param($Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot))
    if (-not ('ClaudeNotifier.Ui.Mascot' -as [type])) { return }
    [ClaudeNotifier.Ui.Mascot]::Kind = [string]$Config.notch.mascot
    [ClaudeNotifier.Ui.Mascot]::ClearDevices()
    foreach ($id in @($Config.notch.mascots.Keys)) { [ClaudeNotifier.Ui.Mascot]::SetDevice([string]$id, [string]$Config.notch.mascots[$id]) }
}

function Get-NotifierMascotOf {
    <# .SYNOPSIS Маскот устройства ('' — этот ПК): одно из NotchMascots. У устройства без своего — как у этого ПК. #>
    param([string]$Device = '', $Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot))
    if ($Device -ne '' -and $Config.notch.mascots.ContainsKey($Device)) { return [string]$Config.notch.mascots[$Device] }
    return [string]$Config.notch.mascot
}

function Switch-NotifierMascot {
    <# .SYNOPSIS Настройки: следующий маскот этого ПК ('') или устройства (сфинкс → огонёк → …). #>
    param([string]$Device = '')
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $order = $script:NotchMascots
    $next = $order[([Array]::IndexOf($order, (Get-NotifierMascotOf -Device $Device -Config $config)) + 1) % $order.Count]
    if ($Device -eq '') { Set-NotifierOptionValue -Name notch -Field mascot -Value $next }
    else {
        $map = @{}
        foreach ($k in @($config.notch.mascots.Keys)) { $map[$k] = $config.notch.mascots[$k] }
        $map[$Device] = $next
        Set-NotifierOptionValue -Name notch -Field mascots -Value ([pscustomobject]$map)
    }
    Set-NotifierMascot
}

function Format-NotifierNotchPosition([string]$Position) {
    switch ($Position) { 'left' { return 'Слева' } 'right' { return 'Справа' } default { return 'По центру' } }
}

function Initialize-NotifierNotch {
    <# .SYNOPSIS Запускает или останавливает шторку по config.json и ставит её на выбранный монитор. #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $config = Get-NotifierConfig -DataRoot $DataRoot
    [void](Import-NotifierUi)
    Set-NotifierMascot -Config $config
    if (-not $config.notch.enabled) {
        if ([ClaudeNotifier.Ui.NotchHost]::Running) { [ClaudeNotifier.Ui.NotchHost]::Stop() }
        $script:NotchPlacement = ''
        $script:NotchExpanded = $false
        return
    }
    [ClaudeNotifier.Ui.NotchHost]::Start()
    [ClaudeNotifier.Ui.NotchHost]::SetShowStats([bool]$config.notch.stats)
    [ClaudeNotifier.Ui.NotchHost]::SetAttention([bool]$config.notch.attention)
    Set-NotifierNotchPlacement -Config $config -Force
}

function Set-NotifierNotchPlacement {
    <# .SYNOPSIS Монитор и положение шторки (если изменились). #>
    param($Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot), [switch]$Force)
    if (-not (Test-NotifierNotchActive)) { return }
    $screen = Get-NotifierNotchScreen -Config $Config
    $key = "$($screen.Bounds)|$($Config.notch.position)"
    if (-not $Force -and $key -eq $script:NotchPlacement) { return }
    $script:NotchPlacement = $key
    # Отступ от края — в том же масштабе DPI, что и сама шторка (NotchForm.ApplyDpi); при 100 % — 24 пикселя.
    $scale = [ClaudeNotifier.Ui.NotchForm]::ScreenScale()
    [ClaudeNotifier.Ui.NotchHost]::Place($screen.Bounds, [string]$Config.notch.position, [int][Math]::Round(24 * $scale))
}

function Open-NotifierNotch {
    <# .SYNOPSIS Раскрыть шторку на странице (home | stats | devices | settings). #>
    param([string]$Page = 'home')
    if (-not (Test-NotifierNotchActive)) { return }
    $script:NotchPage = $Page
    $script:NotchExpanded = $true
    Push-NotifierNotchPage -Page $Page
    [ClaudeNotifier.Ui.NotchHost]::SetExpanded($true, $Page)
}

function Close-NotifierNotch {
    if (-not (Test-NotifierNotchActive)) { return }
    $script:NotchExpanded = $false
    [ClaudeNotifier.Ui.NotchHost]::SetExpanded($false, $null)
}

function Switch-NotifierNotch {
    <# .SYNOPSIS Горячая клавиша и щелчок по точке в трее: раскрыть или свернуть шторку. #>
    if ($script:NotchExpanded) { Close-NotifierNotch } else { Open-NotifierNotch -Page 'home' }
}

function ConvertTo-NotifierNotchItem {
    <# .SYNOPSIS Карточка сеанса → элемент шторки (кнопки — только ответы Claude). #>
    param([Parameter(Mandatory = $true)]$Card, [Parameter(Mandatory = $true)]$Session)
    $it = New-Object ClaudeNotifier.Ui.NotchItem
    $it.Id = $Card.Id
    $it.Title = $Card.Title
    $it.Meta = @('Терминал', 'Приложение')[[int]([string]$Session.origin -eq 'desktop')]
    if ($Session.PSObject.Properties['device'] -and [string]$Session.device -ne '') { $it.Meta = $Card.Section }
    $it.State = $Card.State
    if ($Session.PSObject.Properties['device']) { $it.Device = [string]$Session.device }   # свой маскот у устройства
    # «Похоже, остановился» — у сфинкса свой вид (сонный, в облачке «z»), не ошибка.
    if ([string]$Session.state -eq 'working' -and $Session.PSObject.Properties['stalledSince'] -and [string]$Session.stalledSince -ne '') { $it.State = 'stalled' }
    $it.StateText = $Card.StateText
    if ($Session.PSObject.Properties['stats'] -and $Session.stats -and $Session.stats.PSObject.Properties['tools']) { $it.Tools = [int]$Session.stats.tools }
    if ($Session.PSObject.Properties['agents'] -and $Session.agents) { $it.Agents = @(@($Session.agents) | Where-Object { $_ }).Count }
    if ($Card.SubLines.Length -gt 0) { $it.StateText += " $([char]0x00B7) " + $Card.SubLines[0] }
    $it.Preview = $Card.Preview
    $it.RequestTitle = $Card.RequestTitle
    if ($it.RequestTitle -eq 'Быстрый ответ') { $it.RequestTitle = '' }   # для быстрого ответа — превью ответа Claude
    $it.Actions = [string[]]@($Card.Actions | Where-Object { ($_ -split '\|')[0] -match $script:NotchReplyActions } | ForEach-Object { $_ -replace '\|Свой ответ…\|', '|Свой…|' -replace '\|Разрешать всегда\|', '|Всегда|' })
    # Ждёт вас (запрос, ошибка или вопрос в конце ответа) — с какого момента и что спрашивают: по этому шторка
    # привлекает внимание («выдох», свечение, зов маскота, рост, бегущая строка).
    $ask = ''
    $needs = $false
    if ($it.State -eq 'permission') { $needs = $true; $ask = ("$($Card.RequestTitle) $($Card.RequestDetail)").Trim() }
    elseif ($it.State -eq 'error') { $needs = $true }
    elseif ($it.State -eq 'waiting') {
        $q = ''
        try { $q = Get-NotifierSessionQuestion -Session $Session -Fallback ([string]$Session.preview) }
        catch { Write-NotifierLog -Level WARN -Message "notch: вопрос сеанса $($Session.session_id) не прочитан: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
        if ($q) { $needs = $true; $ask = $q }
    }
    if ($needs) {
        $since = [DateTimeOffset]::MinValue
        if (-not ($Session.PSObject.Properties['since'] -and [DateTimeOffset]::TryParse([string]$Session.since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$since))) { $since = [DateTimeOffset]::UtcNow }
        $it.WaitSince = $since.UtcDateTime.Ticks
        if ($ask.Length -gt 90) { $ask = $ask.Substring(0, 89).TrimEnd() + [char]0x2026 }
        $it.Ask = $ask
    }
    $it.Tag = $Card
    return $it
}

function Get-NotifierNotchItems {
    <# .SYNOPSIS Сеансы → элементы шторки в порядке срочности (закреплённые первыми). #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), $Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot))
    $prefs = Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot
    $pinned = @($prefs.Keys | Where-Object { $prefs[$_].pinned })
    $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.NotchItem]'
    $script:NotchCards = @{}
    foreach ($s in (Get-NotifierSortedSessions -Sessions $Sessions -Pinned $pinned)) {
        $card = ConvertTo-NotifierSessionCard -Session $s -Prefs $prefs -ContextWarn ([int]$Config.context.warnPercent)
        $script:NotchCards[$card.Id] = $card
        $list.Add((ConvertTo-NotifierNotchItem -Card $card -Session $s))
    }
    return , $list.ToArray()
}

function Get-NotifierNotchLimits {
    <#
    .SYNOPSIS
    Полоски шторки: сколько осталось от лимитов Claude. @{ Left5; Detail5; LeftWeek; DetailWeek; Stale }.
    Left — 100 − израсходовано, %; -1 — нет данных. Stale — данные старше 30 минут (полоски серые, в подписи — когда обновлены).
    #>
    param([datetime]$Now = [DateTime]::UtcNow)
    $usage = Get-NotifierUsage -DataRoot $script:TrayDataRoot
    $r = @{ Left5 = -1.0; Detail5 = ''; LeftWeek = -1.0; DetailWeek = ''; Stale = $false }
    if ($null -eq $usage) { return $r }
    $at = [DateTimeOffset]::MinValue
    if ($usage.PSObject.Properties['at'] -and [DateTimeOffset]::TryParse([string]$usage.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) {
        $r.Stale = ($Now - $at.UtcDateTime).TotalMinutes -gt 30
    }
    foreach ($pair in @(@('five_hour', '5'), @('seven_day', 'Week'))) {
        $w = Format-NotifierUsageWindow -Usage $usage -Window $pair[0] -Now $Now
        if ($null -eq $w.Percent -or [double]$w.Percent -lt 0) { continue }
        $r['Left' + $pair[1]] = [double][Math]::Max(0, [Math]::Min(100, 100 - [double]$w.Percent))
        $detail = [string]$w.Detail
        if ($r.Stale -and $detail -ne 'окно обновилось') { $detail = 'данные от ' + $at.ToLocalTime().ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        if ($detail -eq 'окно обновилось') { $detail = 'сброшен' }
        $r['Detail' + $pair[1]] = $detail
    }
    return $r
}

function Push-NotifierNotchLimits {
    <# .SYNOPSIS Передать шторке полоски лимитов и состояние звука. #>
    param([bool]$SoundOff)
    $l = Get-NotifierNotchLimits
    [ClaudeNotifier.Ui.NotchHost]::SetLimits([float]$l.Left5, [string]$l.Detail5, [float]$l.LeftWeek, [string]$l.DetailWeek, [bool]$l.Stale, $SoundOff)
}

function Update-NotifierNotch {
    <# .SYNOPSIS Из обновления сеансов (раз в 5 с и после событий): персонажи, полоски лимитов, страница «Устройства». #>
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    if (-not (Test-NotifierNotchActive)) { return }
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    Set-NotifierNotchPlacement -Config $config   # монитор отключили или сменили разрешение — переставить
    [ClaudeNotifier.Ui.NotchHost]::SetItems((Get-NotifierNotchItems -Sessions $Sessions -Config $config))
    Push-NotifierNotchLimits -SoundOff ([bool]$config.quiet.enabled)
    $script:NotchSessions = $Sessions
    if ($script:NotchExpanded -and $script:NotchPage -eq 'devices') { Push-NotifierNotchPage -Page devices }
    if ($script:NotchExpanded -and $script:NotchPage -eq 'answer' -and $script:NotchAnswerId) { Push-NotifierNotchAnswer -Id $script:NotchAnswerId }
}

function Push-NotifierNotchAnswer {
    <# .SYNOPSIS Полный последний ответ сеанса (из его журнала) — в шторку. #>
    param([Parameter(Mandatory = $true)][string]$Id)
    if (-not (Test-NotifierNotchActive) -or -not $script:NotchCards.ContainsKey($Id)) { return }
    $session = Get-NotifierCardSession $script:NotchCards[$Id]
    $text = ''
    if ($session -and $session.PSObject.Properties['transcript']) { try { $text = Get-NotifierLastAnswer -Path ([string]$session.transcript) } catch { } }
    if ($text -eq '' -and $session) { $text = ConvertTo-NotifierPlainText ([string]$session.preview) }
    [ClaudeNotifier.Ui.NotchHost]::SetAnswer($Id, $text)
}

# --- Страницы-списки ---

function New-NotifierNotchRow {
    param([string]$Kind = 'info', [string]$Key = '', [string]$Title = '', [string]$Subtitle = '', [string]$Value = '', [bool]$On = $false, [string]$Dot = '', [string[]]$Actions = @())
    $r = New-Object ClaudeNotifier.Ui.NotchRow
    $r.Kind = $Kind; $r.Key = $Key; $r.Title = $Title; $r.Subtitle = $Subtitle; $r.Value = $Value; $r.On = $On; $r.Dot = $Dot
    $r.Actions = [string[]]$Actions
    return $r
}

function Get-NotifierNotchSettingsRows {
    <#
    .SYNOPSIS
    Страница «Настройки» шторки по разделам: заголовок (header) — пункт бокового меню, строки раздела показываются
    в две колонки без прокрутки. Порядок внутри раздела — по парам слева направо (событие и его звук рядом).
    #>
    $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $rows = @()
    $rows += New-NotifierNotchRow header -Title 'Уведомления'
    foreach ($type in @('done', 'permission', 'error', 'limit')) {
        $label = Get-NotifierEventLabel $type
        $rows += New-NotifierNotchRow switch "event.$type" $label[0] $label[1] -On ([bool]$c.events[$type].enabled)
        $rows += New-NotifierNotchRow choice "sound.$type" 'Звук' $label[0] -Value (Get-NotifierSelectLabel "sound.$type" -Config $c)
    }
    $rows += New-NotifierNotchRow choice 'quiet' 'Без звука' 'Всегда или по часам' -Value (Get-NotifierSelectLabel 'quiet' -Config $c)
    $rows += New-NotifierNotchRow choice 'longTasks' 'Звук «Готово»' 'После задач дольше (или вас нет)' -Value (Get-NotifierSelectLabel 'longTasks' -Config $c)
    $rows += New-NotifierNotchRow header -Title 'Ответы'
    $rows += New-NotifierNotchRow switch 'approvals' 'Запросы разрешения' 'Разрешать из шторки и с телефона' -On ([bool]$c.approvals.enabled)
    $rows += New-NotifierNotchRow switch 'quickReplies' 'Быстрые ответы' 'Отвечать после «Готово» без перехода в окно' -On ([bool]$c.quickReplies.enabled)
    $rows += New-NotifierNotchRow choice 'remind' 'Напоминание' 'Повторить, если запрос ждёт' -Value (Get-NotifierSelectLabel 'remind' -Config $c)
    $rows += New-NotifierNotchRow switch 'showPrompt' 'Показывать мой запрос' 'Начало запроса в подробностях сеанса' -On ([bool]$c.showPrompt)
    $rows += New-NotifierNotchRow header -Title 'Сеансы'
    $rows += New-NotifierNotchRow choice 'context' 'Контекст' 'Предупредить до автосжатия' -Value (Get-NotifierSelectLabel 'context' -Config $c)
    $rows += New-NotifierNotchRow choice 'stalled' 'Сеанс завис' 'Тишина в журнале или ошибка API' -Value (Get-NotifierSelectLabel 'stalled' -Config $c)
    $rows += New-NotifierNotchRow choice 'inactive' 'Давние сеансы' 'Ждут ответа — в конец списка' -Value (Get-NotifierSelectLabel 'inactive' -Config $c)
    $rows += New-NotifierNotchRow header -Title 'Шторка'
    $rows += New-NotifierNotchRow choice 'notch.screen' 'Монитор' 'Экран для шторки' -Value (Get-NotifierSelectLabel 'notch.screen' -Config $c)
    $rows += New-NotifierNotchRow choice 'notch.position' 'Положение' 'У верхнего края' -Value (Get-NotifierSelectLabel 'notch.position' -Config $c)
    $rows += New-NotifierNotchRow switch 'notch.stats' 'Загрузка ПК' 'ЦП, ГП и память в свёрнутой шторке' -On ([bool]$c.notch.stats)
    $rows += New-NotifierNotchRow switch 'notch.attention' 'Привлекать внимание' 'Шторка зовёт, когда Claude ждёт вас' -On ([bool]$c.notch.attention)
    $rows += New-NotifierNotchRow choice 'hotkey' 'Горячая клавиша' (Format-NotifierHotKeySubtitle) -Value (Get-NotifierSelectLabel 'hotkey' -Config $c)
    $rows += New-NotifierNotchRow switch 'notch' 'Шторка вместо окна' 'Выключить — прежнее окно «Сеансы»' -On $true
    $rows += New-NotifierNotchRow header -Title 'Маскоты'
    $rows += New-NotifierNotchRow choice 'mascot:' 'Этот ПК' 'Сеансы Claude на этом компьютере' -Value (Get-NotifierSelectLabel 'mascot:' -Config $c)
    $devices = @()
    if ($script:Net -and $script:Net.Network) { $devices = @($script:Net.Network.devices | Where-Object { $_ }) }
    foreach ($d in $devices) {
        $rows += New-NotifierNotchRow choice "mascot:$([string]$d.id)" ([string]$d.name) (Get-NotifierDeviceKindText $d) -Value (Get-NotifierSelectLabel "mascot:$([string]$d.id)" -Config $c)
    }
    if ($devices.Count -eq 0) { $rows += New-NotifierNotchRow note -Title 'Подключите Mac или телефон на странице «Устройства» — у сеансов с них может быть свой маскот.' }
    $rows += New-NotifierNotchRow header -Title 'Система'
    $auto = $false; try { $auto = [bool](Test-NotifierAutostart) } catch { }
    $rows += New-NotifierNotchRow switch 'autostart' 'Запускать при входе' 'Шторка сразу после включения ПК' -On $auto
    $rows += New-NotifierNotchRow button 'data' 'Папка данных' (Format-NotifierShortText ([string]$script:TrayDataRoot)) -Value 'Открыть'
    $rows += New-NotifierNotchRow button 'export' 'Экспорт настроек' 'Сохранить в файл для другого ПК' -Value 'Сохранить…'
    $rows += New-NotifierNotchRow button 'import' 'Импорт настроек' 'Загрузить из сохранённого файла' -Value 'Загрузить…'
    return $rows   # строки по одной в конвейер: вызывающие оборачивают в @()
}

function Get-NotifierNotchDevicesRows {
    <# .SYNOPSIS Страница «Устройства»: доступ из сети, подключение, устройства с действиями. #>
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $rows = @()
    $net = $script:Net
    if ($null -eq $net) { return (New-NotifierNotchRow note -Title 'Доступ из сети недоступен.') }
    $sub = 'Выключен — Mac и телефон не видят этот ПК'; $on = $false
    if ($net.Server) { $sub = "Включён $([char]0x00B7) $(Get-NotifierServerBaseUrl $net)"; $on = $true }
    elseif ($net.Network.enabled -and $net.Error) { $sub = "Сервер не запустился: $($net.Error)"; $on = $true }
    $rows += New-NotifierNotchRow header -Title 'Доступ из сети'
    $rows += New-NotifierNotchRow switch 'net' 'Доступ из сети' $sub -On $on
    $rows += New-NotifierNotchRow button 'connect' 'Подключить устройство' 'Mac или телефон в той же сети Wi-Fi' -Value 'Подключить'
    $counts = @{}
    foreach ($s in $Sessions) { if ($null -eq $s) { continue }; $id = ''; if ($s.PSObject.Properties['device']) { $id = [string]$s.device }; $counts[$id] = 1 + [int]$counts[$id] }
    $devices = @($net.Network.devices | Where-Object { $_ })
    $rows += New-NotifierNotchRow header -Title 'Устройства'
    if ($devices.Count -eq 0) { $rows += New-NotifierNotchRow note -Title 'Подключённых устройств нет. Нажмите «Подключить» и откройте адрес на телефоне или Mac.' }
    foreach ($d in $devices) {
        $seen = Format-NotifierLastSeen -Ts ([string]$d.last_seen)
        $state = "Был $seen"; $dot = ''
        if ($seen -eq 'в сети') { $state = 'В сети'; $dot = 'online' }
        if ($seen -eq [string][char]0x2014) { $state = 'Ещё не на связи' }
        $meta = @($state, (Get-NotifierDeviceKindText $d), (Format-NotifierSessionCount ([int]$counts[[string]$d.id]))) -join " $([char]0x00B7) "
        $notify = @('Уведомления: выкл', 'Уведомления: вкл')[[int][bool]$d.notify]
        $rows += New-NotifierNotchRow device ([string]$d.id) ([string]$d.name) $meta -Dot $dot -Actions @("notify|$notify|secondary", 'rename|Имя|secondary', 'remove|Отключить|destructive')
    }
    return $rows   # строки по одной в конвейер: вызывающие оборачивают в @()
}

function Get-NotifierNotchStatsRows {
    <# .SYNOPSIS Страница «Статистика»: итог недели, столбцы по дням, проекты за сегодня и за неделю. #>
    $s = $script:ActivitySummary
    if ($null -eq $s) { return (New-NotifierNotchRow note -Title 'Считаю статистику по журналам Claude Code на этом ПК…') }
    $dot = " $([char]0x00B7) "
    $rows = @()
    $title = "За 7 дней: $(Format-NotifierTokensShort ([int64]$s.Total.tokens)) токенов${dot}$(Format-NotifierDuration ([int64]$s.Total.seconds))"
    if ($s.Total.PSObject.Properties['cost'] -and [double]$s.Total.cost -gt 0) { $title += "${dot}$([char]0x2248) $(Format-NotifierCost ([double]$s.Total.cost))" }
    $rows += New-NotifierNotchRow info -Title $title -Subtitle "Запросов $([int]$s.Total.prompts)${dot}проектов $(@($s.Week).Count)${dot}обновлено в $($s.Updated.ToString('HH:mm'))"
    $c = ConvertTo-NotifierStatsChart -Summary $s
    $chart = New-NotifierNotchRow chart
    $chart.Values = [double[]]$c.Values; $chart.Labels = [string[]]$c.Labels; $chart.ValueLabels = [string[]]$c.ValueLabels; $chart.Highlight = [int]$c.Highlight
    $rows += $chart
    foreach ($section in @(@{ Name = 'Сегодня'; Items = @($s.Today) }, @{ Name = 'За 7 дней'; Items = @($s.Week) })) {
        $rows += New-NotifierNotchRow header -Title $section.Name
        if (@($section.Items | Where-Object { $_ }).Count -eq 0) { $rows += New-NotifierNotchRow note -Title 'Пока нет данных.' }
        foreach ($p in $section.Items) {
            if ($null -eq $p) { continue }
            $sub = "$(Format-NotifierDuration ([int64]$p.seconds))${dot}запросов $([int]$p.prompts)"
            if ($p.PSObject.Properties['cost'] -and [double]$p.cost -gt 0) { $sub += "${dot}$(Format-NotifierCost ([double]$p.cost))" }
            $rows += New-NotifierNotchRow info -Title ([string]$p.project) -Subtitle $sub -Value "$(Format-NotifierTokensShort ([int64]$p.tokens)) токенов"
        }
    }
    $rows += New-NotifierNotchRow note -Title 'Из журналов Claude Code на этом ПК. Время — пока сеанс активен; стоимость — примерная, по ценам API.'
    return $rows   # строки по одной в конвейер: вызывающие оборачивают в @()
}

function Push-NotifierNotchPage {
    <# .SYNOPSIS Строки страницы — в шторку. «Главная» и «Ответ» строк не требуют. #>
    param([string]$Page = $script:NotchPage)
    if (-not (Test-NotifierNotchActive)) { return }
    $rows = $null
    switch ($Page) {
        'settings' { $rows = @(Get-NotifierNotchSettingsRows) }
        'devices' { $rows = @(Get-NotifierNotchDevicesRows -Sessions @($script:NotchSessions)) }
        'stats' {
            $rows = @(Get-NotifierNotchStatsRows)
            # Пересчёт — если итога ещё нет или он старше 10 минут (иначе готовый итог снова запускал бы пересчёт).
            if ($null -eq $script:ActivitySummary -or [datetime]::UtcNow -ge $script:ActivityNextAt) { [void](Start-NotifierActivityScan) }
        }
    }
    if ($null -ne $rows) { [ClaudeNotifier.Ui.NotchHost]::SetRows($Page, [ClaudeNotifier.Ui.NotchRow[]]@($rows)) }
}

# --- Команды из шторки ---

function Invoke-NotifierNotchCommands {
    <# .SYNOPSIS Из таймера трея: разобрать щелчки шторки. #>
    if (-not ('ClaudeNotifier.Ui.NotchHost' -as [type])) { return }
    $e = $null
    while ([ClaudeNotifier.Ui.NotchHost]::Commands.TryDequeue([ref]$e)) { Invoke-NotifierNotchCommand -Event $e }
}

function Show-NotifierSoundMenuAt {
    <# .SYNOPSIS Меню звука типа события у курсора: выбрать WAV, системный, прослушать. #>
    param([Parameter(Mandatory = $true)][string]$Type, [System.Drawing.Point]$Location = [System.Windows.Forms.Cursor]::Position)
    $script:SoundMenuType = $Type
    $menu = New-NotifierMenu -Theme ([ClaudeNotifier.Ui.Theme]::Create($true)) -Items @(
        @('Выбрать WAV…', {
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Filter = 'Звук WAV (*.wav)|*.wav'; $dlg.Title = 'Звук уведомления'
                [ClaudeNotifier.Ui.NotchHost]::SetHold($true)
                try { if ((Show-NotifierFileDialog -Dialog $dlg) -eq [System.Windows.Forms.DialogResult]::OK) { Set-NotifierEventOption -Type $script:SoundMenuType -Sound $dlg.FileName } }
                finally { $dlg.Dispose(); [ClaudeNotifier.Ui.NotchHost]::SetHold($false) }
                Push-NotifierNotchPage -Page settings
            }),
        @('Системный звук', { Set-NotifierEventOption -Type $script:SoundMenuType -Sound ''; Push-NotifierNotchPage -Page settings }),
        '-',
        @('Прослушать', { [void](Invoke-NotifierSound -Type $script:SoundMenuType -Config (Get-NotifierConfig -DataRoot $script:TrayDataRoot) -DataRoot $script:TrayDataRoot) })
    )
    [ClaudeNotifier.Ui.NotchHost]::SetHold($true)
    $menu.add_Closed({ [ClaudeNotifier.Ui.NotchHost]::SetHold($false) })
    $menu.Show($Location)
}

function Invoke-NotifierNotchSetting {
    <#
    .SYNOPSIS
    Тумблер или выбор на страницах «Настройки» и «Устройства». Возвращает $true, если открыт выпадающий список
    (тогда шторку держат раскрытой, пока он не закроется).
    #>
    param([Parameter(Mandatory = $true)][string]$Key, [System.Drawing.Point]$Location = [System.Windows.Forms.Cursor]::Position, [int]$Width = 0)
    # Селекты — выпадающий список под кнопкой; страница обновится после выбора.
    if (@(Get-NotifierSelectOptions -Key $Key).Count -gt 0) {
        Show-NotifierSelect -Key $Key -Location $Location -Width $Width -After { Push-NotifierNotchPage -Page settings }
        return $true
    }
    $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $null = switch -Regex ($Key) {
        '^event\.(done|permission|error|limit)$' { Set-NotifierEventOption -Type $Matches[1] -Enabled (-not [bool]$c.events[$Matches[1]].enabled) }
        '^(approvals|quickReplies|groups)$' { Set-NotifierOptionValue -Name $Key -Value (-not [bool]$c[$Key].enabled); $script:SessionsDirty = $true }
        '^showPrompt$' { Set-NotifierOptionValue -Name showPrompt -Value (-not [bool]$c.showPrompt) }
        '^notch\.attention$' {
            $on = -not [bool]$c.notch.attention
            Set-NotifierOptionValue -Name notch -Field attention -Value $on
            if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetAttention($on) }
        }
        '^notch\.stats$' {
            $on = -not [bool]$c.notch.stats
            Set-NotifierOptionValue -Name notch -Field stats -Value $on
            if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetShowStats($on) }
        }
        '^notch$' {
            # Шторку выключили — дальше работает прежнее окно (открываем его на настройках).
            Set-NotifierOptionValue -Name notch -Value $false
            Initialize-NotifierNotch
            Show-NotifierSessionsWindow -Tab 2
            return $false
        }
        '^autostart$' { Set-NotifierAutostart -Enabled (-not (Test-NotifierAutostart)) -AppRoot $PSScriptRoot }
        '^net$' {
            if ($script:Net.Server -or ($script:Net.Network.enabled -and $script:Net.Error)) { Disable-NotifierNetworkAccess }
            else { [void](Enable-NotifierNetworkAccess -Owner $null) }
            [void](Invoke-NotifierSessionsRefresh)
        }
    }
    return $false
}

function Switch-NotifierQuiet {
    <# .SYNOPSIS Кнопка-динамик в шторке: «Без звука» всегда ↔ выкл; расписание (quiet.schedule) не трогается. #>
    $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $on = -not [bool]$c.quiet.enabled
    Set-NotifierOptionValue -Name quiet -Value $on
    Push-NotifierNotchLimits -SoundOff $on
}

function Invoke-NotifierDeviceActionById {
    <# .SYNOPSIS Действие с устройством из шторки: notify | rename | remove. #>
    param([Parameter(Mandatory = $true)][string]$Id, [Parameter(Mandatory = $true)][ValidateSet('notify', 'rename', 'remove')][string]$Action)
    $net = $script:Net
    if ($null -eq $net) { return }
    $d = Find-NotifierDevice -Network $net.Network -Id $Id
    if ($null -eq $d) { return }
    switch ($Action) {
        'notify' { $d.notify = -not [bool]$d.notify }
        'rename' {
            $r = Show-NotifierDialog -Owner $null -Title 'Переименовать устройство' -Primary 'Сохранить' -InputValue ([string]$d.name)
            if (-not $r.Ok) { return }
            $name = ([string]$r.Value -replace '[\x00-\x1f]', '').Trim()
            if ($name -eq '') { return }
            if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
            $d.name = $name
        }
        'remove' {
            $msg = 'Устройство потеряет доступ к этому ПК.'
            if ($d.hooks) { $msg += ' Хуки на самом Mac останутся — удалить их: ~/.claude-notifier/uninstall.sh' }
            $r = Show-NotifierDialog -Owner $null -Title "Отключить «$($d.name)»?" -Primary 'Отключить' -Destructive -Message $msg
            if (-not $r.Ok) { return }
            [void](Remove-NotifierDeviceAndSessions -Id ([string]$d.id))
        }
    }
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
    [void](Invoke-NotifierSessionsRefresh)
}

function Switch-NotifierNotchScreen {
    <# .SYNOPSIS Настройки: следующий монитор для шторки. #>
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $all = @([System.Windows.Forms.Screen]::AllScreens)
    $cur = Get-NotifierNotchScreen -Config $config
    $i = 0
    for ($k = 0; $k -lt $all.Count; $k++) { if ($all[$k].DeviceName -eq $cur.DeviceName) { $i = $k } }
    Set-NotifierOptionValue -Name notch -Field screen -Value ([string]$all[($i + 1) % $all.Count].DeviceName)
    Set-NotifierNotchPlacement
}

function Switch-NotifierNotchPosition {
    <# .SYNOPSIS Настройки: слева → по центру → справа. #>
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $order = @('left', 'center', 'right')
    $next = $order[([Array]::IndexOf($order, [string]$config.notch.position) + 1) % 3]
    Set-NotifierOptionValue -Name notch -Field position -Value $next
    Set-NotifierNotchPlacement
}

# --- Селекты настроек: кнопка со стрелкой вниз → список вариантов под ней ---
# Все варианты описаны в Get-NotifierSelectOptions; Set-NotifierSelectValue записывает только значение из этого
# списка, поэтому ручная правка config.json со «своим» числом тоже видна (оно добавляется в список как текущее).

$script:NotchSounds = @('Windows Notify Messaging', 'Windows Notify Calendar', 'Windows Notify Email', 'Windows Notify System Generic',
    'Windows Notify', 'Windows Message Nudge', 'Windows Proximity Notification', 'Windows Exclamation', 'Windows Ding',
    'chimes', 'chord', 'tada')
$script:QuietSchedules = @('22:00-07:00', '23:00-08:00', '00:00-09:00')

function New-SelectOption([string]$Value, [string]$Label, [bool]$Current, [switch]$Separator) {
    return @{ Value = $Value; Label = $Label; Current = $Current; Separator = [bool]$Separator }
}

function Get-NumberSelectOptions {
    # Варианты-числа с «Выкл» (Off — значение выключения) и текущим значением, даже если его нет среди готовых.
    param([int[]]$Values, [string]$Current, [scriptblock]$Format, [string]$Off = '', [string]$OffLabel = 'Выкл')
    $list = @()
    if ($Off -ne '') { $list += New-SelectOption $Off $OffLabel ($Current -eq $Off) }
    $all = @($Values)
    if ($Current -ne $Off -and $Current -match '^\d+$' -and $all -notcontains [int]$Current) { $all = @($all + [int]$Current | Sort-Object) }
    foreach ($v in $all) { $list += New-SelectOption ([string]$v) (& $Format $v) ([string]$v -eq $Current) }
    return $list
}

function Format-NotifierQuietSchedule([string]$Schedule) {
    if ($Schedule -notmatch '^(\d\d:\d\d)-(\d\d:\d\d)$') { return 'Выкл' }
    return "$($Matches[1])$([char]0x2013)$($Matches[2])"
}

function Get-NotifierSelectOptions {
    <#
    .SYNOPSIS
    Варианты селекта настроек: @{ Value; Label; Current; Separator } по порядку. Значения, начинающиеся с «*», —
    действия (выбрать файл, прослушать), а не настройка. Неизвестный ключ — пусто.
    #>
    param([Parameter(Mandatory = $true)][string]$Key, $Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot))
    $c = $Config
    switch -Regex ($Key) {
        '^notch\.screen$' {
            $set = [string]$c.notch.screen
            $auto = Get-NotifierNotchScreen -Config @{ notch = @{ screen = '' } }
            New-SelectOption '' "Автоматически ($(Format-NotifierScreenName $auto -Short))" ($set -eq '')
            foreach ($s in @([System.Windows.Forms.Screen]::AllScreens)) { New-SelectOption ([string]$s.DeviceName) (Format-NotifierScreenName $s) ($set -ne '' -and $s.DeviceName -eq $set) }
            # Выбранный монитор отключён: шторка на «автоматическом», но выбор помнится — покажем его отдельно.
            if ($set -ne '' -and @([System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $set }).Count -eq 0) { New-SelectOption $set 'Отключённый монитор' $true }
        }
        '^notch\.position$' {
            $cur = [string]$c.notch.position
            if (@('left', 'right') -notcontains $cur) { $cur = 'center' }
            foreach ($v in @('left', 'center', 'right')) { New-SelectOption $v (Format-NotifierNotchPosition $v) ($v -eq $cur) }
        }
        '^(?:notch\.mascot|mascot:(.*))$' {
            $dev = if ($Matches[1]) { [string]$Matches[1] } else { '' }
            if ($dev -ne '') {
                # У устройства может не быть своего маскота — тогда как у этого ПК.
                $own = $c.notch.mascots.ContainsKey($dev)
                New-SelectOption '' "Как у этого ПК ($(Format-NotifierMascot ([string]$c.notch.mascot)))" (-not $own)
                foreach ($v in $script:NotchMascots) { New-SelectOption $v (Format-NotifierMascot $v) ($own -and [string]$c.notch.mascots[$dev] -eq $v) }
            }
            else { foreach ($v in $script:NotchMascots) { New-SelectOption $v (Format-NotifierMascot $v) ([string]$c.notch.mascot -eq $v) } }
        }
        '^remind$' { Get-NumberSelectOptions -Values 1, 3, 5, 10, 15 -Current ([string][int]$c.approvals.remindMinutes) -Off '0' -Format { "$($args[0]) мин" } }
        '^longTasks$' {
            $cur = if ($c.longTasks.enabled) { [string][int]$c.longTasks.minutes } else { 'off' }
            Get-NumberSelectOptions -Values 1, 2, 5, 10, 15 -Current $cur -Off 'off' -OffLabel 'Всегда' -Format { "От $($args[0]) мин" }
        }
        '^context$' {
            $cur = if ($c.context.enabled) { [string][int]$c.context.warnPercent } else { 'off' }
            Get-NumberSelectOptions -Values 70, 80, 85, 90, 95 -Current $cur -Off 'off' -Format { "$($args[0]) %" }
        }
        '^stalled$' {
            $cur = if ($c.stalled.enabled) { [string][int]$c.stalled.minutes } else { 'off' }
            Get-NumberSelectOptions -Values 5, 10, 15, 30, 60 -Current $cur -Off 'off' -Format { "$($args[0]) мин" }
        }
        '^inactive$' {
            $cur = if ($c.inactive.enabled) { [string][int]$c.inactive.hours } else { 'off' }
            Get-NumberSelectOptions -Values 1, 2, 4, 8, 24 -Current $cur -Off 'off' -Format { "$($args[0]) ч" }
        }
        '^sound\.(done|permission|error|limit)$' {
            $cur = [string]$c.events[$Matches[1]].sound
            New-SelectOption '' 'Системный' ($cur -eq '')
            $media = Join-Path $env:SystemRoot 'Media'
            $known = $false
            foreach ($n in $script:NotchSounds) {
                $p = Join-Path $media "$n.wav"
                if (-not (Test-Path -LiteralPath $p)) { continue }
                $is = $cur -ne '' -and [string]::Equals($cur, $p, [StringComparison]::OrdinalIgnoreCase)
                if ($is) { $known = $true }
                New-SelectOption $p ($n -replace '^Windows ', '') $is
            }
            if ($cur -ne '' -and -not $known) { New-SelectOption $cur ([IO.Path]::GetFileNameWithoutExtension($cur) -replace '^Windows ', '') $true }
            New-SelectOption '*file' 'Свой файл WAV…' $false -Separator
            New-SelectOption '*play' 'Прослушать' $false
        }
        '^hotkey$' {
            $cur = if ($c.hotkey.enabled) { [string]$c.hotkey.keys } else { 'off' }
            New-SelectOption 'off' 'Выкл' ($cur -eq 'off')
            foreach ($v in (Get-NotifierHotKeyChoices)) {
                $label = if ($v -eq 'auto') { 'Win+Shift+C (или Ctrl+Alt+C)' } else { $v }
                New-SelectOption $v $label ($v -eq $cur)
            }
        }
        '^quiet$' {
            # Выкл / Всегда (кнопка-динамик в шторке) / по расписанию каждый день.
            $cur = if ($c.quiet.enabled) { 'always' } else { [string]$c.quiet.schedule }
            New-SelectOption '' 'Выкл' ($cur -eq '')
            New-SelectOption 'always' 'Всегда' ($cur -eq 'always')
            $all = @($script:QuietSchedules)
            if ($cur -ne '' -and $all -notcontains $cur) { $all += $cur }
            foreach ($v in $all) { New-SelectOption $v (Format-NotifierQuietSchedule $v) ($v -eq $cur) }
        }
    }
}

function Get-NotifierSelectLabel {
    <# .SYNOPSIS Текст кнопки селекта — подпись текущего варианта (у монитора — коротко). #>
    param([Parameter(Mandatory = $true)][string]$Key, $Config = (Get-NotifierConfig -DataRoot $script:TrayDataRoot))
    if ($Key -eq 'notch.screen') {
        if ([string]$Config.notch.screen -eq '') { return 'Авто' }
        return (Format-NotifierScreenName (Get-NotifierNotchScreen -Config $Config) -Short)
    }
    $cur = @(Get-NotifierSelectOptions -Key $Key -Config $Config | Where-Object { $_.Current }) | Select-Object -First 1
    if ($null -eq $cur) { return '' }
    $label = [string]$cur.Label
    if ($Key -like 'mascot:?*' -and [string]$cur.Value -eq '') { return 'Как у ПК' }
    if ($Key -eq 'hotkey' -and [string]$cur.Value -eq 'auto') { return 'Win+Shift+C' }
    return $label
}

function Set-NotifierSelectValue {
    <#
    .SYNOPSIS
    Записать вариант, выбранный в селекте, и сразу применить (место шторки, маскот, горячая клавиша).
    Принимается только значение из Get-NotifierSelectOptions; действия «*file» / «*play» — у звука.
    #>
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    if (@(Get-NotifierSelectOptions -Key $Key -Config $config | Where-Object { [string]$_.Value -ceq $Value }).Count -eq 0) { return }
    switch -Regex ($Key) {
        '^notch\.screen$' { Set-NotifierOptionValue -Name notch -Field screen -Value $Value; Set-NotifierNotchPlacement }
        '^notch\.position$' { Set-NotifierOptionValue -Name notch -Field position -Value $Value; Set-NotifierNotchPlacement }
        '^(?:notch\.mascot|mascot:(.*))$' {
            $dev = if ($Matches[1]) { [string]$Matches[1] } else { '' }
            if ($dev -eq '') { Set-NotifierOptionValue -Name notch -Field mascot -Value $Value }
            else {
                $map = @{}
                foreach ($k in @($config.notch.mascots.Keys)) { $map[$k] = $config.notch.mascots[$k] }
                if ($Value -eq '') { $map.Remove($dev) } else { $map[$dev] = $Value }   # '' — снова как у этого ПК
                Set-NotifierOptionValue -Name notch -Field mascots -Value ([pscustomobject]$map)
            }
            Set-NotifierMascot
        }
        '^remind$' { Set-NotifierOptionValue -Name approvals -Field remindMinutes -Value ([int]$Value) }
        '^(longTasks|context|stalled|inactive)$' {
            $name = $Matches[1]
            $field = @{ longTasks = 'minutes'; context = 'warnPercent'; stalled = 'minutes'; inactive = 'hours' }[$name]
            if ($Value -eq 'off') { Set-NotifierOptionValue -Name $name -Value $false }
            else {
                $section = $config[$name]
                $section.enabled = $true
                $section[$field] = [int]$Value
                Set-NotifierConfigValue -Name $name -Value ([pscustomobject]$section) -DataRoot $script:TrayDataRoot
            }
            $script:SessionsDirty = $true
        }
        '^sound\.(done|permission|error|limit)$' {
            $type = $Matches[1]
            switch ($Value) {
                '*play' { [void](Invoke-NotifierSound -Type $type -Config $config -DataRoot $script:TrayDataRoot); return }
                '*file' {
                    $dlg = New-Object System.Windows.Forms.OpenFileDialog
                    $dlg.Filter = 'Звук WAV (*.wav)|*.wav'; $dlg.Title = 'Звук уведомления'
                    if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetHold($true) }
                    try { if ((Show-NotifierFileDialog -Dialog $dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }; $file = $dlg.FileName }
                    finally { $dlg.Dispose(); if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetHold($false) } }
                    Set-NotifierEventOption -Type $type -Sound $file
                }
                default { Set-NotifierEventOption -Type $type -Sound $Value }
            }
            # Выбранный звук сразу слышно — так проще выбирать.
            [void](Invoke-NotifierSound -Type $type -Config (Get-NotifierConfig -DataRoot $script:TrayDataRoot) -DataRoot $script:TrayDataRoot)
        }
        '^hotkey$' {
            if ($Value -eq 'off') { Set-NotifierOptionValue -Name hotkey -Value $false }
            else {
                $section = $config.hotkey; $section.enabled = $true; $section.keys = $Value
                Set-NotifierConfigValue -Name hotkey -Value ([pscustomobject]$section) -DataRoot $script:TrayDataRoot
            }
            try { [void](Register-NotifierHotKey) } catch { }
        }
        '^quiet$' {
            $section = $config.quiet
            if ($Value -eq 'always') { $section.enabled = $true }
            else { $section.enabled = $false; $section.schedule = $Value }
            Set-NotifierConfigValue -Name quiet -Value ([pscustomobject]$section) -DataRoot $script:TrayDataRoot
            Push-NotifierNotchLimits -SoundOff ([bool]$section.enabled)
        }
    }
}

function Show-NotifierSelect {
    <#
    .SYNOPSIS
    Выпадающий список вариантов настройки под кнопкой-селектом (шторка или прежнее окно): текущий — с галочкой.
    Location — левый нижний угол кнопки на экране, Width — её ширина (список не уже кнопки). After — что сделать после выбора.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [System.Drawing.Point]$Location = [System.Windows.Forms.Cursor]::Position,
        [int]$Width = 0,
        [scriptblock]$After
    )
    $options = @(Get-NotifierSelectOptions -Key $Key)
    if ($options.Count -eq 0) { return }
    if ($script:SelectMenu -and -not $script:SelectMenu.IsDisposed) {
        foreach ($it in @($script:SelectMenu.Items)) { if ($it.Image) { $it.Image.Dispose() } }   # картинки маскотов
        $script:SelectMenu.Dispose()
    }
    $theme = [ClaudeNotifier.Ui.Theme]::Create($true)
    $menu = New-NotifierMenu -Theme $theme
    $menu.ShowCheckMargin = $true
    if ($Width -gt 0) { $menu.MinimumSize = New-Object System.Drawing.Size($Width, 0) }
    # Маскоты — с картинкой у каждого пункта: выбирать по виду, а не по названию.
    $mascots = $Key -match '^(notch\.mascot|mascot:)'
    $pcMascot = ''
    if ($mascots -and ('ClaudeNotifier.Ui.Mascot' -as [type])) {
        $menu.ShowImageMargin = $true
        $menu.ImageScalingSize = New-Object System.Drawing.Size($theme.S(30), $theme.S(30))
        $pcMascot = [string](Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.mascot
    }
    else { $mascots = $false }
    $script:SelectAfter = $After
    foreach ($o in $options) {
        if ($o.Separator) { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ([string]$o.Label)
        $mi.Padding = New-Object System.Windows.Forms.Padding($theme.S(4), $theme.S(5), $theme.S(8), $theme.S(5))
        if ($mascots) {
            $kind = if ([string]$o.Value -eq '') { $pcMascot } else { [string]$o.Value }   # «Как у этого ПК» — маскот ПК
            $mi.Image = [ClaudeNotifier.Ui.Mascot]::Preview($kind, $theme.S(30))
            $mi.ImageScaling = [System.Windows.Forms.ToolStripItemImageScaling]::None
        }
        $mi.Checked = [bool]$o.Current
        $mi.Tag = @{ Key = $Key; Value = [string]$o.Value }
        $mi.add_Click({
                $t = $this.Tag
                try { Set-NotifierSelectValue -Key $t.Key -Value $t.Value }
                catch { Write-NotifierLog -Level ERROR -Message "settings: $($t.Key): $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                if ($script:SelectAfter) { & $script:SelectAfter }
            })
        [void]$menu.Items.Add($mi)
    }
    $script:SelectMenu = $menu
    # Пока список открыт, щелчок по нему не должен сворачивать шторку.
    if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetHold($true) }
    $menu.add_Closed({ if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetHold($false) } })
    $menu.Show($Location)
}

function Export-NotifierSettings {
    <#
    .SYNOPSIS
    Настройки (config.json) — в файл для другого ПК. chainStatusLine не переносится: это команда этого ПК.
    Нет config.json — пишутся настройки по умолчанию.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [string]$DataRoot = $script:TrayDataRoot)
    $src = Join-Path $DataRoot 'config.json'
    $obj = [pscustomobject]@{}
    if (Test-Path -LiteralPath $src -PathType Leaf) { $obj = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($src, [Text.Encoding]::UTF8)) -ErrorAction Stop }
    if ($obj.PSObject.Properties['chainStatusLine']) { $obj.PSObject.Properties.Remove('chainStatusLine') }
    $obj | Add-Member -NotePropertyName '$claudeNotifier' -NotePropertyValue 'settings' -Force   # метка: это файл наших настроек
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $obj -Depth 8), (New-Object System.Text.UTF8Encoding $false))
}

function Import-NotifierSettings {
    <#
    .SYNOPSIS
    Загружает настройки из файла экспорта. Файл проверяется заранее (JSON-объект с меткой экспорта); свой
    chainStatusLine этого ПК сохраняется. Неверные значения внутри при чтении заменятся значениями по умолчанию.
    Возвращает '' при успехе или текст ошибки.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [string]$DataRoot = $script:TrayDataRoot)
    try { $obj = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -ErrorAction Stop }
    catch { return 'Файл не читается как JSON.' }
    if ($obj -isnot [System.Management.Automation.PSCustomObject] -or [string]$obj.PSObject.Properties['$claudeNotifier'].Value -ne 'settings') {
        return 'Это не файл настроек claude-notifier (сохраните его через «Экспорт настроек»).'
    }
    $obj.PSObject.Properties.Remove('$claudeNotifier')
    if ($obj.PSObject.Properties['chainStatusLine']) { $obj.PSObject.Properties.Remove('chainStatusLine') }
    $dst = Join-Path $DataRoot 'config.json'
    if (Test-Path -LiteralPath $dst -PathType Leaf) {
        try {
            $mine = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($dst, [Text.Encoding]::UTF8)) -ErrorAction Stop
            if ($mine.PSObject.Properties['chainStatusLine']) { $obj | Add-Member -NotePropertyName chainStatusLine -NotePropertyValue $mine.chainStatusLine -Force }
        }
        catch { }
        Copy-Item -LiteralPath $dst -Destination "$dst.before-import" -Force   # на случай, если захочется вернуть
    }
    $tmp = "$dst.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 8), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $dst -Force
    return ''
}

function Export-NotifierSettingsDialog {
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter = 'Настройки claude-notifier (*.json)|*.json'; $dlg.FileName = 'claude-notifier-settings.json'; $dlg.Title = 'Экспорт настроек'
    try {
        if ((Show-NotifierFileDialog -Dialog $dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        Export-NotifierSettings -Path $dlg.FileName
    }
    catch { [void](Show-NotifierDialog -Owner $null -Title 'Не удалось сохранить настройки' -Message $_.Exception.Message -Primary 'Понятно') }
    finally { $dlg.Dispose() }
}

function Import-NotifierSettingsDialog {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Настройки claude-notifier (*.json)|*.json'; $dlg.Title = 'Импорт настроек'
    try {
        if ((Show-NotifierFileDialog -Dialog $dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $err = Import-NotifierSettings -Path $dlg.FileName
        if ($err) { [void](Show-NotifierDialog -Owner $null -Title 'Настройки не загружены' -Message $err -Primary 'Понятно'); return }
        # Применить сразу: маскоты, место шторки, горячая клавиша, списки сеансов.
        Set-NotifierMascot
        Set-NotifierNotchPlacement -Force
        try { [void](Register-NotifierHotKey) } catch { }
        $script:SessionsDirty = $true
    }
    catch { [void](Show-NotifierDialog -Owner $null -Title 'Настройки не загружены' -Message $_.Exception.Message -Primary 'Понятно') }
    finally { $dlg.Dispose() }
}

function Show-NotifierNotchSessionMenu {
    <# .SYNOPSIS Правый щелчок по сеансу в шторке: то же меню, что в окне (перейти, файлы, папка, имя, закрепить, без уведомлений, убрать). #>
    param([Parameter(Mandatory = $true)]$Card, [System.Drawing.Point]$Location = [System.Windows.Forms.Cursor]::Position)
    if ($null -eq $script:NotchMenu -or $script:NotchMenu.IsDisposed) {
        $script:NotchMenu = New-NotifierSessionMenu -Theme ([ClaudeNotifier.Ui.Theme]::Create($true))
        $script:NotchMenu.add_Closed({ [ClaudeNotifier.Ui.NotchHost]::SetHold($false) })
    }
    $script:MenuItem = $Card
    $script:MenuSource = 'notch'
    [ClaudeNotifier.Ui.NotchHost]::SetHold($true)
    $script:NotchMenu.Show($Location)
}

function Invoke-NotifierNotchCommand {
    <# .SYNOPSIS Щелчок в шторке (из очереди): страницы, ответы, переход к окну, настройки, устройства. #>
    param([Parameter(Mandatory = $true)]$Event)
    $card = $null
    if ($Event.Id -and $script:NotchCards.ContainsKey([string]$Event.Id)) { $card = $script:NotchCards[[string]$Event.Id] }
    $session = $null
    if ($card) { $session = Get-NotifierCardSession $card }
    $keepHold = $false
    # Пока трей показывает диалог, щелчок по нему не должен сворачивать шторку.
    if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::SetHold($true) }
    try {
        switch ([string]$Event.Kind) {
            'expand' { $script:NotchExpanded = $true; $script:NotchPage = 'home' }
            { @('collapse', 'close') -contains $_ } { $script:NotchExpanded = $false }   # шторка уже свернулась сама
            'page' {
                $script:NotchPage = [string]$Event.Action
                if ($script:NotchPage -eq 'answer') { $script:NotchAnswerId = [string]$Event.Id; Push-NotifierNotchAnswer -Id $script:NotchAnswerId }
                else { Push-NotifierNotchPage -Page $script:NotchPage }
            }
            'sound' { Switch-NotifierQuiet }   # кнопка-динамик: «Без звука» всегда / выкл (расписание остаётся)
            'open' {
                if ($null -eq $session -or ($session.PSObject.Properties['device'] -and [string]$session.device -ne '')) { return }
                if ((Invoke-NotifierSessionFocus -Session $session) -ne 'unknown') { Close-NotifierNotch }
            }
            'action' {
                if ($null -eq $card) { return }
                $script:DialogOpen = $true
                try { [void](Invoke-NotifierCardAction -Item $card -ActionId ([string]$Event.Action)) }
                finally { $script:DialogOpen = $false }
                [void](Invoke-NotifierSessionsRefresh)
            }
            'set' {
                $w = 0; [void][int]::TryParse([string]$Event.Action, [ref]$w)   # у селекта — ширина кнопки
                # Открыт выпадающий список — шторку держим раскрытой, пока он не закроется (снимет его Closed).
                if (Invoke-NotifierNotchSetting -Key ([string]$Event.Id) -Location $Event.Location -Width $w) { $keepHold = $true }
                Push-NotifierNotchPage
            }
            'remove' {
                # Крестик на плашке: сеанс убирается из списка (вернётся при следующем событии в нём).
                Remove-NotifierSession -SessionId ([string]$Event.Id)
                [void](Invoke-NotifierSessionsRefresh)
            }
            'menu' {
                if ($null -eq $card) { return }
                $keepHold = $true
                Show-NotifierNotchSessionMenu -Card $card -Location $Event.Location
            }
            'row' {
                $id = [string]$Event.Id
                if ($id -eq 'data') { Start-Process explorer.exe $script:TrayDataRoot }
                elseif ($id -eq 'export') { Export-NotifierSettingsDialog }
                elseif ($id -eq 'import') { Import-NotifierSettingsDialog }
                elseif ($id -eq 'connect') { Show-NotifierConnectDialog }
                elseif ($id -like 'sound.*') { $keepHold = $true; Show-NotifierSoundMenuAt -Type $id.Substring(6) -Location $Event.Location }
                elseif ($Event.Action) { Invoke-NotifierDeviceActionById -Id $id -Action ([string]$Event.Action) }
                Push-NotifierNotchPage
            }
        }
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: шторка: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    finally { if (-not $keepHold -and (Test-NotifierNotchActive)) { [ClaudeNotifier.Ui.NotchHost]::SetHold($false) } }
}
