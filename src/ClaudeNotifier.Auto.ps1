#Requires -Version 5.1
<#
.SYNOPSIS
Автоматика трея: очередь заданий, продолжение после сброса лимита, изменения сеанса в файлах, правила
«разрешать такие 30 минут», таймлайн дня и отчёт за неделю.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source.
  • Очередь (DataRoot\queue.json, { session_id: [текст…] }): задание из поля шторки, пока сеанс занят; когда
    Claude закончит и ждёт ввода — уходит первое из очереди.
  • Лимит (DataRoot\limit-wait.json): сеанс остановился из-за лимита — шторка показывает, когда продолжит;
    после сброса окна отправляет «Продолжай» (первый текст быстрых ответов).
  • Доставка текста сеансу: через хук ожидания ответа (Stop, быстрые ответы), иначе — в консоль сеанса в
    терминале (console-type.ps1). Сеансы приложения Claude без хука — только уведомление.
  • Таймлайн (DataRoot\timeline.jsonl): смены статуса сеансов — полоса дня на странице «Статистика».
  • Отчёт за неделю: по понедельникам маскот вручает итоги прошлой недели (страница «report»).
#>

$script:QueueFile = 'queue.json'
$script:LimitWaitFile = 'limit-wait.json'
$script:TimelineFile = 'timeline.jsonl'
$script:ChangesShown = @()     # файлы на странице «Изменения» (строки — по номеру)
$script:ConsoleTypeScript = Join-Path $PSScriptRoot 'console-type.ps1'

function Read-NotifierJsonMap {
    <# .SYNOPSIS JSON-объект из файла DataRoot → hashtable (ключ → значение); нет файла или битый — пустой. #>
    param([string]$Name, [string]$DataRoot = $script:TrayDataRoot)
    $map = @{}
    $path = Join-Path $DataRoot $Name
    if (-not (Test-Path -LiteralPath $path)) { return $map }
    try {
        $o = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop
        if ($o) { foreach ($p in $o.PSObject.Properties) { $map[$p.Name] = $p.Value } }
    }
    catch { Write-NotifierLog -Level WARN -Message "auto: $Name не прочитан: $($_.Exception.Message)" -DataRoot $DataRoot }
    return $map
}

function Save-NotifierJsonMap {
    param([string]$Name, [hashtable]$Map, [string]$DataRoot = $script:TrayDataRoot)
    $json = if ($Map.Count -eq 0) { '{}' } else { ConvertTo-Json -InputObject ([pscustomobject]$Map) -Depth 5 -Compress }
    try { [IO.File]::WriteAllText((Join-Path $DataRoot $Name), $json, (New-Object Text.UTF8Encoding $false)) }
    catch { Write-NotifierLog -Level WARN -Message "auto: $Name не сохранён: $($_.Exception.Message)" -DataRoot $DataRoot }
}

function Format-NotifierSpan {
    <# .SYNOPSIS Секунды → «40 мин», «1 ч 05 мин», «меньше минуты». #>
    param([double]$Seconds)
    if ($Seconds -lt 60) { return 'меньше минуты' }
    $m = [int][Math]::Floor($Seconds / 60)
    if ($m -lt 60) { return "$m мин" }
    return ('{0} ч {1:00} мин' -f [int][Math]::Floor($m / 60), ($m % 60))
}

function Get-NotifierSessionById {
    param([string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    return (@(Get-NotifierSessions -DataRoot $DataRoot | Where-Object { [string]$_.session_id -eq $SessionId }) | Select-Object -First 1)
}

# --- Доставка текста сеансу ---

function Send-NotifierConsoleText {
    <#
    .SYNOPSIS
    Текст и Enter — в консоль процесса Claude (сеанс в терминале) через console-type.ps1 в отдельном скрытом
    процессе. $true — введено.
    #>
    param([int]$TargetPid, [string]$Text, [string]$DataRoot = $script:TrayDataRoot)
    if ($TargetPid -le 0 -or $Text.Trim() -eq '' -or -not (Test-Path -LiteralPath $script:ConsoleTypeScript)) { return $false }
    try { $null = Get-Process -Id $TargetPid -ErrorAction Stop } catch { return $false }
    try {
        $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -WorkingDirectory $env:TEMP -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
            '-File', ('"' + $script:ConsoleTypeScript + '"'), '-TargetPid', $TargetPid, '-Text', ('"' + ($Text -replace '"', "'") + '"'))
        $null = $p.Handle
        if (-not $p.WaitForExit(8000)) { try { $p.Kill() } catch { }; return $false }
        if ($p.ExitCode -ne 0) { Write-NotifierLog -Level WARN -Message "auto: ввод в консоль $TargetPid не удался (код $($p.ExitCode))" -DataRoot $DataRoot }
        return ($p.ExitCode -eq 0)
    }
    catch { Write-NotifierLog -Level WARN -Message "auto: ввод в консоль: $($_.Exception.Message)" -DataRoot $DataRoot; return $false }
}

function Send-NotifierSessionText {
    <#
    .SYNOPSIS
    Отдать текст сеансу этого ПК, который ждёт ввода: через хук ожидания ответа, иначе (сеанс в терминале) —
    в его консоль. Возвращает 'reply' | 'console' | '' (не доставлено).
    #>
    param([Parameter(Mandatory = $true)]$Session, [Parameter(Mandatory = $true)][string]$Text, [string]$DataRoot = $script:TrayDataRoot)
    $sid = [string]$Session.session_id
    if ($Session.PSObject.Properties['device'] -and [string]$Session.device -ne '') { return '' }   # с другого устройства — нельзя
    if ($script:Pending -and $script:Pending.Replies -and $script:Pending.Replies.ContainsKey($sid)) {
        if (Write-NotifierReply -SessionId $sid -Text $Text -DataRoot $DataRoot) {
            [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
            return 'reply'
        }
    }
    if ([string]$Session.origin -eq 'cli' -and $Session.PSObject.Properties['window'] -and $Session.window -and [int]$Session.window.pid -gt 0) {
        if (Send-NotifierConsoleText -TargetPid ([int]$Session.window.pid) -Text $Text -DataRoot $DataRoot) {
            [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
            return 'console'
        }
    }
    return ''
}

# --- Очередь заданий ---

function Get-NotifierQueue {
    <# .SYNOPSIS Очередь сеанса: массив текстов. #>
    param([string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    $map = Read-NotifierJsonMap -Name $script:QueueFile -DataRoot $DataRoot
    if (-not $map.ContainsKey($SessionId)) { return @() }
    return @(@($map[$SessionId]) | Where-Object { $_ -is [string] -and $_.Trim() -ne '' })
}

function Add-NotifierQueuedTask {
    <# .SYNOPSIS Задание в конец очереди сеанса. Возвращает, сколько их теперь (0 — не добавлено). #>
    param([string]$SessionId, [string]$Text, [string]$DataRoot = $script:TrayDataRoot)
    $t = ($Text -replace '\s+$', '').Trim()
    if ($SessionId -eq '' -or $t -eq '') { return 0 }
    if ($t.Length -gt 4000) { $t = $t.Substring(0, 4000) }
    $map = Read-NotifierJsonMap -Name $script:QueueFile -DataRoot $DataRoot
    $list = @()
    if ($map.ContainsKey($SessionId)) { $list = @(@($map[$SessionId]) | Where-Object { $_ -is [string] }) }
    if ($list.Count -ge 20) { return 0 }
    $list += $t
    $map[$SessionId] = $list
    Save-NotifierJsonMap -Name $script:QueueFile -Map $map -DataRoot $DataRoot
    Write-NotifierLog -Level INFO -Message "auto: задание в очередь сеанса $SessionId ($($list.Count))" -DataRoot $DataRoot
    return $list.Count
}

function Remove-NotifierQueuedTask {
    <# .SYNOPSIS Убрать задание из очереди (номер с 0); -All — всю очередь сеанса. #>
    param([string]$SessionId, [int]$Index = 0, [switch]$All, [string]$DataRoot = $script:TrayDataRoot)
    $map = Read-NotifierJsonMap -Name $script:QueueFile -DataRoot $DataRoot
    if (-not $map.ContainsKey($SessionId)) { return }
    $list = @(@($map[$SessionId]) | Where-Object { $_ -is [string] })
    if ($All) { $list = @() }
    elseif ($Index -ge 0 -and $Index -lt $list.Count) { $keep = @(); for ($i = 0; $i -lt $list.Count; $i++) { if ($i -ne $Index) { $keep += $list[$i] } }; $list = $keep }
    if ($list.Count -eq 0) { $map.Remove($SessionId) } else { $map[$SessionId] = $list }
    Save-NotifierJsonMap -Name $script:QueueFile -Map $map -DataRoot $DataRoot
}

function Invoke-NotifierQueueTick {
    <#
    .SYNOPSIS
    Сеанс с очередью закончил и ждёт ввода — первое задание уходит ему. Сеанса больше нет — очередь убирается.
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $map = Read-NotifierJsonMap -Name $script:QueueFile -DataRoot $DataRoot
    if ($map.Count -eq 0) { return }
    $sessions = @(Get-NotifierSessions -DataRoot $DataRoot)
    $dirty = $false
    foreach ($sid in @($map.Keys)) {
        $s = @($sessions | Where-Object { [string]$_.session_id -eq $sid }) | Select-Object -First 1
        if ($null -eq $s) { $map.Remove($sid); $dirty = $true; continue }
        if ([string]$s.state -ne 'waiting') { continue }
        $list = @(@($map[$sid]) | Where-Object { $_ -is [string] -and $_.Trim() -ne '' })
        if ($list.Count -eq 0) { $map.Remove($sid); $dirty = $true; continue }
        $how = Send-NotifierSessionText -Session $s -Text $list[0] -DataRoot $DataRoot
        if ($how -eq '') { continue }   # пока некуда — попробуем на следующем тике
        $rest = @(); for ($i = 1; $i -lt $list.Count; $i++) { $rest += $list[$i] }
        if ($rest.Count -eq 0) { $map.Remove($sid) } else { $map[$sid] = $rest }
        $dirty = $true
        $short = $list[0]; if ($short.Length -gt 60) { $short = $short.Substring(0, 59) + [char]0x2026 }
        Write-NotifierLog -Level INFO -Message "auto: задание из очереди ушло сеансу $sid ($how)" -DataRoot $DataRoot
        $script:SessionsDirty = $true
        if (-not $script:TrayNoOutput -and (Test-NotifierNotchActive)) { [ClaudeNotifier.Ui.NotchHost]::Peek("Из очереди $([char]0x00B7) $([string]$s.project): $short", 4500) }
    }
    if ($dirty) { Save-NotifierJsonMap -Name $script:QueueFile -Map $map -DataRoot $DataRoot }
}

# --- Продолжение после лимита ---

function Test-NotifierLimitStop {
    <# .SYNOPSIS Ошибка сеанса — из-за лимита (usage limit / rate limit / 429). #>
    param([Parameter(Mandatory = $true)]$Event)
    if ([string]$Event.type -ne 'error') { return $false }
    $text = "$([string]$Event.title) $([string]$Event.preview)"
    return [bool]($text -match '(?i)usage limit|limit reached|rate.?limit|\b429\b|limit will reset|лимит')
}

function Get-NotifierLimitResetAt {
    <#
    .SYNOPSIS
    Когда сбросится исчерпанный лимит (UTC): окно, израсходованное на 90 % и больше (5 часов или неделя), по
    usage.json. $null — неизвестно (тогда ждём, пока расход 5-часового окна не упадёт).
    #>
    param([datetime]$Now = [DateTime]::UtcNow, [string]$DataRoot = $script:TrayDataRoot)
    $u = Get-NotifierUsage -DataRoot $DataRoot
    if ($null -eq $u) { return $null }
    $best = $null
    foreach ($w in @('five_hour', 'seven_day')) {
        if (-not $u.PSObject.Properties[$w] -or $null -eq $u.$w) { continue }
        $win = $u.$w
        if ([double]$win.percent -lt 90 -or -not $win.PSObject.Properties['resets_at'] -or -not $win.resets_at) { continue }
        $at = [DateTimeOffset]::FromUnixTimeSeconds([int64]$win.resets_at).UtcDateTime
        if ($at -le $Now) { continue }
        if ($null -eq $best -or $at -gt $best) { $best = $at }   # исчерпаны оба — ждём более поздний
    }
    return $best
}

function Register-NotifierLimitStop {
    <# .SYNOPSIS Сеанс остановился из-за лимита — запомнить, когда продолжить. #>
    param([Parameter(Mandatory = $true)]$Event, [datetime]$Now = [DateTime]::UtcNow, [string]$DataRoot = $script:TrayDataRoot)
    $sid = ''
    if ($Event.PSObject.Properties['session_id']) { $sid = [string]$Event.session_id }
    if ($sid -eq '') { return }
    $reset = Get-NotifierLimitResetAt -Now $Now -DataRoot $DataRoot
    $map = Read-NotifierJsonMap -Name $script:LimitWaitFile -DataRoot $DataRoot
    $map[$sid] = [pscustomobject][ordered]@{ at = $Now.ToString('o'); resume = $(if ($reset) { $reset.ToString('o') } else { '' }); project = [string]$Event.project }
    Save-NotifierJsonMap -Name $script:LimitWaitFile -Map $map -DataRoot $DataRoot
    $when = if ($reset) { $reset.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture) } else { 'после сброса' }
    Write-NotifierLog -Level INFO -Message "auto: сеанс $sid остановился из-за лимита $([char]0x2014) продолжит в $when" -DataRoot $DataRoot
}

function Get-NotifierLimitWait {
    <# .SYNOPSIS Сеанс ждёт сброса лимита: @{ Resume = DateTime UTC или $null } или $null. #>
    param([string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    $map = Read-NotifierJsonMap -Name $script:LimitWaitFile -DataRoot $DataRoot
    if (-not $map.ContainsKey($SessionId)) { return $null }
    $r = $null; $d = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$map[$SessionId].resume, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$d)) { $r = $d.UtcDateTime }
    return @{ Resume = $r }
}

function Invoke-NotifierLimitResumeTick {
    <#
    .SYNOPSIS
    Лимит сбросился (время сброса прошло, или расход 5-часового окна упал ниже 80 %) — сеансу уходит «Продолжай».
    Не доставить (приложение Claude без хука) — уведомление «можно продолжить». Сеанс уже продолжили сами
    или его закрыли — ожидание снимается.
    #>
    param([datetime]$Now = [DateTime]::UtcNow, [string]$DataRoot = $script:TrayDataRoot)
    $map = Read-NotifierJsonMap -Name $script:LimitWaitFile -DataRoot $DataRoot
    if ($map.Count -eq 0) { return }
    $sessions = @(Get-NotifierSessions -DataRoot $DataRoot)
    $usage = Get-NotifierUsage -DataRoot $DataRoot
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $dirty = $false
    foreach ($sid in @($map.Keys)) {
        $w = $map[$sid]
        $s = @($sessions | Where-Object { [string]$_.session_id -eq $sid }) | Select-Object -First 1
        $at = [DateTimeOffset]::MinValue
        [void][DateTimeOffset]::TryParse([string]$w.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)
        if ($null -eq $s -or [string]$s.state -eq 'working' -or ($Now - $at.UtcDateTime).TotalHours -gt 30) { $map.Remove($sid); $dirty = $true; continue }
        $resume = [DateTimeOffset]::MinValue
        $due = $false
        if ([DateTimeOffset]::TryParse([string]$w.resume, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$resume)) {
            $due = $Now -ge $resume.UtcDateTime.AddSeconds(45)   # запас: окно на сервере сбрасывается не секунда в секунду
        }
        elseif ($usage -and $usage.PSObject.Properties['five_hour'] -and $usage.five_hour) {
            $uat = [DateTimeOffset]::MinValue
            [void][DateTimeOffset]::TryParse([string]$usage.at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$uat)
            $due = $uat.UtcDateTime -gt $at.UtcDateTime -and [double]$usage.five_hour.percent -lt 80
        }
        if (-not $due) { continue }
        $map.Remove($sid); $dirty = $true
        $project = [string]$s.project
        $how = ''
        if ([bool]$config.notch.limitResume) {
            $text = [string](@(Get-NotifierQuickReplyTexts | ForEach-Object { $_ }) | Select-Object -First 1)
            if (-not $text) { $text = 'Продолжай' }
            $how = Send-NotifierSessionText -Session $s -Text $text -DataRoot $DataRoot
        }
        $script:SessionsDirty = $true
        $msg = if ($how) { "Лимит сброшен $([char]0x2014) «$project» продолжил работу" } else { "Лимит сброшен $([char]0x2014) можно продолжить «$project»" }
        Write-NotifierLog -Level INFO -Message "auto: $msg ($(if ($how) { $how } else { 'без доставки' }))" -DataRoot $DataRoot
        if ($script:TrayNoOutput) { continue }
        if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::Notice($msg, 6000); [ClaudeNotifier.Ui.NotchHost]::React($sid, 'joy') }
        else { [void](Show-NotifierToast -Event ([pscustomobject]@{ type = 'done'; title = 'Лимит сброшен'; preview = $msg; session_id = $sid }) -DataRoot $DataRoot) }
    }
    if ($dirty) { Save-NotifierJsonMap -Name $script:LimitWaitFile -Map $map -DataRoot $DataRoot }
}

# --- Таймлайн дня ---

$script:TimelineLast = @{}   # session_id → последний записанный статус

function Add-NotifierTimelineMark {
    <# .SYNOPSIS Смена статуса сеанса → строка в timeline.jsonl (то же, что уже записано, — не пишется). #>
    param([Parameter(Mandatory = $true)]$Event, [datetime]$Now = [DateTime]::UtcNow, [string]$DataRoot = $script:TrayDataRoot)
    $sid = ''
    if ($Event.PSObject.Properties['session_id']) { $sid = [string]$Event.session_id }
    if ($sid -eq '') { return }
    $state = switch ([string]$Event.type) { 'working' { 'working' } 'done' { 'waiting' } 'start' { 'waiting' } 'permission' { 'permission' } 'request' { 'permission' } 'error' { 'error' } 'end' { 'end' } default { '' } }
    if ($state -eq '') { return }
    if ($Event.PSObject.Properties['device'] -and [string]$Event.device -ne '') { return }   # только сеансы этого ПК
    if ($script:TimelineLast.ContainsKey($sid) -and $script:TimelineLast[$sid] -eq $state) { return }
    $script:TimelineLast[$sid] = $state
    $line = ConvertTo-Json -InputObject ([ordered]@{ t = $Now.ToString('o'); sid = $sid; project = [string]$Event.project; state = $state }) -Compress
    $path = Join-Path $DataRoot $script:TimelineFile
    try {
        [IO.File]::AppendAllText($path, $line + "`n", (New-Object Text.UTF8Encoding $false))
        # Раз в сутки — только последние 3 дня.
        $fi = New-Object IO.FileInfo $path
        if ($fi.Length -gt 400KB) {
            $cut = $Now.AddDays(-3).ToString('o')
            $keep = @([IO.File]::ReadAllLines($path) | Where-Object { $_ -match '"t":"([^"]+)"' -and $Matches[1] -ge $cut })
            [IO.File]::WriteAllLines($path, [string[]]$keep, (New-Object Text.UTF8Encoding $false))
        }
    }
    catch { }
}

function Get-NotifierTimeline {
    <#
    .SYNOPSIS
    Полосы дня: по проектам — отрезки статусов с полуночи (минуты от 00:00 по местному времени).
    @{ Lanes = [{ Project; Segments = [{ From; To; State }] }]; Worked; Waited; Errors; NowMin } (секунды).
    #>
    param([datetime]$Now = [DateTime]::Now, [string]$DataRoot = $script:TrayDataRoot)
    $midnight = $Now.Date
    $path = Join-Path $DataRoot $script:TimelineFile
    $marks = @()
    if (Test-Path -LiteralPath $path) {
        foreach ($l in [IO.File]::ReadAllLines($path)) {
            if ($l.Trim() -eq '') { continue }
            try { $m = ConvertFrom-Json -InputObject $l -ErrorAction Stop } catch { continue }
            $t = [DateTimeOffset]::MinValue
            if (-not [DateTimeOffset]::TryParse([string]$m.t, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$t)) { continue }
            $marks += [pscustomobject]@{ T = $t.LocalDateTime; Sid = [string]$m.sid; Project = [string]$m.project; State = [string]$m.state }
        }
    }
    $nowMin = ($Now - $midnight).TotalMinutes
    $live = @{}
    foreach ($s in @(Get-NotifierSessions -DataRoot $DataRoot)) { $live[[string]$s.session_id] = $true }
    $lanes = [ordered]@{}
    $worked = 0.0; $waited = 0.0; $errors = 0.0
    foreach ($g in @($marks | Group-Object Sid)) {
        $list = @($g.Group | Sort-Object T)
        for ($i = 0; $i -lt $list.Count; $i++) {
            $m = $list[$i]
            if ($m.State -eq 'end') { continue }
            $end = if ($i + 1 -lt $list.Count) { $list[$i + 1].T } elseif ($live.ContainsKey($m.Sid)) { $Now } else { $m.T }
            $from = [Math]::Max(0, ($m.T - $midnight).TotalMinutes); $to = [Math]::Min($nowMin, ($end - $midnight).TotalMinutes)
            if ($to - $from -lt 0.2) { continue }
            # Ожидание дольше 2 часов подряд — сеанс заброшен, а не ждёт вас: в полосе не показываем.
            if ($m.State -eq 'waiting' -and $to - $from -gt 120) { continue }
            $proj = if ($m.Project) { $m.Project } else { 'сеанс' }
            if (-not $lanes.Contains($proj)) { $lanes[$proj] = New-Object System.Collections.ArrayList }
            [void]$lanes[$proj].Add([pscustomobject]@{ From = $from; To = $to; State = $m.State })
            $sec = ($to - $from) * 60
            switch ($m.State) { 'working' { $worked += $sec } 'error' { $errors += $sec } default { $waited += $sec } }
        }
    }
    $out = @()
    foreach ($k in $lanes.Keys) { $out += [pscustomobject]@{ Project = $k; Segments = @($lanes[$k]) } }
    $out = @($out | Sort-Object { -(@($_.Segments | ForEach-Object { $_.To - $_.From }) | Measure-Object -Sum).Sum } | Select-Object -First 6)
    return @{ Lanes = $out; Worked = $worked; Waited = $waited; Errors = $errors; NowMin = $nowMin }
}

function New-NotifierTimelineRow {
    <# .SYNOPSIS Строка «Таймлайн дня» для страницы «Статистика» (Kind timeline: Labels — проекты, Actions — отрезки). #>
    param([datetime]$Now = [DateTime]::Now)
    $tl = Get-NotifierTimeline -Now $Now
    if (@($tl.Lanes).Count -eq 0) { return $null }
    $segs = @()
    for ($i = 0; $i -lt $tl.Lanes.Count; $i++) {
        foreach ($s in $tl.Lanes[$i].Segments) { $segs += ('{0}|{1}|{2}|{3}' -f $i, [Math]::Round($s.From, 1).ToString([Globalization.CultureInfo]::InvariantCulture), [Math]::Round($s.To, 1).ToString([Globalization.CultureInfo]::InvariantCulture), $s.State) }
    }
    $sub = "Работал $(Format-NotifierSpan $tl.Worked) $([char]0x00B7) ждал вас $(Format-NotifierSpan $tl.Waited)"
    if ($tl.Errors -ge 60) { $sub += " $([char]0x00B7) ошибки $(Format-NotifierSpan $tl.Errors)" }
    $r = New-NotifierNotchRow timeline 'timeline' 'Сегодня по часам' $sub -Actions $segs
    $r.Labels = [string[]]@($tl.Lanes | ForEach-Object { $_.Project })
    $r.Values = [double[]]@([Math]::Round($tl.NowMin, 1))
    return $r
}

# --- Отчёт за неделю ---

function Get-NotifierWeekReport {
    <#
    .SYNOPSIS
    Итоги прошлой недели (пн–вс): задач готово (по истории), часов работы и расход (по статистике), самый
    активный проект. @{ From; To; Tasks; Seconds; Cost; Top; TopSeconds; Longest }.
    #>
    param([datetime]$Now = [DateTime]::Now, [string]$DataRoot = $script:TrayDataRoot)
    $dow = ([int]$Now.DayOfWeek + 6) % 7   # понедельник — 0
    $thisMon = $Now.Date.AddDays(-$dow)
    $from = $thisMon.AddDays(-7); $to = $thisMon
    $tasks = 0; $longest = 0
    foreach ($e in @(Get-NotifierHistory -DataRoot $DataRoot)) {
        if ([string]$e.type -ne 'done') { continue }
        $ts = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$e.ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ts)) { continue }
        $lt = $ts.LocalDateTime
        if ($lt -lt $from -or $lt -ge $to) { continue }
        $tasks++
        if ($e.PSObject.Properties['taskSeconds']) { $longest = [Math]::Max($longest, [int64]$e.taskSeconds) }
    }
    $sec = 0.0; $cost = 0.0; $top = ''; $topSec = 0.0
    try {
        $sum = Get-NotifierActivitySummary -StateDir (Join-Path $DataRoot 'activity') -Days 14 -Now $Now
        foreach ($d in @($sum.Days)) {
            $dd = [datetime]::MinValue
            if (-not [datetime]::TryParseExact([string]$d.date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dd)) { continue }
            if ($dd -lt $from -or $dd -ge $to) { continue }
            $sec += [double]$d.seconds
            if ($d.PSObject.Properties['cost']) { $cost += [double]$d.cost }
        }
        $w = @($sum.Week | Sort-Object { -[double]$_.seconds }) | Select-Object -First 1
        if ($w) { $top = [string]$w.project; $topSec = [double]$w.seconds }
    }
    catch { }
    return @{ From = $from; To = $to.AddDays(-1); Tasks = $tasks; Seconds = $sec; Cost = $cost; Top = $top; TopSeconds = $topSec; Longest = $longest }
}

function Get-NotifierWeekReportRows {
    param([datetime]$Now = [DateTime]::Now)
    $r = Get-NotifierWeekReport -Now $Now
    $ci = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $rows = @()
    $rows += New-NotifierNotchRow header -Title ("Неделя {0} $([char]0x2013) {1}" -f $r.From.ToString('d MMMM', $ci), $r.To.ToString('d MMMM', $ci))
    $rows += New-NotifierNotchRow info 'rep.tasks' 'Задач готово' 'Каждая — маскоту в копилку' -Value ([string]$r.Tasks)
    $rows += New-NotifierNotchRow info 'rep.hours' 'Claude работал' 'По журналам Claude Code' -Value (Format-NotifierSpan $r.Seconds)
    if ($r.Cost -gt 0) { $rows += New-NotifierNotchRow info 'rep.cost' 'Расход' 'По ценам API, примерно' -Value ('$' + [Math]::Round($r.Cost, 2).ToString([Globalization.CultureInfo]::InvariantCulture)) }
    if ($r.Top) { $rows += New-NotifierNotchRow info 'rep.top' 'Самый активный проект' (Format-NotifierSpan $r.TopSeconds) -Value $r.Top }
    if ($r.Longest -gt 0) { $rows += New-NotifierNotchRow info 'rep.long' 'Самая долгая задача' 'От запроса до «Готово»' -Value (Format-NotifierSpan $r.Longest) }
    $lv = Get-NotifierLevelOf -Xp (Get-NotifierMascotProgress)
    $rows += New-NotifierNotchRow info 'rep.level' 'Маскот' "Уровень $($lv.Level) $([char]0x00B7) до следующего $([Math]::Max(0, $lv.Next - $lv.Xp)) задач" -Value "ур. $($lv.Level)"
    return $rows
}

function Invoke-NotifierWeeklyReportTick {
    <#
    .SYNOPSIS
    По понедельникам с 9:00, когда вы за ПК и шторка запущена, — один раз за неделю: маскот вручает отчёт.
    #>
    param([datetime]$Now = [DateTime]::Now, [string]$DataRoot = $script:TrayDataRoot)
    if ($Now.DayOfWeek -ne [DayOfWeek]::Monday -or $Now.Hour -lt 9 -or $script:TrayNoOutput) { return }
    $week = '{0}-W{1}' -f $Now.Year, [Globalization.CultureInfo]::InvariantCulture.Calendar.GetWeekOfYear($Now, [Globalization.CalendarWeekRule]::FirstFourDayWeek, [DayOfWeek]::Monday)
    $mark = Join-Path $DataRoot 'report-week.txt'
    try { if ((Test-Path -LiteralPath $mark) -and ([IO.File]::ReadAllText($mark)).Trim() -eq $week) { return } } catch { }
    if (-not (Test-NotifierNotchActive)) { return }
    try { if ((Get-NotifierIdleSeconds) -gt 60) { return } } catch { }
    [IO.File]::WriteAllText($mark, $week)
    Show-NotifierWeekReport -Now $Now
    Write-NotifierLog -Level INFO -Message "auto: отчёт за неделю показан ($week)" -DataRoot $DataRoot
}

function Show-NotifierWeekReport {
    <# .SYNOPSIS Отчёт за неделю — страница шторки «report» (маскот вручает листок). #>
    param([datetime]$Now = [DateTime]::Now)
    if (-not (Test-NotifierNotchActive)) { return }
    [ClaudeNotifier.Ui.NotchHost]::SetRows('report', [ClaudeNotifier.Ui.NotchRow[]]@(Get-NotifierWeekReportRows -Now $Now))
    $script:NotchPage = 'report'
    [ClaudeNotifier.Ui.NotchHost]::ShowPage('report')
}

# --- Шторка: доп. сведения сеанса, страницы, строки ---

function Add-NotifierNotchItemExtras {
    <#
    .SYNOPSIS
    Элемент шторки: можно ли поставить задание в очередь и сколько их; изменения в файлах («3 файла · +120 −14»);
    сеанс ждёт сброса лимита — когда продолжит.
    #>
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow)
    $sid = [string]$Session.session_id
    $local = -not ($Session.PSObject.Properties['device'] -and [string]$Session.device -ne '')
    if ($local) {
        $Item.Queued = @(Get-NotifierQueue -SessionId $sid).Count
        $Item.CanQueue = @('working', 'permission', 'error') -contains [string]$Session.state
    }
    if ($Session.PSObject.Properties['stats'] -and $Session.stats -and $Session.stats.PSObject.Properties['changed'] -and [int]$Session.stats.changed -gt 0) {
        $n = [int]$Session.stats.changed
        $word = if ($n % 10 -eq 1 -and $n % 100 -ne 11) { 'файл' } elseif (@(2, 3, 4) -contains ($n % 10) -and @(12, 13, 14) -notcontains ($n % 100)) { 'файла' } else { 'файлов' }
        $Item.Changes = "$n $word $([char]0x00B7) +$([int]$Session.stats.added) $([char]0x2212)$([int]$Session.stats.removed)"
    }
    $lw = Get-NotifierLimitWait -SessionId $sid
    if ($lw) {
        if ($lw.Resume) {
            $left = $lw.Resume - $Now
            $at = $lw.Resume.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            $Item.StateText = if ($left.TotalSeconds -gt 0) { "Лимит $([char]0x00B7) продолжу в $at (через $(Format-NotifierSpan $left.TotalSeconds))" } else { "Лимит сброшен $([char]0x00B7) продолжаю" }
        }
        else { $Item.StateText = "Лимит $([char]0x00B7) продолжу после сброса" }
    }
}

function Get-NotifierNotchAutoRows {
    <# .SYNOPSIS Строки страниц «Изменения» и «Очередь» выбранного сеанса и «Отчёт за неделю». #>
    param([string]$Page, [string]$SessionId)
    $rows = @()
    if ($Page -eq 'report') { return @(Get-NotifierWeekReportRows) }
    $s = Get-NotifierSessionById -SessionId $SessionId
    $name = if ($s) { [string]$s.project } else { 'сеанс' }
    if ($Page -eq 'changes') {
        $list = @()
        if ($s -and $s.PSObject.Properties['transcript'] -and $s.transcript) { $list = @(Get-NotifierTranscriptChanges -Path ([string]$s.transcript) -StateDir (Join-Path $script:TrayDataRoot 'stats')) }
        $script:ChangesShown = @($list | ForEach-Object { [string]$_.path })
        $rows += New-NotifierNotchRow header -Title "Изменения $([char]0x00B7) $name"
        if ($list.Count -eq 0) { $rows += New-NotifierNotchRow note -Title 'Сеанс ещё не менял файлы.' ; return $rows }
        $root = ''
        if ($s.PSObject.Properties['stats'] -and $s.stats -and $s.stats.PSObject.Properties['cwd']) { $root = ([string]$s.stats.cwd).TrimEnd('\', '/') }
        for ($i = 0; $i -lt $list.Count; $i++) {
            $f = [string]$list[$i].path
            $rel = $f
            if ($root -and $f.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $rel = $f.Substring($root.Length).TrimStart('\', '/') }
            $dir = Split-Path $rel -Parent
            $rows += New-NotifierNotchRow device "chg$i" ([IO.Path]::GetFileName($f)) $(if ($dir) { "$dir $([char]0x00B7) +$($list[$i].add) $([char]0x2212)$($list[$i].del)" } else { "+$($list[$i].add) $([char]0x2212)$($list[$i].del)" }) -Actions @('open|Открыть|secondary')
        }
        return $rows
    }
    if ($Page -eq 'queue') {
        $q = @(Get-NotifierQueue -SessionId $SessionId)
        $rows += New-NotifierNotchRow header -Title "Очередь $([char]0x00B7) $name"
        if ($q.Count -eq 0) { $rows += New-NotifierNotchRow note -Title 'Очередь пуста. Напишите задание в поле ответа на странице сеанса, пока Claude работает.'; return $rows }
        for ($i = 0; $i -lt $q.Count; $i++) {
            $t = $q[$i] -replace '\s+', ' '
            if ($t.Length -gt 140) { $t = $t.Substring(0, 139) + [char]0x2026 }
            $rows += New-NotifierNotchRow device "q$i" $(if ($i -eq 0) { 'Следующее' } else { "$($i + 1)-е" }) $t -Actions @('remove|Убрать|destructive')
        }
        $rows += New-NotifierNotchRow button 'qclear' 'Очистить очередь' 'Задания не уйдут' -Value 'Очистить'
        return $rows
    }
    return $rows
}

function Get-NotifierNotchAutoAllowRows {
    <# .SYNOPSIS Действующие правила «разрешать такие 30 минут» — строки для настроек (раздел «Ответы»). #>
    $rows = @()
    $rules = @(Get-NotifierAutoAllowRules -DataRoot $script:TrayDataRoot)
    for ($i = 0; $i -lt $rules.Count; $i++) {
        $until = [DateTimeOffset]::MinValue
        [void][DateTimeOffset]::TryParse([string]$rules[$i].until, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$until)
        $left = Format-NotifierSpan ($until.UtcDateTime - [DateTime]::UtcNow).TotalSeconds
        $rows += New-NotifierNotchRow device "rule$i" ([string]$rules[$i].title) "$([string]$rules[$i].project) $([char]0x00B7) ещё $left" -Actions @('remove|Убрать|destructive')
    }
    return $rows
}

function Invoke-NotifierAutoRow {
    <# .SYNOPSIS Щелчок по строке страниц «Изменения», «Очередь», правил разрешений. $true — обработан. #>
    param([string]$Id, [string]$Action)
    if ($Id -match '^chg(\d+)$') {
        $i = [int]$Matches[1]
        if ($i -lt @($script:ChangesShown).Count) { Open-NotifierFileInEditor -Path ([string]$script:ChangesShown[$i]) }
        return $true
    }
    if ($Id -match '^q(\d+)$') {
        Remove-NotifierQueuedTask -SessionId $script:NotchAnswerId -Index ([int]$Matches[1])
        Push-NotifierNotchPage -Page queue
        $script:SessionsDirty = $true
        return $true
    }
    if ($Id -eq 'qclear') {
        Remove-NotifierQueuedTask -SessionId $script:NotchAnswerId -All
        Push-NotifierNotchPage -Page queue
        $script:SessionsDirty = $true
        return $true
    }
    if ($Id -match '^rule(\d+)$') {
        Remove-NotifierAutoAllowRule -Index ([int]$Matches[1]) -DataRoot $script:TrayDataRoot
        Push-NotifierNotchPage -Page settings
        return $true
    }
    if ($Id -eq 'report') { Show-NotifierWeekReport; return $true }
    return $false
}

function Open-NotifierFileInEditor {
    <# .SYNOPSIS Файл — в VS Code (если установлен), иначе — в программе по умолчанию. #>
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        if (Test-NotifierNotchActive) { [ClaudeNotifier.Ui.NotchHost]::Notice('Файла уже нет', 3000) }
        return
    }
    $code = Get-Command code.cmd, code -ErrorAction SilentlyContinue | Select-Object -First 1
    try {
        if ($code) { Start-Process -FilePath $code.Source -ArgumentList @('--goto', ('"' + $Path + '"')) -WindowStyle Hidden }
        else { Start-Process -FilePath $Path }
    }
    catch { Write-NotifierLog -Level WARN -Message "auto: файл не открыт: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

# --- Связь с трем ---

function Invoke-NotifierAutoEvent {
    <# .SYNOPSIS Событие сеанса: таймлайн; остановка из-за лимита — ждать сброса. #>
    param([Parameter(Mandatory = $true)]$Event, [string]$DataRoot = $script:TrayDataRoot)
    Add-NotifierTimelineMark -Event $Event -DataRoot $DataRoot
    if (Test-NotifierLimitStop -Event $Event) { Register-NotifierLimitStop -Event $Event -DataRoot $DataRoot }
}

function Invoke-NotifierAutoTick {
    <# .SYNOPSIS Редкий тик трея (раз в секунду): очередь, продолжение после лимита, отчёт недели. #>
    param([datetime]$Now = [DateTime]::UtcNow)
    try { Invoke-NotifierQueueTick } catch { Write-NotifierLog -Level WARN -Message "auto: очередь: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    try { Invoke-NotifierLimitResumeTick -Now $Now } catch { Write-NotifierLog -Level WARN -Message "auto: лимит: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    try { Invoke-NotifierWeeklyReportTick } catch { Write-NotifierLog -Level WARN -Message "auto: отчёт недели: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}
