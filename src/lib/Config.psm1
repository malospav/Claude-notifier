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
        quickReplies    = @{ enabled = $true; minutes = 60 }
        showPrompt      = $false  # хранить начало запроса пользователя для подробностей сеанса (по умолчанию нет — приватность)
        context         = @{ enabled = $true; warnPercent = 85 }   # уведомление «контекст почти заполнен» (скоро автосжатие)
        hotkey          = @{ enabled = $true }                     # Win+Shift+C — мини-окно у трея
        stalled         = @{ enabled = $true; minutes = 10 }       # «Работает», но журнал молчит столько минут — «сеанс, похоже, остановился»
        longTasks       = @{ enabled = $true; minutes = 2 }        # «Готово» со звуком — только если Claude работал дольше (или вас нет за ПК)
        groups          = @{ enabled = $true; minSessions = 4 }    # от стольких сеансов — сеансы одного проекта сворачиваются в группу
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
            try { $obj = $text | ConvertFrom-Json -ErrorAction Stop }
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

function Get-NotifierConfig {
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
        [string]$DataRoot = (Get-NotifierDataRoot)
    )

    $config = Get-NotifierDefaultConfig
    $path = Join-Path $DataRoot 'config.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return $config
    }

    try {
        $user = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
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
    Merge-OptionSection $config $user 'quickReplies' @{ minutes = @(1, 240) } $DataRoot
    $showPrompt = Get-JsonProperty $user 'showPrompt'
    if ($showPrompt.found) {
        if ($showPrompt.value -is [bool]) { $config.showPrompt = $showPrompt.value }
        else { Write-NotifierLog -Level WARN -Message "config.json: 'showPrompt' должно быть true/false" -DataRoot $DataRoot }
    }

    return $config
}

Export-ModuleMember -Function Get-NotifierDefaultConfig, Get-NotifierConfig, Get-NotifierEventTitle, Set-NotifierConfigValue -Variable NotifierStrings
