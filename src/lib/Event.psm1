Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

$script:KindToType = @{
    stop         = 'done'
    notification = 'permission'
    stopfailure  = 'error'
    # Служебные события для окна «Сеансы»: без уведомления и без записи в историю.
    sessionstart = 'start'
    prompt       = 'working'
    sessionend   = 'end'
    permreq      = 'request'   # запрос разрешения, на который можно ответить из приложения
}

function Get-InputString($Object, [string]$Name) {
    # Значение строкового поля входа хука или $null, если поля нет или это не строка.
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop -or $prop.Value -isnot [string]) { return $null }
    return $prop.Value
}

function Format-NotifierPreview {
    <#
    .SYNOPSIS
    Готовит превью: переводы строк и табуляции → пробел, повторные пробелы схлопываются,
    текст длиннее MaxLength обрезается до MaxLength символов с «…» в конце.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory = $true)][ValidateRange(2, 100000)][int]$MaxLength
    )
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $flat = ([regex]::Replace($Text, '\s+', ' ')).Trim()
    if ($flat.Length -le $MaxLength) { return $flat }
    return $flat.Substring(0, $MaxLength - 1).TrimEnd() + [char]0x2026
}

function Get-ProjectName([string]$Cwd) {
    if ([string]::IsNullOrWhiteSpace($Cwd)) { return '' }
    $trimmed = $Cwd.TrimEnd('\', '/')
    if ($trimmed -eq '') { return '' }
    $parts = $trimmed -split '[\\/]'
    return $parts[$parts.Length - 1]
}

function ConvertTo-NotifierEvent {
    <#
    .SYNOPSIS
    Преобразует JSON входа хука Claude Code в событие v1 (architecture.md §4).

    .PARAMETER HookKind
    stop | notification | stopfailure.

    .PARAMETER Json
    Сырой stdin хука.

    .PARAMETER EntryPoint
    Значение CLAUDE_CODE_ENTRYPOINT; 'claude-desktop' → origin=desktop, иначе cli.

    .PARAMETER HostSessionId
    Значение CLAUDE_CODE_HOST_SESSION_ID или пусто.

    .PARAMETER Config
    Настройки (Get-NotifierConfig); отсюда берётся previewLength.

    .OUTPUTS
    PSCustomObject события v1 или $null, если вход не разобран (пишется WARN).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$HookKind,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Json,
        [AllowEmptyString()][string]$EntryPoint = $env:CLAUDE_CODE_ENTRYPOINT,
        [AllowEmptyString()][string]$HostSessionId = $env:CLAUDE_CODE_HOST_SESSION_ID,
        [hashtable]$Config,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )

    if (-not $script:KindToType.ContainsKey($HookKind)) {
        Write-NotifierLog -Level WARN -Message "Event: неизвестный HookKind '$HookKind'" -DataRoot $DataRoot
        return $null
    }
    try {
        $hook = $Json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-NotifierLog -Level WARN -Message "Event: вход хука '$HookKind' не разобран как JSON" -DataRoot $DataRoot
        return $null
    }
    if ($hook -isnot [System.Management.Automation.PSCustomObject]) {
        Write-NotifierLog -Level WARN -Message "Event: вход хука '$HookKind' не является JSON-объектом" -DataRoot $DataRoot
        return $null
    }
    if ($null -eq $Config) { $Config = Get-NotifierConfig -DataRoot $DataRoot }

    $type = $script:KindToType[$HookKind]
    switch ($HookKind) {
        'stop' { $raw = Get-InputString $hook 'last_assistant_message' }
        'notification' { $raw = Get-InputString $hook 'message' }
        'stopfailure' {
            $err = Get-InputString $hook 'error'
            $details = Get-InputString $hook 'error_details'
            $raw = (@($err, $details) | Where-Object { -not [string]::IsNullOrEmpty($_) }) -join ': '
        }
        default { $raw = '' }   # служебные события: текст запроса пользователя не передаётся
    }

    $project = Get-ProjectName (Get-InputString $hook 'cwd')
    if (@('done', 'permission', 'error', 'limit') -contains $type) { $title = Get-NotifierEventTitle -Type $type }
    else { $title = 'Сеанс' }
    if ($project -ne '') { $title = "$title $([char]0x00B7) $project" }
    $hostId = $null
    if (-not [string]::IsNullOrEmpty($HostSessionId)) { $hostId = $HostSessionId }
    $origin = 'cli'
    if ($EntryPoint -eq 'claude-desktop') { $origin = 'desktop' }

    return [pscustomobject][ordered]@{
        v               = 1
        id              = [guid]::NewGuid().ToString()
        ts              = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        type            = $type
        session_id      = Get-InputString $hook 'session_id'
        host_session_id = $hostId
        origin          = $origin
        project         = $project
        title           = $title
        preview         = Format-NotifierPreview -Text $raw -MaxLength $Config.previewLength
        window          = $null
    }
}

function Add-NotifierEventDetails {
    <#
    .SYNOPSIS
    Подробности сеанса к событию: статистика журнала (после ответа) и, если включено, начало запроса пользователя.
    Ошибки не мешают доставке события.
    #>
    param($Event, [string]$Kind, [string]$InputJson, $Config, [string]$DataRoot)
    try {
        $hook = ConvertFrom-Json -InputObject $InputJson -ErrorAction Stop
        $tp = $hook.PSObject.Properties['transcript_path']
        # Путь к журналу — трею: он сам обновляет заполненность контекста, пока сеанс работает.
        if ($tp -and $tp.Value -is [string] -and $tp.Value -ne '') { $Event | Add-Member -NotePropertyName transcript -NotePropertyValue $tp.Value -Force }
        if ($Kind -eq 'stop' -or $Kind -eq 'stopfailure') {
            if ($tp -and $tp.Value -is [string]) {
                $stats = Get-NotifierTranscriptStats -Path $tp.Value -StateDir (Join-Path $DataRoot 'stats')
                if ($stats) { $Event | Add-Member -NotePropertyName stats -NotePropertyValue ([pscustomobject]$stats) -Force }
            }
        }
        if ($Kind -eq 'prompt' -and $Config.showPrompt) {
            $pr = $hook.PSObject.Properties['prompt']
            # Служебные «сообщения» (отчёт субагента, уведомление о задаче) — не ваш запрос.
            if ($pr -and $pr.Value -is [string] -and $pr.Value.TrimStart() -notmatch '^<(agent-message|task-notification|system-reminder|command-|local-command)') {
                $Event | Add-Member -NotePropertyName prompt -NotePropertyValue (Format-NotifierPreview -Text $pr.Value -MaxLength $Config.previewLength) -Force
            }
        }
    }
    catch { Write-NotifierLog -Level WARN -Message "bridge: подробности сеанса не собраны: $($_.Exception.Message)" -DataRoot $DataRoot }
}

Export-ModuleMember -Function ConvertTo-NotifierEvent, Format-NotifierPreview, Add-NotifierEventDetails
