Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Window.psm1')

# sessions.json — JSON-массив активных сеансов Claude. Пишет только трей (один процесс),
# поэтому гонок записи нет. Поля: session_id, project, origin, device, state, since, updated, preview, window.
# state: working | waiting | permission | error. Завершённые сеансы из списка удаляются.

# Тип события → статус сеанса ($null — событие статус не меняет).
$script:TypeToState = @{
    start      = 'waiting'
    working    = 'working'
    done       = 'waiting'
    permission = 'permission'
    error      = 'error'
    request    = 'permission'   # запрос разрешения, на который можно ответить из приложения
}
# Порядок в окне: сначала те, что ждут человека.
$script:StateOrder = @{ permission = 0; error = 1; waiting = 2; working = 3 }
$script:MaxIdleHours = 24

function Get-SessionsPath([string]$DataRoot) { return (Join-Path $DataRoot 'sessions.json') }

function ConvertTo-UtcTime([string]$Ts) {
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
    return $null
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-NotifierSessions {
    <#
    .SYNOPSIS
    Читает sessions.json (сеансы выводятся в конвейер по одному; вызывающий оборачивает в @()).
    Нет файла или файл повреждён → ничего (повреждённый файл удаляется, WARN в лог).
    #>
    [CmdletBinding()]
    param([string]$DataRoot = (Get-NotifierDataRoot))
    $path = Get-SessionsPath $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $text = $null
    for ($i = 0; $i -lt 3 -and $null -eq $text; $i++) {
        try { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
        catch [IO.IOException], [UnauthorizedAccessException] { Start-Sleep -Milliseconds 50 }
    }
    if ($null -eq $text) { return }   # временно занят — не путать с повреждением
    try { $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch {
        try { Remove-Item -LiteralPath $path -Force } catch { }
        Write-NotifierLog -Level WARN -Message 'sessions: sessions.json повреждён и удалён' -DataRoot $DataRoot
        return
    }
    foreach ($x in @($parsed)) {
        if ($x -is [System.Management.Automation.PSCustomObject] -and (Get-Prop $x 'session_id') -is [string]) { $x }
    }
}

function Save-NotifierSessions {
    <# .SYNOPSIS Атомарно записывает список сеансов в sessions.json. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $path = Get-SessionsPath $DataRoot
    $tmp = "$path.tmp-$PID"
    $json = '[]'
    if ($Sessions.Count -gt 0) { $json = ConvertTo-Json -InputObject @($Sessions) -Depth 6 -Compress }
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Update-NotifierSessionList {
    <#
    .SYNOPSIS
    Применяет событие к списку сеансов и возвращает новый список (исходный не меняется).

    .DESCRIPTION
    end → сеанс удаляется. start/working/done/permission/error → сеанс создаётся или обновляется:
    статус, время смены статуса (since), время события (updated), окно (если найдено).
    done обновляет превью последнего ответа. Событие без session_id и limit список не меняют.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory = $true)]$Event
    )
    $sid = Get-Prop $Event 'session_id'
    $type = [string](Get-Prop $Event 'type')
    if ($sid -isnot [string] -or $sid -eq '') { return , @($Sessions) }
    $others = @($Sessions | Where-Object { [string](Get-Prop $_ 'session_id') -ne $sid })
    if ($type -eq 'end') { return , $others }
    if (-not $script:TypeToState.ContainsKey($type)) { return , @($Sessions) }

    $ts = [string](Get-Prop $Event 'ts')
    if ($ts -eq '') { $ts = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    $old = @($Sessions | Where-Object { [string](Get-Prop $_ 'session_id') -eq $sid }) | Select-Object -First 1
    $state = $script:TypeToState[$type]

    $since = $ts
    if ($old -and (Get-Prop $old 'state') -eq $state -and (Get-Prop $old 'since')) { $since = [string](Get-Prop $old 'since') }
    $preview = ''
    if ($old) { $preview = [string](Get-Prop $old 'preview') }
    if ($type -eq 'done') { $preview = [string](Get-Prop $Event 'preview') }
    $window = $null
    if ($old) { $window = Get-Prop $old 'window' }
    $evWindow = Get-Prop $Event 'window'
    if ($evWindow -and [int64](Get-Prop $evWindow 'hwnd') -ne 0) {
        $window = [pscustomobject][ordered]@{ hwnd = [int64](Get-Prop $evWindow 'hwnd'); pid = [int](Get-Prop $evWindow 'pid') }
    }
    $project = [string](Get-Prop $Event 'project')
    if ($project -eq '' -and $old) { $project = [string](Get-Prop $old 'project') }
    $origin = [string](Get-Prop $Event 'origin')
    if ($origin -eq '' -and $old) { $origin = [string](Get-Prop $old 'origin') }
    $device = [string](Get-Prop $Event 'device')   # '' — этот ПК; иначе id устройства из network.json
    # Служебные события без поля device («Работает» после ответа из шторки или с телефона) устройство сеанса
    # не меняют: иначе сеанс Mac после ответа «переезжал» бы на этот ПК.
    if ($null -eq $Event.PSObject.Properties['device'] -and $old) { $device = [string](Get-Prop $old 'device') }

    # Подробности: начало сеанса (первое событие или начало журнала), статистика журнала, последний запрос.
    $started = $ts
    if ($old -and (Get-Prop $old 'started')) { $started = [string](Get-Prop $old 'started') }
    $stats = $null
    if ($old) { $stats = Get-Prop $old 'stats' }
    $evStats = Get-Prop $Event 'stats'
    if ($evStats) {
        $stats = $evStats
        $st = [string](Get-Prop $evStats 'started')
        if ($st -ne '') { $started = $st }
    }
    $transcript = ''
    if ($old) { $transcript = [string](Get-Prop $old 'transcript') }
    if (Get-Prop $Event 'transcript') { $transcript = [string](Get-Prop $Event 'transcript') }
    # С какого момента Claude занят задачей: начало работы после ожидания (переходы «работает» ↔ «нужно разрешение» — та же задача).
    $busy = ''
    if ($old) { $busy = [string](Get-Prop $old 'busySince') }
    if ($state -eq 'working' -and ($busy -eq '' -or -not $old -or @('working', 'permission') -notcontains [string](Get-Prop $old 'state'))) { $busy = $ts }
    $agents = @()
    if ($old -and (Get-Prop $old 'agents')) { $agents = @(Get-Prop $old 'agents') }   # активные агенты — обновляет трей раз в 15 с
    $prompt = ''
    if ($old) { $prompt = [string](Get-Prop $old 'prompt') }
    if (Get-Prop $Event 'prompt') { $prompt = [string](Get-Prop $Event 'prompt') }

    $session = [pscustomobject][ordered]@{
        session_id = $sid
        project    = $project
        origin     = $origin
        device     = $device
        state      = $state
        since      = $since
        updated    = $ts
        started    = $started
        busySince  = $busy
        preview    = $preview
        prompt     = $prompt
        stats      = $stats
        agents     = $agents
        transcript = $transcript
        window     = $window
    }
    return , @($others + $session)
}

function Test-NotifierSessionAlive {
    <#
    .SYNOPSIS
    Жив ли сеанс: процесс claude.exe (если известен pid) существует и окно (если известно) открыто.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Session)
    $win = Get-Prop $Session 'window'
    if ($null -eq $win) { return $true }
    $procId = [int](Get-Prop $win 'pid')
    if ($procId -gt 0) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($null -eq $proc -or $proc.ProcessName -notlike 'claude*') { return $false }
    }
    $hwnd = [int64](Get-Prop $win 'hwnd')
    if ($hwnd -ne 0 -and -not (Test-SessionWindow -Hwnd $hwnd)) { return $false }
    return $true
}

function Select-NotifierLiveSessions {
    <#
    .SYNOPSIS
    Отбрасывает завершившиеся сеансы: процесс или окно закрыты либо событий не было MaxIdleHours часов.
    Возвращает новый список.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [datetime]$Now = [DateTime]::UtcNow,
        [int]$MaxIdleHours = $script:MaxIdleHours
    )
    $live = @()
    foreach ($s in $Sessions) {
        $updated = ConvertTo-UtcTime ([string](Get-Prop $s 'updated'))
        if ($null -ne $updated -and ($Now - $updated).TotalHours -ge $MaxIdleHours) { continue }
        if (-not (Test-NotifierSessionAlive -Session $s)) { continue }
        $live += $s
    }
    return , $live
}

function Get-NotifierSortedSessions {
    <# .SYNOPSIS Порядок для окна: закреплённые; затем нужно разрешение, ошибка, ждёт ответа, работает; внутри — новые выше. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions, [string[]]$Pinned = @())
    $script:SortPinned = @($Pinned)
    $sorted = @($Sessions | Sort-Object -Property @(
            @{ Expression = { if ($script:SortPinned -contains [string](Get-Prop $_ 'session_id')) { 0 } else { 1 } } },
            @{ Expression = { $o = $script:StateOrder[[string](Get-Prop $_ 'state')]; if ($null -eq $o) { 9 } else { $o } } },
            @{ Expression = { [string](Get-Prop $_ 'updated') }; Descending = $true }))
    return , $sorted
}

function Format-NotifierElapsed {
    <# .SYNOPSIS «только что», «5 мин», «2 ч 05 мин», «3 дн» — сколько прошло с Ts. #>
    [CmdletBinding()]
    param([AllowEmptyString()][string]$Ts, [datetime]$Now = [DateTime]::UtcNow)
    $t = ConvertTo-UtcTime $Ts
    if ($null -eq $t) { return '' }
    $span = $Now - $t
    if ($span.TotalMinutes -lt 1) { return 'только что' }
    if ($span.TotalHours -lt 1) { return "$([int][Math]::Floor($span.TotalMinutes)) мин" }
    if ($span.TotalDays -lt 1) { return ('{0} ч {1:00} мин' -f [int][Math]::Floor($span.TotalHours), $span.Minutes) }
    return "$([int][Math]::Floor($span.TotalDays)) дн"
}

function Get-NotifierAgentsStateText {
    <# .SYNOPSIS Статус работающего сеанса с агентами: «Работает агент», «Работают агенты · 3»; без агентов — ''. #>
    param($Session)
    if ([string](Get-Prop $Session 'state') -ne 'working') { return '' }
    $n = @(@(Get-Prop $Session 'agents') | Where-Object { $_ }).Count
    if ($n -eq 0) { return '' }
    if ($n -eq 1) { return 'Работает агент' }
    return "Работают агенты $([char]0x00B7) $n"
}

function Get-NotifierSessionStateText {
    <# .SYNOPSIS Русское название статуса сеанса. #>
    param([string]$State)
    # Своя таблица, а не переменная из Config.psm1: импортированная переменная обнуляется,
    # если Config перезагружают с -Force (так делают тесты).
    $names = @{ working = 'Работает'; waiting = 'Ждёт ответа'; permission = 'Нужно разрешение'; error = 'Ошибка' }
    if ($names.ContainsKey($State)) { return $names[$State] }
    return $State
}

# session-prefs.json — что пользователь задал сеансу: своё имя, закрепление, без уведомлений.
# Отдельно от sessions.json: настройки переживают завершение и возобновление сеанса (claude --resume).
$script:PrefsKeepDays = 30

function Get-NotifierSessionPrefs {
    <# .SYNOPSIS Настройки сеансов: hashtable session_id → @{ title; pinned; muted; updated }. #>
    [CmdletBinding()]
    param([string]$DataRoot = (Get-NotifierDataRoot), [switch]$ForWrite)
    $prefs = @{}
    $path = Join-Path $DataRoot 'session-prefs.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $prefs }
    # Занят другим процессом: чтение повторяется; не вышло — читателям пусто, а запись (-ForWrite) прерывается,
    # иначе Set-NotifierSessionPref перезаписал бы файл и стёр все настройки.
    $text = $null
    for ($i = 0; $null -eq $text; $i++) {
        try { $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8) }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if ($i -ge 2) { if ($ForWrite) { throw }; return $prefs }
            Start-Sleep -Milliseconds 50
        }
    }
    try { $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop }
    catch {
        # Повреждён: сохранить копию для разбора, а не молча перезаписать при следующем изменении.
        try { Move-Item -LiteralPath $path -Destination "$path.corrupt" -Force } catch { }
        Write-NotifierLog -Level WARN -Message 'sessions: session-prefs.json повреждён, переименован в session-prefs.json.corrupt' -DataRoot $DataRoot
        return $prefs
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $prefs }
    foreach ($p in $obj.PSObject.Properties) {
        $v = $p.Value
        $prefs[$p.Name] = @{ title = [string](Get-Prop $v 'title'); pinned = [bool](Get-Prop $v 'pinned'); muted = [bool](Get-Prop $v 'muted'); updated = [string](Get-Prop $v 'updated') }
    }
    return $prefs
}

function Set-NotifierSessionPref {
    <#
    .SYNOPSIS
    Меняет настройку сеанса: title (пустая строка — вернуть имя проекта), pinned, muted. Записи без настроек
    и старше 30 дней удаляются.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][ValidateSet('title', 'pinned', 'muted')][string]$Name,
        [AllowEmptyString()]$Value,
        [string]$DataRoot = (Get-NotifierDataRoot),
        [datetime]$Now = [DateTime]::UtcNow
    )
    $prefs = Get-NotifierSessionPrefs -DataRoot $DataRoot -ForWrite
    if (-not $prefs.ContainsKey($SessionId)) { $prefs[$SessionId] = @{ title = ''; pinned = $false; muted = $false; updated = '' } }
    if ($Name -eq 'title') { $prefs[$SessionId].title = ([string]$Value).Trim() } else { $prefs[$SessionId][$Name] = [bool]$Value }
    $prefs[$SessionId].updated = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $out = [ordered]@{}
    foreach ($k in @($prefs.Keys | Sort-Object)) {
        $e = $prefs[$k]
        if ($e.title -eq '' -and -not $e.pinned -and -not $e.muted) { continue }
        # Старше 30 дней удаляются только переименования: закрепление и «без уведомлений» — явный выбор, он не истекает.
        $u = ConvertTo-UtcTime $e.updated
        if (-not $e.pinned -and -not $e.muted -and $null -ne $u -and ($Now - $u).TotalDays -gt $script:PrefsKeepDays) { continue }
        $out[$k] = [ordered]@{ title = $e.title; pinned = $e.pinned; muted = $e.muted; updated = $e.updated }
    }
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $path = Join-Path $DataRoot 'session-prefs.json'
    $tmp = "$path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $out -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

Export-ModuleMember -Function Get-NotifierAgentsStateText, Get-NotifierSessionPrefs, Set-NotifierSessionPref, Get-NotifierSessions, Save-NotifierSessions, Update-NotifierSessionList, Test-NotifierSessionAlive, Select-NotifierLiveSessions, Get-NotifierSortedSessions, Format-NotifierElapsed, Get-NotifierSessionStateText
