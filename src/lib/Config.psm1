Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:EventTypes = @('done', 'permission', 'error', 'limit')
$script:PreviewLengthMin = 20
$script:PreviewLengthMax = 2000

# Строки интерфейса: заголовки типов событий.
$NotifierStrings = @{
    done       = 'Готово'
    permission = 'Нужно разрешение'
    error      = 'Ошибка'
    limit      = 'Лимит'
    # Статусы сеанса в окне «Сеансы Claude»
    'state.working'    = 'Работает'
    'state.waiting'    = 'Ждёт ответа'
    'state.permission' = 'Нужно разрешение'
    'state.error'      = 'Ошибка'
}

# Маскоты шторки (ClaudeNotifier.Ui.Mascot.Kinds): 3D-сфинкс и плоские векторные.
$script:Mascots = @('flatsphynx', 'flame', 'boxcat', 'penguin', 'kitty', 'ghost', 'mochi', 'dino', 'frog', 'reaper', 'onigiri', 'cupcat', 'fox', 'leaf', 'bee')

function Get-NotifierDefaultConfig {
    <#
    .SYNOPSIS
    Возвращает новую копию настроек по умолчанию (те же значения, что в config.default.json).
    #>
    [CmdletBinding()]
    param()
    $events = @{}
    foreach ($t in $script:EventTypes) {
        $events[$t] = @{ enabled = $true; sound = '' }
    }
    return @{
        events          = $events
        limitThresholds = @(80, 90)
        previewLength   = 200
        chainStatusLine = $null   # прежний statusLine пользователя (объект из settings.json), вызывается перед нашим
        # Ответы из приложения: запросы разрешения (хук PermissionRequest ждёт решения до waitSeconds)
        # и быстрые ответы после «Готово» (хук Stop с asyncRewake ждёт до minutes минут).
        # cliWaitSeconds: в CLI хук может выполняться до показа диалога — по умолчанию не ждём, чтобы не задерживать его.
        # remindMinutes: запрос висит без ответа — повторить уведомление через столько минут (до 3 раз; 0 — не напоминать).
        approvals       = @{ enabled = $true; waitSeconds = 600; cliWaitSeconds = 0; remindMinutes = 3 }
        quickReplies    = @{ enabled = $true; minutes = 60; texts = @('Продолжай', 'Да', 'Нет') }   # texts — свои кнопки, 1–5 шт. до 40 знаков (в уведомлении Windows не больше 5)
        showPrompt      = $false  # хранить начало запроса пользователя для подробностей сеанса (по умолчанию нет — приватность)
        context         = @{ enabled = $true; warnPercent = 85 }   # уведомление «контекст почти заполнен» (скоро автосжатие)
        hotkey          = @{ enabled = $true; keys = 'auto' }      # keys — сочетание (Get-NotifierHotKeyChoices); auto — Win+Shift+C, а если занято — Ctrl+Alt+C
        stalled         = @{ enabled = $true; minutes = 10 }       # «Работает», но журнал молчит столько минут — «сеанс, похоже, остановился»
        longTasks       = @{ enabled = $true; minutes = 2 }        # «Готово» со звуком — только если Claude работал дольше (или вас нет за ПК)
        groups          = @{ enabled = $true; minSessions = 4 }    # от стольких сеансов — сеансы одного проекта сворачиваются в группу
        push            = @{ enabled = $false; url = ''; away = 5; preview = $false; remind = 30 }   # на телефон вне сети: url — тема ntfy или бот Telegram (lib\Push.psm1); away — только если вас нет за ПК столько минут (0 — всегда); preview — с текстом вопроса; remind — сеанс ждёт ответа дольше стольких минут: напомнить на телефон ещё раз (до 2 раз; 0 — нет)
        update          = @{ enabled = $true; channel = 'release' }   # раз в 6 ч проверять обновление на GitHub (app\version.json); channel — release (последний выпуск, иначе main) | main
        budget          = @{ enabled = $false; daily = 20 }        # расход за сегодня (примерно, по ценам API) дошёл до суммы, $ — одно уведомление в день
        inactive        = @{ enabled = $true; hours = 2 }          # «Ждёт ответа» дольше стольких часов — в свёрнутую строку «Неактивные»
        notch           = @{ enabled = $true; screen = ''; position = 'center'; mascot = 'flatsphynx'; mascots = @{}; stats = $true; attention = $true; sounds = $true; seasonal = $true; byProject = $false; limitResume = $true; digest = $true; digestHour = 18; inline = $true; theme = 'dark'; size = 'normal'; color = 'none' }   # theme — dark | light | auto (как в Windows); size — compact | normal | large   # inline — пока вы за ПК, уведомления показывает шторка (без всплывающих окон Windows)   # sounds — звуки маскота; seasonal — наряды (ночной колпак, праздники); digest — сводка дня во «выдохе» шторки после digestHour   # stats — загрузка ПК (ЦП, ГП, память) посередине свёрнутой шторки   # mascot — flatsphynx | flame | boxcat | penguin | kitty | ghost | mochi | dino | frog | reaper | onigiri | cupcat | fox | leaf | bee; mascots — свой у сеансов с других устройств: { id устройства: маскот }   # шторка вверху экрана; screen — имя монитора ('' — второй), position — left | center | right
        quiet           = @{ enabled = $false; schedule = '' }     # звук выключен (кнопка в шторке); schedule — ещё и по расписанию «HH:mm-HH:mm» ('' — нет)
        smartQuiet      = @{ enabled = $true }                     # игра на весь экран, презентация, звонок — уведомления копятся и приходят сводкой
        voice           = @{ enabled = $false; idle = 5 }          # вас нет за ПК дольше idle минут — ещё и голосом Windows
        projects        = @{}                                      # правила проектов: { имя проекта: important (без «Готово») | off }
    }
}

function Merge-OptionSection($Config, $User, [string]$Name, [hashtable]$Ranges, [string]$DataRoot) {
    # Раздел-объект с полем enabled (bool) и целыми полями из Ranges: @{ поле = @(min, max) }.
    $sec = Get-JsonProperty $User $Name
    if (-not $sec.found) { return }
    if ($sec.value -isnot [System.Management.Automation.PSCustomObject]) {
        Write-NotifierLog -Level WARN -Message "config.json: '$Name' должно быть объектом; используются значения по умолчанию" -DataRoot $DataRoot
        return
    }
    $enabled = Get-JsonProperty $sec.value 'enabled'
    if ($enabled.found) {
        if ($enabled.value -is [bool]) { $Config[$Name].enabled = $enabled.value }
        else { Write-NotifierLog -Level WARN -Message "config.json: '$Name.enabled' должно быть true/false" -DataRoot $DataRoot }
    }
    foreach ($field in $Ranges.Keys) {
        $v = Get-JsonProperty $sec.value $field
        if (-not $v.found) { continue }
        $r = $Ranges[$field]
        if ((Test-IsInteger $v.value) -and $v.value -ge $r[0] -and $v.value -le $r[1]) { $Config[$Name][$field] = [int]$v.value }
        else { Write-NotifierLog -Level WARN -Message "config.json: '$Name.$field' должно быть целым от $($r[0]) до $($r[1])" -DataRoot $DataRoot }
    }
}

function Set-NotifierConfigValue {
    <#
    .SYNOPSIS
    Меняет один верхнеуровневый ключ config.json, сохраняя остальные. Value = $null удаляет ключ.
    Повреждённый config.json не перезаписывается — выбрасывается исключение.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()]$Value,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    $path = Join-Path $DataRoot 'config.json'
    $obj = [pscustomobject]@{}
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
        if ($text.Trim() -ne '') {
            try { $obj = ConvertFrom-NotifierJson -InputObject $text }
            catch { throw "config.json повреждён ($path): исправьте или удалите файл" }
            if ($obj -isnot [System.Management.Automation.PSCustomObject]) { throw "config.json должен содержать JSON-объект ($path)" }
        }
    }
    elseif ($null -eq $Value) { return }
    if ($null -eq $Value) { $obj.PSObject.Properties.Remove($Name) }
    else { $obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $tmp = "$path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, ($obj | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    $script:ConfigMem = @{ Stamp = ''; Json = '' }   # записали — следующий вызов перечитает
}

function Get-NotifierEventTitle {
    <#
    .SYNOPSIS
    Возвращает русский заголовок для типа события: done, permission, error или limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('done', 'permission', 'error', 'limit')]
        [string]$Type
    )
    # Своя таблица, а не $NotifierStrings: переменная модуля бывает пустой, если модуль перезагружают с -Force.
    switch ($Type) { 'done' { return 'Готово' } 'permission' { return 'Нужно разрешение' } 'error' { return 'Ошибка' } 'limit' { return 'Лимит' } }
}

function Test-IsInteger($Value) {
    return ($Value -is [int] -or $Value -is [long])
}

function Get-JsonProperty($Object, [string]$Name) {
    # Возвращает @{ found; value } для свойства PSCustomObject, не падая в StrictMode.
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return @{ found = $false; value = $null } }
    return @{ found = $true; value = $prop.Value }
}

function Merge-EventsSection($Config, $UserEvents, [string]$DataRoot) {
    if ($UserEvents -isnot [System.Management.Automation.PSCustomObject]) {
        Write-NotifierLog -Level WARN -Message "config.json: 'events' должно быть объектом; используются значения по умолчанию" -DataRoot $DataRoot
        return
    }
    foreach ($t in $script:EventTypes) {
        $entry = Get-JsonProperty $UserEvents $t
        if (-not $entry.found) { continue }
        if ($entry.value -isnot [System.Management.Automation.PSCustomObject]) {
            Write-NotifierLog -Level WARN -Message "config.json: 'events.$t' должно быть объектом; используются значения по умолчанию" -DataRoot $DataRoot
            continue
        }
        $enabled = Get-JsonProperty $entry.value 'enabled'
        if ($enabled.found) {
            if ($enabled.value -is [bool]) { $Config.events[$t].enabled = $enabled.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'events.$t.enabled' должно быть true/false; используется значение по умолчанию" -DataRoot $DataRoot }
        }
        $sound = Get-JsonProperty $entry.value 'sound'
        if ($sound.found) {
            if ($sound.value -is [string]) { $Config.events[$t].sound = $sound.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'events.$t.sound' должно быть строкой; используется значение по умолчанию" -DataRoot $DataRoot }
        }
    }
}

$script:ConfigCodeStamp = ''
$script:ConfigMem = @{ Stamp = ''; Json = '' }   # итог настроек в памяти (Get-NotifierConfig)
try { $script:ConfigCodeStamp = [string][IO.File]::GetLastWriteTimeUtc($PSCommandPath).Ticks } catch { }

function Get-NotifierConfig {
    <#
    .SYNOPSIS
    Читает <DataRoot>\config.json и объединяет его с настройками по умолчанию (см. Get-NotifierConfigUncached).

    .DESCRIPTION
    Итог запоминается в <DataRoot>\cache\config.merged.json вместе с полным текстом config.json и отметкой версии
    этого модуля: мост хуков запускается на каждое событие, а первая проверка всех настроек в новом процессе
    PowerShell стоит ~60 мс. Кэш используется, только если текст config.json совпадает символ в символ.
    В долгоживущем трее итог ещё и в памяти (по размеру и времени изменения файла): настройки читаются много раз
    в секунду, а проверка времени файла дешевле чтения и разбора. Каждый вызов получает свою копию.
    #>
    [CmdletBinding()]
    param(
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    $path = [IO.Path]::Combine($DataRoot, 'config.json')   # не Join-Path: вызывается много раз в секунду
    $fi = New-Object System.IO.FileInfo $path
    if (-not $fi.Exists) { return (Get-NotifierDefaultConfig) }
    $fast = [bool]('ClaudeNotifier.JsonLite' -as [type])
    $stamp = "$DataRoot|$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
    if ($fast -and $script:ConfigMem.Stamp -ceq $stamp) {
        try { return [ClaudeNotifier.JsonLite]::Parse($script:ConfigMem.Json, $true) } catch { }
    }
    $text = $null
    try { $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) } catch { }
    $cache = Join-Path $DataRoot 'cache\config.merged.json'
    if ($fast -and $null -ne $text -and [IO.File]::Exists($cache)) {
        try {
            $c = [ClaudeNotifier.JsonLite]::Parse([IO.File]::ReadAllText($cache, [Text.Encoding]::UTF8), $true)
            if ($c -is [hashtable] -and [string]$c['ver'] -ceq $script:ConfigCodeStamp -and [string]$c['src'] -ceq $text -and $c['cfg'] -is [hashtable]) {
                $script:ConfigMem = @{ Stamp = $stamp; Json = [ClaudeNotifier.JsonLite]::Write($c['cfg']) }
                return $c['cfg']
            }
        }
        catch { }
    }
    $config = Get-NotifierConfigUncached -DataRoot $DataRoot -Text $text
    if ($fast -and $null -ne $text) {
        try {
            [void][IO.Directory]::CreateDirectory((Split-Path $cache))
            $tmp = "$cache.tmp-$PID"
            [IO.File]::WriteAllText($tmp, [ClaudeNotifier.JsonLite]::Write(@{ ver = $script:ConfigCodeStamp; src = $text; cfg = $config }), (New-Object System.Text.UTF8Encoding $false))
            Move-Item -LiteralPath $tmp -Destination $cache -Force
        }
        catch { }
        try { $script:ConfigMem = @{ Stamp = $stamp; Json = [ClaudeNotifier.JsonLite]::Write($config) } } catch { }
    }
    return $config
}

function Get-NotifierConfigUncached {
    <#
    .SYNOPSIS
    Читает <DataRoot>\config.json и объединяет его с настройками по умолчанию.

    .DESCRIPTION
    Каждое отсутствующее или неверное значение заменяется значением по умолчанию; о неверных
    значениях пишется WARN в лог. Функция не выбрасывает исключений из-за содержимого файла.
    Пороги лимитов сортируются и очищаются от повторов.

    .PARAMETER DataRoot
    Каталог данных; по умолчанию Get-NotifierDataRoot.

    .OUTPUTS
    Hashtable: events.<type>.enabled / .sound, limitThresholds, previewLength.
    #>
    [CmdletBinding()]
    param(
        [string]$DataRoot = (Get-NotifierDataRoot),
        [AllowNull()][string]$Text = $null   # уже прочитанный config.json (иначе читается здесь)
    )

    $config = Get-NotifierDefaultConfig
    $path = Join-Path $DataRoot 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $config
    }

    try {
        if ([string]::IsNullOrEmpty($Text)) { $Text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) }
        $user = ConvertFrom-NotifierJson -InputObject $Text
    }
    catch {
        Write-NotifierLog -Level WARN -Message "config.json не разобран ($($_.Exception.Message)); используются значения по умолчанию" -DataRoot $DataRoot
        return $config
    }
    if ($user -isnot [System.Management.Automation.PSCustomObject]) {
        Write-NotifierLog -Level WARN -Message 'config.json должен содержать объект; используются значения по умолчанию' -DataRoot $DataRoot
        return $config
    }

    $preview = Get-JsonProperty $user 'previewLength'
    if ($preview.found) {
        $v = $preview.value
        if ((Test-IsInteger $v) -and $v -ge $script:PreviewLengthMin -and $v -le $script:PreviewLengthMax) {
            $config.previewLength = [int]$v
        }
        else {
            Write-NotifierLog -Level WARN -Message "config.json: 'previewLength' должно быть целым от $($script:PreviewLengthMin) до $($script:PreviewLengthMax); используется $($config.previewLength)" -DataRoot $DataRoot
        }
    }

    $thresholds = Get-JsonProperty $user 'limitThresholds'
    if ($thresholds.found) {
        $list = @($thresholds.value)
        $valid = ($thresholds.value -is [array]) -and $list.Count -gt 0
        foreach ($x in $list) {
            if (-not ((Test-IsInteger $x) -and $x -ge 1 -and $x -le 100)) { $valid = $false }
        }
        if ($valid) {
            $config.limitThresholds = @($list | ForEach-Object { [int]$_ } | Sort-Object -Unique)
        }
        else {
            Write-NotifierLog -Level WARN -Message "config.json: 'limitThresholds' должно быть непустым списком целых от 1 до 100; используется [80, 90]" -DataRoot $DataRoot
        }
    }

    $events = Get-JsonProperty $user 'events'
    if ($events.found) {
        Merge-EventsSection $config $events.value $DataRoot
    }

    $chain = Get-JsonProperty $user 'chainStatusLine'
    if ($chain.found -and $null -ne $chain.value) {
        $cmd = $null
        if ($chain.value -is [System.Management.Automation.PSCustomObject]) { $cmd = $chain.value.PSObject.Properties['command'] }
        if ($cmd -and $cmd.Value -is [string] -and $cmd.Value.Trim() -ne '') { $config.chainStatusLine = $chain.value }
        else {
            Write-NotifierLog -Level WARN -Message "config.json: 'chainStatusLine' должно быть объектом с полем command; прежняя строка статуса не вызывается" -DataRoot $DataRoot
        }
    }

    Merge-OptionSection $config $user 'approvals' @{ waitSeconds = @(10, 3600); cliWaitSeconds = @(0, 3600); remindMinutes = @(0, 120) } $DataRoot
    Merge-OptionSection $config $user 'context' @{ warnPercent = @(50, 99) } $DataRoot
    Merge-OptionSection $config $user 'hotkey' @{} $DataRoot
    Merge-OptionSection $config $user 'stalled' @{ minutes = @(3, 120) } $DataRoot
    Merge-OptionSection $config $user 'longTasks' @{ minutes = @(1, 60) } $DataRoot
    Merge-OptionSection $config $user 'groups' @{ minSessions = @(2, 20) } $DataRoot
    Merge-OptionSection $config $user 'inactive' @{ hours = @(1, 72) } $DataRoot
    Merge-OptionSection $config $user 'budget' @{ daily = @(1, 10000) } $DataRoot
    Merge-OptionSection $config $user 'push' @{ away = @(0, 240); remind = @(0, 720) } $DataRoot
    Merge-OptionSection $config $user 'update' @{} $DataRoot
    $upd = Get-JsonProperty $user 'update'
    if ($upd.found -and $upd.value -is [System.Management.Automation.PSCustomObject]) {
        $ch = Get-JsonProperty $upd.value 'channel'
        if ($ch.found) {
            if (@('release', 'main') -contains [string]$ch.value) { $config.update.channel = [string]$ch.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'update.channel' должно быть release или main" -DataRoot $DataRoot }
        }
    }
    $push = Get-JsonProperty $user 'push'
    if ($push.found -and $push.value -is [System.Management.Automation.PSCustomObject]) {
        $u = Get-JsonProperty $push.value 'url'
        if ($u.found) {
            if ($u.value -is [string] -and $u.value.Length -le 300 -and $u.value -notmatch '[\x00-\x20]') { $config.push.url = $u.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'push.url' должно быть адресом без пробелов" -DataRoot $DataRoot }
        }
        $pv = Get-JsonProperty $push.value 'preview'
        if ($pv.found -and $pv.value -is [bool]) { $config.push.preview = $pv.value }
    }
    Merge-OptionSection $config $user 'notch' @{ digestHour = @(0, 23) } $DataRoot
    Merge-OptionSection $config $user 'quiet' @{} $DataRoot
    $hk = Get-JsonProperty $user 'hotkey'
    if ($hk.found -and $hk.value -is [System.Management.Automation.PSCustomObject]) {
        $keys = Get-JsonProperty $hk.value 'keys'
        if ($keys.found) {
            if ((Get-NotifierHotKeyChoices) -contains [string]$keys.value) { $config.hotkey.keys = [string]$keys.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'hotkey.keys' — неизвестное сочетание, используется auto" -DataRoot $DataRoot }
        }
    }
    $q = Get-JsonProperty $user 'quiet'
    if ($q.found -and $q.value -is [System.Management.Automation.PSCustomObject]) {
        $sch = Get-JsonProperty $q.value 'schedule'
        if ($sch.found) {
            if ([string]$sch.value -eq '' -or [string]$sch.value -match '^([01]\d|2[0-3]):[0-5]\d-([01]\d|2[0-3]):[0-5]\d$') { $config.quiet.schedule = [string]$sch.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'quiet.schedule' должно быть «HH:mm-HH:mm» или пустой строкой" -DataRoot $DataRoot }
        }
    }
    $notch = Get-JsonProperty $user 'notch'
    if ($notch.found -and $notch.value -is [System.Management.Automation.PSCustomObject]) {
        $scr = Get-JsonProperty $notch.value 'screen'
        if ($scr.found -and $scr.value -is [string]) { $config.notch.screen = $scr.value }
        $att = Get-JsonProperty $notch.value 'attention'
        if ($att.found) {
            if ($att.value -is [bool]) { $config.notch.attention = $att.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.attention' должно быть true/false" -DataRoot $DataRoot }
        }
        foreach ($flag in @('sounds', 'seasonal', 'digest', 'inline', 'byProject', 'limitResume')) {
            $fv = Get-JsonProperty $notch.value $flag
            if (-not $fv.found) { continue }
            if ($fv.value -is [bool]) { $config.notch[$flag] = $fv.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.$flag' должно быть true/false" -DataRoot $DataRoot }
        }
        $stats = Get-JsonProperty $notch.value 'stats'
        if ($stats.found) {
            if ($stats.value -is [bool]) { $config.notch.stats = $stats.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.stats' должно быть true/false" -DataRoot $DataRoot }
        }
        foreach ($pair in @(@('theme', @('dark', 'light', 'auto')), @('size', @('compact', 'normal', 'large')), @('color', @('none', 'h60', 'h120', 'h180', 'h240', 'h300', 'pastel', 'mono')))) {
            $pv = Get-JsonProperty $notch.value $pair[0]
            if (-not $pv.found) { continue }
            if ($pair[1] -contains [string]$pv.value) { $config.notch[$pair[0]] = [string]$pv.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.$($pair[0])' должно быть одним из: $($pair[1] -join ', ')" -DataRoot $DataRoot }
        }
        $pos = Get-JsonProperty $notch.value 'position'
        if ($pos.found) {
            if (@('left', 'center', 'right') -contains [string]$pos.value) { $config.notch.position = [string]$pos.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.position' должно быть left, center или right" -DataRoot $DataRoot }
        }
        $mascot = Get-JsonProperty $notch.value 'mascot'
        if ($mascot.found -and [string]$mascot.value -eq 'sphynx') { $mascot.value = 'flatsphynx' }   # объёмного сфинкса больше нет
        if ($mascot.found) {
            if ($script:Mascots -contains [string]$mascot.value) { $config.notch.mascot = [string]$mascot.value }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'notch.mascot' должно быть одним из: $($script:Mascots -join ', ')" -DataRoot $DataRoot }
        }
        $mascots = Get-JsonProperty $notch.value 'mascots'
        if ($mascots.found -and $mascots.value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($p in $mascots.value.PSObject.Properties) {
                $mv = [string]$p.Value; if ($mv -eq 'sphynx') { $mv = 'flatsphynx' }
                if ($script:Mascots -contains $mv) { $config.notch.mascots[[string]$p.Name] = $mv }
            }
        }
    }
    Merge-OptionSection $config $user 'smartQuiet' @{} $DataRoot
    Merge-OptionSection $config $user 'voice' @{ idle = @(1, 120) } $DataRoot
    $pr = Get-JsonProperty $user 'projects'
    if ($pr.found -and $pr.value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $pr.value.PSObject.Properties) {
            $name = [string]$p.Name
            if ($name.Length -gt 0 -and $name.Length -le 200 -and @('important', 'off') -contains [string]$p.Value) { $config.projects[$name] = [string]$p.Value }
        }
    }
    elseif ($pr.found -and $null -ne $pr.value) { Write-NotifierLog -Level WARN -Message "config.json: 'projects' должно быть объектом { проект: important | off }" -DataRoot $DataRoot }
    Merge-OptionSection $config $user 'quickReplies' @{ minutes = @(1, 240) } $DataRoot
    # Свои тексты быстрых ответов: непустые строки до 40 знаков, не больше 5; иначе — по умолчанию.
    $qr = Get-JsonProperty $user 'quickReplies'
    if ($qr.found -and $qr.value -is [System.Management.Automation.PSCustomObject]) {
        $tx = Get-JsonProperty $qr.value 'texts'
        if ($tx.found) {
            $list = @(@($tx.value) | Where-Object { $_ -is [string] } | ForEach-Object { ($_ -replace '[\x00-\x1f|]', ' ').Trim() } | Where-Object { $_ -ne '' -and $_.Length -le 40 } | Select-Object -First 5)
            if ($list.Count -gt 0) { $config.quickReplies.texts = $list }
            else { Write-NotifierLog -Level WARN -Message "config.json: 'quickReplies.texts' — список строк до 40 знаков; используются ответы по умолчанию" -DataRoot $DataRoot }
        }
    }
    $showPrompt = Get-JsonProperty $user 'showPrompt'
    if ($showPrompt.found) {
        if ($showPrompt.value -is [bool]) { $config.showPrompt = $showPrompt.value }
        else { Write-NotifierLog -Level WARN -Message "config.json: 'showPrompt' должно быть true/false" -DataRoot $DataRoot }
    }

    return $config
}

function Get-NotifierHookPort {
    <# .SYNOPSIS Порт на 127.0.0.1, куда хуки (curl.exe) отправляют события трею. #>
    return 47611
}

function Get-NotifierHotKeyChoices {
    <# .SYNOPSIS Сочетания, которые можно выбрать для горячей клавиши шторки (auto — Win+Shift+C, иначе Ctrl+Alt+C). #>
    return @('auto', 'Win+Shift+C', 'Ctrl+Alt+C', 'Ctrl+Shift+Space', 'Win+Alt+C', 'Ctrl+Alt+Space')
}

function Test-NotifierQuietTime {
    <#
    .SYNOPSIS
    Звук сейчас выключен? Кнопка «Без звука» или расписание quiet.schedule «HH:mm-HH:mm» (через полночь — тоже:
    23:00-08:00 значит с вечера до утра). Время — местное.
    #>
    param([Parameter(Mandatory = $true)]$Config, [datetime]$Now = [DateTime]::Now)
    if ($Config.quiet.enabled) { return $true }
    $s = [string]$Config.quiet.schedule
    if ($s -notmatch '^(\d\d):(\d\d)-(\d\d):(\d\d)$') { return $false }
    $from = [int]$Matches[1] * 60 + [int]$Matches[2]
    $to = [int]$Matches[3] * 60 + [int]$Matches[4]
    $m = $Now.Hour * 60 + $Now.Minute
    if ($from -eq $to) { return $false }
    if ($from -lt $to) { return ($m -ge $from -and $m -lt $to) }
    return ($m -ge $from -or $m -lt $to)
}

function Get-NotifierHookSecret {
    <#
    .SYNOPSIS
    Секрет хуков: curl.exe шлёт его в заголовке X-Claude-Notifier, и трей принимает только такие запросы —
    чужой процесс или другой пользователь Windows не подделает событие. Хранится в <DataRoot>\hook-secret
    (папка профиля, доступна только владельцу). -Create — создать, если файла нет (установщик).
    Нет файла и без -Create → '' (старая установка: трей принимает прежний заголовок «hook»).
    #>
    param([string]$DataRoot = (Get-NotifierDataRoot), [switch]$Create)
    $path = Join-Path $DataRoot 'hook-secret'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $s = ([IO.File]::ReadAllText($path)).Trim()
        if ($s -match '^[A-Za-z0-9_-]{32,64}$') { return $s }
    }
    if (-not $Create) { return '' }
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $s = ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    [IO.File]::WriteAllText($path, $s, (New-Object System.Text.UTF8Encoding $false))
    return $s
}

Export-ModuleMember -Function Get-NotifierHookPort, Get-NotifierHookSecret, Get-NotifierHotKeyChoices, Test-NotifierQuietTime, Get-NotifierDefaultConfig, Get-NotifierConfig, Get-NotifierEventTitle, Set-NotifierConfigValue -Variable NotifierStrings
