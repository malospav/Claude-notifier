Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# Окна лимитов из JSON statusLine: имя поля → подпись в уведомлении и формат времени сброса.
$script:Windows = [ordered]@{
    five_hour = @{ Label = '5 ч'; ResetFormat = "'сброс в 'HH:mm" }
    seven_day = @{ Label = 'Неделя'; ResetFormat = "'сброс 'dd.MM HH:mm" }
}

function Get-Prop($Object, [string]$Name) {
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Test-IsNumber($Value) {
    return ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal])
}

function Read-LimitsState([string]$Path, [string]$DataRoot) {
    # limits.json: { "<окно>": { "resets_at": <unix>, "fired": [80, 90] } } → hashtable.
    $state = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    try {
        $obj = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in $script:Windows.Keys) {
            $w = Get-Prop $obj $name
            if ($null -eq $w) { continue }
            $state[$name] = @{ resets_at = [long](Get-Prop $w 'resets_at'); fired = @(@(Get-Prop $w 'fired') | Where-Object { Test-IsNumber $_ } | ForEach-Object { [int]$_ }) }
        }
    }
    catch {
        Write-NotifierLog -Level WARN -Message 'limits: limits.json не разобран; состояние порогов начато заново' -DataRoot $DataRoot
        return @{}
    }
    return $state
}

function Save-LimitsState([hashtable]$State, [string]$Path) {
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, ($State | ConvertTo-Json -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Format-LimitPreview([string]$Window, [double]$Percent, [long]$ResetsAt) {
    $info = $script:Windows[$Window]
    $local = [DateTimeOffset]::FromUnixTimeSeconds($ResetsAt).LocalDateTime
    $reset = $local.ToString($info.ResetFormat, [Globalization.CultureInfo]::InvariantCulture)
    return "$($info.Label): $([int][Math]::Floor($Percent)) %, $reset"
}

function Test-NotifierLimits {
    <#
    .SYNOPSIS
    Проверяет проценты лимитов из JSON statusLine и возвращает новые пересечения порогов.

    .DESCRIPTION
    Для каждого окна (five_hour, seven_day) берутся пороги из config.json (limitThresholds).
    Сработавшие пороги запоминаются в limits.json для пары (окно, resets_at); при новом resets_at
    окно начинается заново. Если за один раз пересечено несколько порогов, возвращается один —
    наибольший, остальные помечаются сработавшими. Исключений не выбрасывает.

    .OUTPUTS
    Объекты @{ Window; Threshold; Percent; ResetsAt; Preview } (0, 1 или 2 — по числу окон).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$StatusJson,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    try { $status = $StatusJson | ConvertFrom-Json -ErrorAction Stop }
    catch { return }
    $limits = Get-Prop $status 'rate_limits'
    if ($null -eq $limits) { return }

    $thresholds = @((Get-NotifierConfig -DataRoot $DataRoot).limitThresholds)
    $path = Join-Path $DataRoot 'limits.json'
    $state = Read-LimitsState $path $DataRoot
    $changed = $false

    foreach ($name in $script:Windows.Keys) {
        $w = Get-Prop $limits $name
        $pct = Get-Prop $w 'used_percentage'
        $reset = Get-Prop $w 'resets_at'
        if (-not (Test-IsNumber $pct) -or -not (Test-IsNumber $reset)) { continue }
        $reset = [long]$reset

        if (-not $state.ContainsKey($name) -or $state[$name].resets_at -ne $reset) {
            # Новое окно. Сохраняется только вместе со сработавшим порогом: statusLine вызывается
            # часто, а без пересечений писать на диск незачем (старое состояние всё равно отбросится).
            $state[$name] = @{ resets_at = $reset; fired = @() }
        }
        $crossed = @($thresholds | Where-Object { $pct -ge $_ -and $state[$name].fired -notcontains $_ })
        if ($crossed.Count -eq 0) { continue }

        $state[$name].fired = @(@($state[$name].fired) + $crossed | Sort-Object -Unique)
        $changed = $true
        $top = ($crossed | Measure-Object -Maximum).Maximum
        [pscustomobject]@{
            Window    = $name
            Threshold = [int]$top
            Percent   = [double]$pct
            ResetsAt  = $reset
            Preview   = Format-LimitPreview $name ([double]$pct) $reset
        }
    }

    if ($changed) {
        try { Save-LimitsState $state $path }
        catch { Write-NotifierLog -Level ERROR -Message "limits: limits.json не записан: $($_.Exception.Message)" -DataRoot $DataRoot }
    }
}

function New-NotifierLimitEvent {
    <#
    .SYNOPSIS
    Событие v1 типа limit для результата Test-NotifierLimits (session_id и проект — из JSON statusLine).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Result,
        [AllowEmptyString()][string]$StatusJson = '',
        [AllowEmptyString()][string]$EntryPoint = $env:CLAUDE_CODE_ENTRYPOINT,
        [AllowEmptyString()][string]$HostSessionId = $env:CLAUDE_CODE_HOST_SESSION_ID
    )
    $status = $null
    try { $status = $StatusJson | ConvertFrom-Json -ErrorAction Stop } catch { }
    $cwd = [string](Get-Prop $status 'cwd')
    $project = ''
    if ($cwd.Trim('\', '/') -ne '') { $project = ($cwd.TrimEnd('\', '/') -split '[\\/]')[-1] }
    $title = Get-NotifierEventTitle -Type limit
    if ($project -ne '') { $title = "$title $([char]0x00B7) $project" }
    $hostId = $null
    if (-not [string]::IsNullOrEmpty($HostSessionId)) { $hostId = $HostSessionId }
    $origin = 'cli'
    if ($EntryPoint -eq 'claude-desktop') { $origin = 'desktop' }
    $session = Get-Prop $status 'session_id'
    if ($session -isnot [string]) { $session = $null }

    return [pscustomobject][ordered]@{
        v               = 1
        id              = [guid]::NewGuid().ToString()
        ts              = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        type            = 'limit'
        session_id      = $session
        host_session_id = $hostId
        origin          = $origin
        project         = $project
        title           = $title
        preview         = [string]$Result.Preview
        window          = $null
    }
}

Export-ModuleMember -Function Test-NotifierLimits, New-NotifierLimitEvent
