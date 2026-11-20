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
    Скрипт процесса обновления: скачать архив коммита (или выпуска с проверкой SHA-256), распаковать во временную
    папку, запустить install.ps1, дождаться нового трея. Журнал — DataRoot\update.log.

    .DESCRIPTION
    Работа идёт в фоновом потоке (runspace), а главный поток показывает окно обновления
    (update\UpdateWindow.cs рядом со скриптом): состояния download → verify → extract → install → restart → done
    или error. Нет окна (не собралось) — та же работа без него. Установка сорвалась — трей запускается снова.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Sha, [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$ZipUrl = '', [string]$HashUrl = '', [switch]$NoWindow)
    if ($Repo -notmatch $script:RepoPattern -or $Sha -notmatch '^[0-9a-f]{40}$') { throw 'неверный репозиторий или коммит' }
    $q = { param($s) "'" + ($s -replace "'", "''") + "'" }
    # Выпуск: архив и SHA-256 только из загрузок выпусков этого репозитория.
    $rx = '^https://github\.com/' + [regex]::Escape($Repo) + '/releases/download/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
    $zipUri = "https://codeload.github.com/$Repo/zip/$Sha"
    $hashUri = ''
    $what = "$Repo@$Sha"
    if ($ZipUrl -or $HashUrl) {
        if ($ZipUrl -notmatch $rx -or $HashUrl -notmatch $rx) { throw 'неверный адрес выпуска' }
        $what = $ZipUrl; $zipUri = $ZipUrl; $hashUri = $HashUrl
    }
    $template = @'
$ErrorActionPreference = 'Stop'
# Рабочая папка — не папка приложения: процесс с рабочей папкой внутри app\ не дал бы установке её удалить.
Set-Location -LiteralPath $env:TEMP
$dataRoot = __DATAROOT__
$log = Join-Path $dataRoot 'update.log'
function Out-Log([string]$t) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $t) -Encoding UTF8 }

# Работа обновления: меняет $state.Phase / Pct / Detail, окно их показывает.
$work = {
    param($state, $dataRoot, $zipUri, $hashUri, $what, $sha, $repo)
    $ErrorActionPreference = 'Stop'
    Set-Location -LiteralPath $env:TEMP
    $log = Join-Path $dataRoot 'update.log'
    $doneFile = Join-Path $dataRoot 'update-done.txt'
    $appDir = Join-Path $dataRoot 'app'
    function Out-Log([string]$t) { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' ' + $t) -Encoding UTF8 }
    function Test-TrayRunning { @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { [string]$_.CommandLine -match 'ClaudeNotifier\.Tray\.ps1' }).Count -gt 0 }
    function Start-TrayAgain {
        $tray = Join-Path $appDir 'ClaudeNotifier.Tray.ps1'
        if ((Test-Path -LiteralPath $tray) -and -not (Test-TrayRunning)) {
            Start-Process powershell.exe -WorkingDirectory $env:TEMP -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', $tray)
            Out-Log 'Трей запущен снова'
        }
    }
    # Ход обновления — в $state (окно) и в DataRoot\update-progress.json (его читает трей и показывает в шторке):
    # смена шага — сразу, проценты — не чаще 5 раз в секунду.
    $progFile = Join-Path $dataRoot 'update-progress.json'
    $prog = @{ At = [datetime]::MinValue; Phase = '' }
    function Set-UpdState([string]$phase, [double]$pct, $detail) {
        $state.Phase = $phase; $state.Pct = $pct
        if ($null -ne $detail) { $state.Detail = [string]$detail }
        $now = [datetime]::UtcNow
        if ($phase -eq $prog.Phase -and ($now - $prog.At).TotalMilliseconds -lt 200) { return }
        $prog.Phase = $phase; $prog.At = $now
        try {
            $json = [pscustomobject]@{ phase = $phase; pct = $pct; detail = [string]$state.Detail; sha = $sha } | ConvertTo-Json -Compress
            [IO.File]::WriteAllText($progFile, $json)
        }
        catch { }
    }
    $dir = $null
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $dir = Join-Path $env:TEMP ('claude-notifier-update-' + $sha.Substring(0, 12))
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Path $dir | Out-Null
        $zip = Join-Path $dir 'src.zip'
        # 1. Скачивание — кусками: проценты (если сервер назвал размер) и килобайты.
        Out-Log "Скачивание $what"
        Set-UpdState 'download' -1 ''
        $req = [System.Net.HttpWebRequest]::Create($zipUri)
        $req.UserAgent = 'claude-notifier-update'; $req.Timeout = 30000; $req.ReadWriteTimeout = 30000
        $resp = $req.GetResponse()
        $len = $resp.ContentLength
        $in = $resp.GetResponseStream(); $out = [IO.File]::Create($zip)
        try {
            $buf = New-Object byte[] 65536; $total = 0
            while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
                $out.Write($buf, 0, $n); $total += $n
                Set-UpdState 'download' $(if ($len -gt 0) { [double]$total / $len } else { -1 }) ('{0} КБ' -f [int]($total / 1024))
            }
        }
        finally { $out.Dispose(); $in.Dispose(); $resp.Dispose() }
        Set-UpdState 'download' 1.0 $null
        # 2. Проверка SHA-256 (у выпуска).
        if ($hashUri) {
            Set-UpdState 'verify' -1 ''
            $wc2 = New-Object System.Net.WebClient; $wc2.Headers['User-Agent'] = 'claude-notifier-update'
            $wc2.DownloadFile($hashUri, "$zip.sha256"); $wc2.Dispose()
            $want = ((Get-Content -LiteralPath "$zip.sha256" -Raw) -split '\s+' | Where-Object { $_ })[0].Trim().ToLowerInvariant()
            $have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($want -notmatch '^[0-9a-f]{64}$' -or $want -ne $have) { throw "SHA-256 архива не совпал (ждали $want, получили $have)" }
            Out-Log 'SHA-256 совпал'
        }
        # 3. Распаковка.
        Set-UpdState 'extract' -1 ''
        Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
        $root = @(Get-ChildItem -LiteralPath $dir -Directory)[0].FullName
        # 4. Установка (она закрывает трей и запускает новый).
        Out-Log 'Установка'
        Set-UpdState 'install' -1 ''
        $outF = Join-Path $dir 'install.out.txt'; $errF = Join-Path $dir 'install.err.txt'
        $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -WorkingDirectory $root -RedirectStandardOutput $outF -RedirectStandardError $errF -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + (Join-Path $root 'install.ps1') + '"'), '-Commit', $sha, '-Repo', $repo, '-NoDesktopShortcut')
        $null = $p.Handle   # без обращения к дескриптору Start-Process -PassThru теряет код выхода
        $p.WaitForExit()
        $code = $p.ExitCode
        # Вывод установки — в кодировке консоли (OEM), не UTF-8.
        Out-Log ((Get-Content -LiteralPath $outF -Raw -Encoding Oem -ErrorAction SilentlyContinue) + '').Trim()
        $err = ((Get-Content -LiteralPath $errF -Raw -Encoding Oem -ErrorAction SilentlyContinue) + '').Trim()
        if ($err) { Out-Log ('Ошибки установки: ' + $err) }
        Out-Log "Готово, код $code"
        if ($code -ne 0) { throw "установка не удалась (код $code)" }
        [IO.File]::WriteAllText($doneFile, $sha)
        # 5. Запуск новой версии.
        Set-UpdState 'restart' -1 ''
        $until = [DateTime]::UtcNow.AddSeconds(15)
        while (-not (Test-TrayRunning) -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 300 }
        if (-not (Test-TrayRunning)) { Start-TrayAgain }
        Start-Sleep -Milliseconds 600
        Set-UpdState 'done' 1.0 $sha.Substring(0, 7)
        Start-Sleep -Milliseconds 2700
    }
    catch {
        Out-Log ('Ошибка: ' + (($_ | Out-String).Trim()))
        Set-UpdState 'error' -1 $_.Exception.Message
        # Установка могла успеть закрыть трей — запустить его снова (прежняя или уже новая версия).
        try { Start-TrayAgain } catch { Out-Log ('Трей не запущен: ' + $_.Exception.Message) }
        Start-Sleep -Milliseconds 7200
    }
    finally {
        if ($dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        $state.Finished = $true
    }
}

$job = @(__ZIPURI__, __HASHURI__, __WHAT__, __SHA__, __REPO__)
# Окно обновления (UpdateWindow.cs рядом со скриптом) — когда шторки нет: со шторкой ход показывает она (трей читает
# update-progress.json). Окно не собралось — работаем без него.
$useWindow = __WINDOW__
$state = $null
try {
    $cs = Join-Path $PSScriptRoot 'UpdateWindow.cs'
    if ($useWindow -and $PSScriptRoot -and (Test-Path -LiteralPath $cs)) {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        Add-Type -Path $cs -ReferencedAssemblies System.Windows.Forms, System.Drawing -ErrorAction Stop
        $state = New-Object ClaudeNotifier.Update.UpdateState
    }
}
catch { Out-Log ('Окно обновления не собрано: ' + $_.Exception.Message) }
if ($null -eq $state) {
    $plain = [pscustomobject]@{ Phase = 'download'; Detail = ''; Pct = -1.0; Finished = $false }
    & $work $plain $dataRoot $job[0] $job[1] $job[2] $job[3] $job[4]
    return
}
$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$ps = [powershell]::Create(); $ps.Runspace = $rs
[void]$ps.AddScript($work).AddArgument($state).AddArgument($dataRoot).AddArgument($job[0]).AddArgument($job[1]).AddArgument($job[2]).AddArgument($job[3]).AddArgument($job[4])
$h = $ps.BeginInvoke()
$form = New-Object ClaudeNotifier.Update.UpdateWindow $state
[System.Windows.Forms.Application]::Run($form)   # окно закроется само после «Готово» или ошибки
try { [void]$ps.EndInvoke($h) } catch { Out-Log ('Ошибка потока обновления: ' + $_.Exception.Message) }
$ps.Dispose(); $rs.Dispose()
'@
    return $template.Replace('__DATAROOT__', (& $q $DataRoot)).Replace('__ZIPURI__', (& $q $zipUri)).Replace('__HASHURI__', (& $q $hashUri)).
        Replace('__WHAT__', (& $q $what)).Replace('__SHA__', (& $q $Sha)).Replace('__REPO__', (& $q $Repo)).Replace('__WINDOW__', $(if ($NoWindow) { '$false' } else { '$true' }))
}

function Start-NotifierUpdateInstall {
    <#
    .SYNOPSIS
    Запускает обновление отдельным процессом PowerShell (трей закроется и запустится заново). Ход — в шторке
    (трей читает DataRoot\update-progress.json) или, с окном (без -NoWindow), ещё и в окне прогресса справа внизу.
    Скрипт и исходник окна — во временной папке; рабочая папка — TEMP, не папка приложения.
    #>
    param([Parameter(Mandatory = $true)][string]$Repo, [Parameter(Mandatory = $true)][string]$Sha, [Parameter(Mandatory = $true)][string]$DataRoot,
        [string]$ZipUrl = '', [string]$HashUrl = '', [switch]$NoWindow)
    $script = Get-NotifierUpdateScript -Repo $Repo -Sha $Sha -DataRoot $DataRoot -ZipUrl $ZipUrl -HashUrl $HashUrl -NoWindow:$NoWindow
    $dir = Join-Path $env:TEMP ('claude-notifier-updater-' + $Sha.Substring(0, 12))
    [void][IO.Directory]::CreateDirectory($dir)
    $file = Join-Path $dir 'updater.ps1'
    [IO.File]::WriteAllText($file, $script, (New-Object System.Text.UTF8Encoding $true))
    $cs = Join-Path $PSScriptRoot 'update\UpdateWindow.cs'
    if (Test-Path -LiteralPath $cs) { Copy-Item -LiteralPath $cs -Destination (Join-Path $dir 'UpdateWindow.cs') -Force }
    Write-NotifierLog -Level INFO -Message "update: обновление до $($Sha.Substring(0, 12)) запущено" -DataRoot $DataRoot
    # Не из папки приложения (рабочая папка трея): иначе установка не смогла бы удалить прежнюю app\.
    return (Start-Process powershell.exe -WorkingDirectory $env:TEMP -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $file + '"')))
}

Export-ModuleMember -Function Get-NotifierInstalledVersion, ConvertTo-NotifierRepo, Start-NotifierUpdateCheck, ConvertFrom-NotifierCompare, Receive-NotifierUpdateCheck, Start-NotifierReleaseCheck, ConvertFrom-NotifierRelease, Receive-NotifierReleaseCheck, Get-NotifierUpdateScript, Start-NotifierUpdateInstall
