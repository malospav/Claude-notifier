Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

# Расход лимитов Claude (пятичасовое и недельное окна) для полос в окне и мини-окне.
# Источники, по порядку:
#   1. Сервер Anthropic — GET https://api.anthropic.com/api/oauth/usage с токеном входа Claude Code CLI
#      из ~/.claude/.credentials.json (claudeAiOauth). Так же делает команда /usage. Токен уходит только в Anthropic.
#   2. Строка статуса Claude Code CLI (rate_limits) — statusline.ps1 сохраняет её в usage.json.
# Приложение Claude не передаёт лимиты ни хукам, ни строке статуса; без входа в CLI данных нет.
# usage.json: { five_hour: { percent, resets_at (unix) }, seven_day: {…}, source: api|cli, at: ISO }

$script:UsageUrl = 'https://api.anthropic.com/api/oauth/usage'

function Get-UsagePath([string]$DataRoot) { return (Join-Path $DataRoot 'usage.json') }

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function ConvertTo-UnixTime($Value) {
    # resets_at бывает числом (unix) или строкой ISO-8601.
    if ($null -eq $Value) { return [long]0 }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return [long]$Value }
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.ToUnixTimeSeconds() }
    return [long]0
}

function ConvertFrom-NotifierUsageWindows {
    <#
    .SYNOPSIS
    Окна five_hour / seven_day → @{ five_hour = @{ percent; resets_at }; … }.
    PercentField — utilization (сервер) или used_percentage (строка статуса).
    #>
    param($Object, [Parameter(Mandatory = $true)][string]$PercentField)
    $out = [ordered]@{}
    foreach ($name in 'five_hour', 'seven_day') {
        $w = Get-Prop $Object $name
        if ($null -eq $w) { continue }
        $pct = Get-Prop $w $PercentField
        if ($null -eq $pct) { continue }
        try { $value = [double]$pct } catch { continue }
        $out[$name] = [ordered]@{ percent = [Math]::Max([double]0, [Math]::Min([double]100, $value)); resets_at = (ConvertTo-UnixTime (Get-Prop $w 'resets_at')) }
    }
    return $out
}

function Save-NotifierUsage {
    <# .SYNOPSIS Записывает usage.json, если есть хотя бы одно окно. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Windows, [Parameter(Mandatory = $true)][ValidateSet('api', 'cli')][string]$Source, [string]$DataRoot)
    if ($Windows.Count -eq 0) { return $false }
    $obj = [ordered]@{ source = $Source; at = [DateTime]::UtcNow.ToString('o') }
    foreach ($k in $Windows.Keys) { $obj[$k] = $Windows[$k] }
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $path = Get-UsagePath $DataRoot
    $tmp = "$path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
    return $true
}

function Get-NotifierUsage {
    <# .SYNOPSIS Последние данные о расходе (usage.json) или $null. #>
    [CmdletBinding()]
    param([string]$DataRoot)
    $path = Get-UsagePath $DataRoot
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop) } catch { return $null }
}

function Format-NotifierUsageWindow {
    <#
    .SYNOPSIS
    Для полосы: @{ Percent (-1 — нет данных); Detail = «сброс в 14:05» | «сброс 18.11 в 09:00» | «нет данных» }.
    Окно, чей сброс уже прошёл, считается обнулённым.
    #>
    param($Usage, [Parameter(Mandatory = $true)][string]$Window, [datetime]$Now = [DateTime]::UtcNow)
    $w = Get-Prop $Usage $Window
    if ($null -eq $w) { return @{ Percent = -1; Detail = 'нет данных' } }
    $reset = [long](Get-Prop $w 'resets_at')
    $pct = [double](Get-Prop $w 'percent')
    if ($reset -gt 0) {
        $resetAt = [DateTimeOffset]::FromUnixTimeSeconds($reset)
        if ($resetAt.UtcDateTime -le $Now) { return @{ Percent = 0; Detail = 'окно обновилось' } }
        $local = $resetAt.ToLocalTime()
        $fmt = "'сброс в 'HH:mm"
        if ($local.Date -ne $Now.ToLocalTime().Date) { $fmt = "'сброс 'dd.MM' в 'HH:mm" }
        return @{ Percent = $pct; Detail = $local.ToString($fmt, [Globalization.CultureInfo]::InvariantCulture) }
    }
    return @{ Percent = $pct; Detail = '' }
}

function Get-NotifierOAuthToken {
    <#
    .SYNOPSIS
    Токен входа Claude Code CLI (claudeAiOauth.accessToken), если он есть и не истёк; иначе $null.
    Только чтение файла — токен не обновляется и никуда, кроме сервера Anthropic, не передаётся.
    #>
    [CmdletBinding()]
    param([string]$CredentialsPath = (Join-Path $env:USERPROFILE '.claude\.credentials.json'))
    if (-not (Test-Path -LiteralPath $CredentialsPath)) { return $null }
    try { $c = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($CredentialsPath, [Text.Encoding]::UTF8)) -ErrorAction Stop } catch { return $null }
    $o = Get-Prop $c 'claudeAiOauth'
    $token = [string](Get-Prop $o 'accessToken')
    if ($token -eq '') { return $null }
    $exp = Get-Prop $o 'expiresAt'
    if ($exp) {
        try { if ([DateTimeOffset]::FromUnixTimeMilliseconds([int64]$exp).UtcDateTime -le [DateTime]::UtcNow) { return $null } } catch { }
    }
    return $token
}

function Start-NotifierUsageFetch {
    <#
    .SYNOPSIS
    Запускает запрос расхода к серверу Anthropic без ожидания. Возвращает @{ Task; Client } или $null (нет токена).
    #>
    [CmdletBinding()]
    param([string]$CredentialsPath = (Join-Path $env:USERPROFILE '.claude\.credentials.json'))
    $token = Get-NotifierOAuthToken -CredentialsPath $CredentialsPath
    if ($null -eq $token) { return $null }
    Add-Type -AssemblyName System.Net.Http
    $client = New-Object System.Net.Http.HttpClient
    $client.Timeout = [TimeSpan]::FromSeconds(15)
    $req = New-Object System.Net.Http.HttpRequestMessage 'Get', $script:UsageUrl
    $req.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue 'Bearer', $token
    [void]$req.Headers.TryAddWithoutValidation('anthropic-beta', 'oauth-2025-04-20')
    [void]$req.Headers.TryAddWithoutValidation('User-Agent', 'claude-notifier')
    return @{ Task = $client.SendAsync($req); Client = $client; Started = [DateTime]::UtcNow }
}

function Complete-NotifierUsageFetch {
    <#
    .SYNOPSIS
    Если запрос завершён — разбирает ответ и пишет usage.json. 'pending' | 'ok' | 'failed'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Fetch, [string]$DataRoot)
    if (-not $Fetch.Task.IsCompleted) { return 'pending' }
    try {
        if ($Fetch.Task.IsFaulted -or $Fetch.Task.IsCanceled) { throw 'сеть недоступна' }
        $resp = $Fetch.Task.Result
        $body = $resp.Content.ReadAsStringAsync().Result
        if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode)" }
        $windows = ConvertFrom-NotifierUsageWindows -Object (ConvertFrom-Json -InputObject $body -ErrorAction Stop) -PercentField utilization
        if (Save-NotifierUsage -Windows $windows -Source api -DataRoot $DataRoot) { return 'ok' }
        throw 'в ответе нет окон five_hour / seven_day'
    }
    catch {
        Write-NotifierLog -Level WARN -Message "usage: расход не получен: $($_.Exception.Message)" -DataRoot $DataRoot
        return 'failed'
    }
    finally { $Fetch.Client.Dispose() }
}

function ConvertTo-NotifierLimitStatus {
    <#
    .SYNOPSIS
    usage.json → JSON в формате строки статуса (rate_limits) для Test-NotifierLimits: предупреждения 80/90 %
    работают и в приложении Claude, если расход приходит с сервера.
    #>
    param([Parameter(Mandatory = $true)]$Usage)
    $rl = [ordered]@{}
    foreach ($name in 'five_hour', 'seven_day') {
        $w = Get-Prop $Usage $name
        if ($w) { $rl[$name] = [ordered]@{ used_percentage = [double]$w.percent; resets_at = [long]$w.resets_at } }
    }
    return (ConvertTo-Json -InputObject @{ rate_limits = $rl } -Depth 5 -Compress)
}

Export-ModuleMember -Function ConvertFrom-NotifierUsageWindows, Save-NotifierUsage, Get-NotifierUsage, Format-NotifierUsageWindow, Get-NotifierOAuthToken, Start-NotifierUsageFetch, Complete-NotifierUsageFetch, ConvertTo-NotifierLimitStatus
