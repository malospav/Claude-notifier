Set-StrictMode -Version 2.0

# Обновление приложения с GitHub. install.ps1 пишет app\version.json: { commit; repo; installed }.
# Трей раз в 6 часов (и через 2 минуты после запуска) сравнивает установленный коммит с веткой main
# (GitHub compare API): main впереди — «Доступно обновление». Обновление — отдельный скрытый процесс:
# архив коммита с codeload.github.com → временная папка → install.ps1 (он закрывает трей и запускает новый).
# Без version.json (установка не из git) проверка не делается.
# Канал release (по умолчанию): последний выпуск репозитория (GitHub Releases, собирает .github/workflows/release.yml
# по тегу v*) — архив claude-notifier-<тег>.zip и его SHA-256; коммит выпуска — строка «commit: <sha>» в описании.
# Выпусков нет — как канал main. Архив выпуска перед установкой сверяется с SHA-256.

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:UpdateClient = $null
$script:RepoPattern = '^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$'

function Get-NotifierInstalledVersion {
    <# .SYNOPSIS app\version.json: @{ Commit; Repo; Installed } или $null. #>
    param([Parameter(Mandatory = $true)][string]$AppRoot)
    $p = Join-Path $AppRoot 'version.json'
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { $v = ConvertFrom-Json ([IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)) -ErrorAction Stop } catch { return $null }
    $commit = [string]$v.commit; $repo = [string]$v.repo
    if ($commit -notmatch '^[0-9a-f]{40}$' -or $repo -notmatch $script:RepoPattern) { return $null }
    return @{ Commit = $commit; Repo = $repo; Installed = [string]$v.installed }
}

function ConvertTo-NotifierRepo {
    <# .SYNOPSIS Адрес remote (https://github.com/o/r.git, git@github.com:o/r.git) → «o/r» или ''. #>
    param([AllowEmptyString()][string]$Url)
    if ($Url -notmatch '^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([^/]+/[^/]+?)(?:\.git)?/?$') { return '' }
    $repo = $Matches[1]   # отдельно: следующий -match перезаписал бы $Matches
    if ($repo -match $script:RepoPattern) { return $repo }
    return ''
}

function Get-UpdateClient {
    if ($null -eq $script:UpdateClient) {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $script:UpdateClient = New-Object System.Net.Http.HttpClient
        $script:UpdateClient.Timeout = [TimeSpan]::FromSeconds(20)
        $script:UpdateClient.DefaultRequestHeaders.UserAgent.ParseAdd('claude-notifier-update')   # GitHub API без User-Agent отвечает 403
        $script:UpdateClient.DefaultRequestHeaders.Accept.ParseAdd('application/vnd.github+json')
    }
    return $script:UpdateClient
}

function Start-NotifierUpdateCheck {
    <# .SYNOPSIS Запрос сравнения коммитов в фоне: задача HttpClient (результат — Receive-NotifierUpdateCheck). #>
    param([Parameter(Mandatory = $true)][hashtable]$Version, [string]$Branch = 'main')
    $uri = "https://api.github.com/repos/$($Version.Repo)/compare/$($Version.Commit)...$Branch"
    return (Get-UpdateClient).GetStringAsync($uri)
}

function ConvertFrom-NotifierCompare {
    <#
    .SYNOPSIS
    Ответ compare API → @{ Available; Sha; Count; Message } (Available — main впереди установленного коммита).
    #>
    param([Parameter(Mandatory = $true)][string]$Json)
    $c = ConvertFrom-Json $Json -ErrorAction Stop
    $status = [string]$c.status
    $commits = @($c.commits)
    if ($status -ne 'ahead' -or $commits.Count -eq 0) { return @{ Available = $false; Sha = ''; Count = 0; Message = ''; Notes = @() } }
    $last = $commits[-1]
    $msg = (([string]$last.commit.message) -split "`n")[0].Trim()
    if ($msg.Length -gt 90) { $msg = $msg.Substring(0, 89) + [char]0x2026 }
    $sha = [string]$last.sha
    if ($sha -notmatch '^[0-9a-f]{40}$') { return @{ Available = $false; Sha = ''; Count = 0; Message = ''; Notes = @() } }
    # Что нового: первые строки сообщений коммитов, новые сверху (до 12).
    $notes = @(for ($i = $commits.Count - 1; $i -ge 0 -and $i -ge $commits.Count - 12; $i--) {
            $t = (([string]$commits[$i].commit.message) -split "`n")[0].Trim()
            if ($t.Length -gt 140) { $t = $t.Substring(0, 139) + [char]0x2026 }
            if ($t) { $t }
        })
    return @{ Available = $true; Sha = $sha; Count = [int]$c.ahead_by; Message = $msg; Notes = $notes }
}

function Start-NotifierReleaseCheck {
    <# .SYNOPSIS Запрос последнего выпуска в фоне (результат — Receive-NotifierReleaseCheck). #>
    param([Parameter(Mandatory = $true)][string]$Repo)
    if ($Repo -notmatch $script:RepoPattern) { throw 'неверный репозиторий' }
    return (Get-UpdateClient).GetStringAsync("https://api.github.com/repos/$Repo/releases/latest")
}

function ConvertFrom-NotifierRelease {
    <#
    .SYNOPSIS
    Ответ releases/latest → @{ Tag; Sha; ZipUrl; HashUrl; Title } или $null (нет коммита в описании или архива).
    Адреса — только загрузки выпусков этого репозитория на github.com.
    #>
    param([Parameter(Mandatory = $true)][string]$Json, [Parameter(Mandatory = $true)][string]$Repo)
    $r = ConvertFrom-Json $Json -ErrorAction Stop
    $tag = [string]$r.tag_name
    if ($tag -notmatch '^[A-Za-z0-9._-]{1,40}$') { return $null }
    if ([string]$r.body -notmatch '(?m)^commit:\s*([0-9a-f]{40})\s*$') { return $null }
    $sha = $Matches[1]
    $prefix = "https://github.com/$Repo/releases/download/$tag/"
    $zip = ''; $hash = ''
    foreach ($a in @($r.assets)) {
        $u = [string]$a.browser_download_url
        if (-not $u.StartsWith($prefix, [StringComparison]::Ordinal) -or $u.Substring($prefix.Length) -notmatch '^[A-Za-z0-9._-]+$') { continue }
        if ($u.EndsWith('.zip.sha256')) { $hash = $u } elseif ($u.EndsWith('.zip')) { $zip = $u }
    }
    if ($zip -eq '' -or $hash -eq '') { return $null }
    $title = ([string]$r.name).Trim(); if ($title -eq '') { $title = $tag }
    # Что нового — строки описания выпуска (без служебной «commit:»), до 12.
    $notes = @(([string]$r.body -split "`r?`n") | ForEach-Object { ($_ -replace '^\s*[-*]\s+', '').Trim() } |
        Where-Object { $_ -and $_ -notmatch '^commit:' -and $_ -notmatch '^#+\s*$' } | ForEach-Object { $_ -replace '^#+\s*', '' } | Select-Object -First 12)
    return @{ Tag = $tag; Sha = $sha; ZipUrl = $zip; HashUrl = $hash; Title = $title; Notes = $notes }
}

function Receive-NotifierReleaseCheck {
    <#
    .SYNOPSIS
    Завершённый запрос выпуска: @{ Release = <ConvertFrom-NotifierRelease> } | @{ NotFound = $true } (выпусков нет —
    проверять ветку main) | @{ Failed = $true }; $null — ещё идёт.
    #>
    param([Parameter(Mandatory = $true)]$Task, [Parameter(Mandatory = $true)][string]$Repo, [string]$DataRoot)
    if (-not $Task.IsCompleted) { return $null }
    if ($Task.IsFaulted -or $Task.IsCanceled) {
        $e = $Task.Exception; $text = 'истекло время'
        if ($e) { while ($e.InnerException) { $e = $e.InnerException }; $text = $e.Message }
        if ($text -match '404') { return @{ NotFound = $true } }
        if ($DataRoot) { Write-NotifierLog -Level WARN -Message "update: выпуск не получен $([char]0x2014) $text" -DataRoot $DataRoot }
        return @{ Failed = $true }
    }
    try {
        $rel = ConvertFrom-NotifierRelease -Json $Task.Result -Repo $Repo
        if ($null -eq $rel) { return @{ NotFound = $true } }
        return @{ Release = $rel }
    }
    catch {
        if ($DataRoot) { Write-NotifierLog -Level WARN -Message "update: непонятный ответ о выпуске $([char]0x2014) $($_.Exception.Message)" -DataRoot $DataRoot }
        return @{ Failed = $true }
    }
}

function Receive-NotifierUpdateCheck {
    <# .SYNOPSIS Завершённая проверка: результат ConvertFrom-NotifierCompare, $null — ещё идёт или ошибка (в журнал). #>
    param([Parameter(Mandatory = $true)]$Task, [string]$DataRoot)
    if (-not $Task.IsCompleted) { return $null }
    if ($Task.IsFaulted -or $Task.IsCanceled) {
        $e = $Task.Exception; $text = 'истекло время'
        if ($e) { while ($e.InnerException) { $e = $e.InnerException }; $text = $e.Message }
        if ($DataRoot) { Write-NotifierLog -Level WARN -Message "update: проверка обновления не удалась $([char]0x2014) $text" -DataRoot $DataRoot }
        return @{ Available = $false; Sha = ''; Count = 0; Message = ''; Failed = $true }
    }
    try { return (ConvertFrom-NotifierCompare -Json $Task.Result) }
    catch {
        if ($DataRoot) { Write-NotifierLog -Level WARN -Message "update: непонятный ответ GitHub $([char]0x2014) $($_.Exception.Message)" -DataRoot $DataRoot }
        return @{ Available = $false; Sha = ''; Count = 0; Message = ''; Failed = $true }
    }
}

function Get-NotifierUpdateScript {
    <#
    .SYNOPSIS
    Команда скрытого процесса обновления: скачать архив коммита, распаковать во временную папку, запустить install.ps1.
    Журнал — DataRoot\update.log.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Sha, [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$ZipUrl = '', [string]$HashUrl = '')
    if ($Repo -notmatch $script:RepoPattern -or $Sha -notmatch '^[0-9a-f]{40}$') { throw 'неверный репозиторий или коммит' }
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    # Выпуск: архив и SHA-256 только из загрузок выпусков этого репозитория.
    $rx = '^https://github\.com/' + [regex]::Escape($Repo) + '/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
    $download = "Invoke-WebRequest -UseBasicParsing -Uri 'https://codeload.github.com/$Repo/zip/$Sha' -OutFile `$zip -Headers @{ 'User-Agent' = 'claude-notifier-update' }"
    $what = "$Repo@$Sha"
    if ($ZipUrl -or $HashUrl) {
        if ($ZipUrl -notmatch $rx -or $HashUrl -notmatch $rx) { throw 'неверный адрес выпуска' }
        $what = $ZipUrl
        $download = @"
Invoke-WebRequest -UseBasicParsing -Uri '$ZipUrl' -OutFile `$zip -Headers @{ 'User-Agent' = 'claude-notifier-update' }
    Invoke-WebRequest -UseBasicParsing -Uri '$HashUrl' -OutFile "`$zip.sha256" -Headers @{ 'User-Agent' = 'claude-notifier-update' }
    `$want = ((Get-Content -LiteralPath "`$zip.sha256" -Raw) -split '\s+' | Where-Object { `$_ })[0].Trim().ToLowerInvariant()
    `$have = (Get-FileHash -LiteralPath `$zip -Algorithm SHA256).Hash.ToLowerInvariant()
    if (`$want -notmatch '^[0-9a-f]{64}`$' -or `$want -ne `$have) { throw "SHA-256 архива не совпал (ждали `$want, получили `$have)" }
    Out-Log 'SHA-256 совпал'
"@
    }
    return @"
`$ErrorActionPreference = 'Stop'
`$log = Join-Path $(& $q $DataRoot) 'update.log'
function Out-Log([string]`$t) { Add-Content -LiteralPath `$log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + `$t) -Encoding UTF8 }
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    `$dir = Join-Path `$env:TEMP 'claude-notifier-update-$($Sha.Substring(0, 12))'
    if (Test-Path -LiteralPath `$dir) { Remove-Item -LiteralPath `$dir -Recurse -Force }
    New-Item -ItemType Directory -Path `$dir | Out-Null
    `$zip = Join-Path `$dir 'src.zip'
    Out-Log 'Скачивание $what'
    $download
    Expand-Archive -LiteralPath `$zip -DestinationPath `$dir -Force
    `$root = @(Get-ChildItem -LiteralPath `$dir -Directory)[0].FullName
    Out-Log 'Установка'
    `$out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path `$root 'install.ps1') -Commit '$Sha' -Repo '$Repo' -NoDesktopShortcut 2>&1
    Out-Log ((`$out | Out-String).Trim())
    Out-Log "Готово, код `$LASTEXITCODE"
    Remove-Item -LiteralPath `$dir -Recurse -Force -ErrorAction SilentlyContinue
}
catch { Out-Log ('Ошибка: ' + `$_.Exception.Message) }
"@
}

function Start-NotifierUpdateInstall {
    <# .SYNOPSIS Запускает обновление скрытым процессом PowerShell (трей закроется и запустится заново). #>
    param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Sha, [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$ZipUrl = '', [string]$HashUrl = '')
    $script = Get-NotifierUpdateScript -Repo $Repo -Sha $Sha -DataRoot $DataRoot -ZipUrl $ZipUrl -HashUrl $HashUrl
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    Write-NotifierLog -Level INFO -Message "update: обновление до $($Sha.Substring(0, 12)) запущено" -DataRoot $DataRoot
    return (Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc))
}

Export-ModuleMember -Function Get-NotifierInstalledVersion, ConvertTo-NotifierRepo, Start-NotifierUpdateCheck, ConvertFrom-NotifierCompare, Receive-NotifierUpdateCheck, Start-NotifierReleaseCheck, ConvertFrom-NotifierRelease, Receive-NotifierReleaseCheck, Get-NotifierUpdateScript, Start-NotifierUpdateInstall
