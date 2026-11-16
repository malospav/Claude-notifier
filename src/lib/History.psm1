Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# history.json — JSON-массив событий v1 (старые первыми) с необязательным полем status.
# Пишут два процесса (трей добавляет, focus-handler меняет status); запись атомарная (temp + replace).
$script:MaxItems = 100

function Get-HistoryPath([string]$DataRoot) { return (Join-Path $DataRoot 'history.json') }

function Get-NotifierHistory {
    <#
    .SYNOPSIS
    Читает историю (события выводятся в конвейер по одному; вызывающий оборачивает в @()).
    Нет файла → ничего. Повреждённый файл → переименовывается
    в history.json.corrupt, пишется WARN, возвращается пустой массив.
    #>
    [CmdletBinding()]
    param([string]$DataRoot = (Get-NotifierDataRoot))
    $path = Get-HistoryPath $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
    $parsed = $null
    $ok = $true
    try { $parsed = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop }
    catch { $ok = $false }
    if ($ok -and $null -ne $parsed -and $parsed -isnot [array]) { $ok = $false }
    if (-not $ok) {
        try { Move-Item -LiteralPath $path -Destination "$path.corrupt" -Force } catch { }
        Write-NotifierLog -Level WARN -Message 'history: history.json повреждён, переименован в history.json.corrupt; история начата заново' -DataRoot $DataRoot
        return
    }
    $items = @()
    foreach ($x in @($parsed)) {
        if ($x -is [System.Management.Automation.PSCustomObject]) { $items += $x }
    }
    return $items
}

function Save-NotifierHistory {
    <# .SYNOPSIS Атомарно записывает массив событий в history.json. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Items,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $path = Get-HistoryPath $DataRoot
    $tmp = "$path.tmp-$PID-$([guid]::NewGuid().ToString('N'))"
    $json = '[]'
    if ($Items.Count -gt 0) { $json = ConvertTo-Json -InputObject @($Items) -Depth 6 -Compress }
    [IO.File]::WriteAllText($tmp, $json, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Add-NotifierHistory {
    <#
    .SYNOPSIS
    Добавляет событие в конец истории; хранится не больше Max последних.

    .OUTPUTS
    Число событий в истории после добавления.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Event,
        [string]$DataRoot = (Get-NotifierDataRoot),
        [int]$Max = $script:MaxItems
    )
    $items = @(Get-NotifierHistory -DataRoot $DataRoot) + @($Event)
    if ($items.Count -gt $Max) { $items = $items[($items.Count - $Max)..($items.Count - 1)] }
    Save-NotifierHistory -Items $items -DataRoot $DataRoot
    return $items.Count
}

function Find-NotifierHistoryEvent {
    <# .SYNOPSIS Событие по id или $null. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id, [string]$DataRoot = (Get-NotifierDataRoot))
    foreach ($x in (Get-NotifierHistory -DataRoot $DataRoot)) {
        if ($x.PSObject.Properties['id'] -and [string]$x.id -eq $Id) { return $x }
    }
    return $null
}

function Set-NotifierHistoryStatus {
    <#
    .SYNOPSIS
    Ставит событию поле status (например, closed). Возвращает $true, если событие найдено.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Status,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    $items = @(Get-NotifierHistory -DataRoot $DataRoot)
    $found = $false
    foreach ($x in $items) {
        if ($x.PSObject.Properties['id'] -and [string]$x.id -eq $Id) {
            $x | Add-Member -NotePropertyName status -NotePropertyValue $Status -Force
            $found = $true
        }
    }
    if ($found) { Save-NotifierHistory -Items $items -DataRoot $DataRoot }
    return $found
}

function Format-NotifierHistoryItem {
    <#
    .SYNOPSIS
    Текст пункта меню: «HH:mm · <Тип> · <project>» (локальное время), у закрытых — « (закрыта)».
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Event)
    $time = '--:--'
    $ts = $Event.PSObject.Properties['ts']
    $parsed = [DateTimeOffset]::MinValue
    if ($ts -and [DateTimeOffset]::TryParse([string]$ts.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        $time = $parsed.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    }
    $type = [string]$Event.type
    $title = $type
    if ($NotifierStrings.ContainsKey($type)) { $title = $NotifierStrings[$type] }
    $parts = @($time, $title)
    $project = $Event.PSObject.Properties['project']
    if ($project -and [string]$project.Value -ne '') { $parts += [string]$project.Value }
    $text = $parts -join " $([char]0x00B7) "
    $status = $Event.PSObject.Properties['status']
    if ($status -and $status.Value -eq 'closed') { $text += ' (закрыта)' }
    return $text
}

Export-ModuleMember -Function Get-NotifierHistory, Save-NotifierHistory, Add-NotifierHistory, Find-NotifierHistoryEvent, Set-NotifierHistoryStatus, Format-NotifierHistoryItem
