<#
.SYNOPSIS
Что не даёт пропустить важное: заполненность контекста сеансов (и предупреждение перед автосжатием),
напоминания о запросах без ответа, мигание точки в трее, горячая клавиша мини-окна.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source и работает в его области видимости ($script:…).
#>

$script:ContextWarned = @{}          # session_id → предупреждение о контексте уже показано
$script:ContextNextAt = [datetime]::MinValue
$script:ContextIntervalSec = 15
$script:Reminders = @{}              # id запроса → @{ Count; Last }
$script:MaxReminders = 3
$script:TrayAlert = $false           # есть запрос, который ждёт дольше remindMinutes
$script:BlinkFrame = ''
$script:HotKey = $null
$script:HotKeyText = ''
$script:StallNotified = @{}          # session_id → с какого момента молчит журнал (о чём уже предупредили)
$script:ApiErrorNotified = @{}       # session_id → время ошибки API из журнала, о которой уже сообщили
$script:ApiErrorGraceSec = 20        # столько ждём хука StopFailure, прежде чем сообщить об ошибке из журнала
$script:ExpandedGroups = @{}         # группы сеансов одного проекта, раскрытые в списке
$script:AgentBudgetMs = 400          # за один проход трея журналы агентов читаются не дольше (первый раз их бывает десятки МБ)
$script:AgentActiveMinutes = 30      # незавершённый агент, журнал которого молчит дольше, считается брошенным

function Get-NotifierFeedSignature($Stats) {
    # Лента изменилась (новое событие или инструмент закончился) — подробности нужно обновить.
    if ($null -eq $Stats) { return '' }
    $feed = $null
    if ($Stats -is [System.Collections.IDictionary]) { if ($Stats.Contains('feed')) { $feed = $Stats['feed'] } }
    elseif ($Stats.PSObject.Properties['feed']) { $feed = $Stats.feed }
    $last = @(@($feed) | Where-Object { $_ })
    if ($last.Count -eq 0) { return '' }
    return "$($last.Count)|$($last[-1].ts)|$($last[-1].ms)"
}

function Get-NotifierSessionName {
    <# .SYNOPSIS Имя сеанса для уведомлений и карточек: своё (из настроек сеанса) или имя проекта. #>
    param([Parameter(Mandatory = $true)]$Session, [hashtable]$Prefs = @{})
    $sid = [string]$Session.session_id
    if ($Prefs.ContainsKey($sid) -and $Prefs[$sid].title) { return [string]$Prefs[$sid].title }
    $p = [string]$Session.project
    if ($p -eq '') { return 'Без проекта' }
    return $p
}

function Test-NotifierSessionMuted {
    param([string]$SessionId, [hashtable]$Prefs = @{})
    return ($SessionId -and $Prefs.ContainsKey($SessionId) -and [bool]$Prefs[$SessionId].muted)
}

# --- Контекст ---

function Get-NotifierContextAlerts {
    <#
    .SYNOPSIS
    События «контекст почти заполнен» для сеансов, перешедших порог warnPercent (один раз; снова — после
    сжатия, когда заполненность опустится на 10 пунктов ниже порога). Без уведомлений и выключенная настройка — без событий.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [Parameter(Mandatory = $true)]$Config,
        [hashtable]$Prefs = @{}
    )
    $events = @()
    $warn = [int]$Config.context.warnPercent
    foreach ($s in $Sessions) {
        $sid = [string]$s.session_id
        $stats = $null
        if ($s.PSObject.Properties['stats']) { $stats = $s.stats }
        if ($null -eq $stats -or -not $stats.PSObject.Properties['window']) { continue }
        $pct = [int]$stats.percent
        if ($pct -lt $warn - 10) { $script:ContextWarned.Remove($sid); continue }
        if ($pct -lt $warn -or $script:ContextWarned.ContainsKey($sid)) { continue }
        $script:ContextWarned[$sid] = $true
        if (-not $Config.context.enabled -or (Test-NotifierSessionMuted $sid $Prefs)) { continue }
        $name = Get-NotifierSessionName -Session $s -Prefs $Prefs
        $events += [pscustomobject][ordered]@{
            v          = 1
            id         = [guid]::NewGuid().ToString()
            ts         = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            type       = 'limit'
            context    = $true
            session_id = $sid
            origin     = [string]$s.origin
            project    = [string]$s.project
            title      = "Контекст почти заполнен $([char]0x00B7) $name"
            preview    = "Заполнено $pct % ($(Format-NotifierTokens ([int64]$stats.context)) из $(Format-NotifierTokens ([int64]$stats.window))). Скоро Claude сожмёт историю — можно начать новый сеанс или выполнить /compact."
            window     = $s.window
        }
    }
    return $events
}

# --- «Готово» только после долгих задач ---

function Test-NotifierQuickTask {
    <#
    .SYNOPSIS
    $true — «Готово» не стоит показывать: Claude работал меньше longTasks.minutes минут, а вы за компьютером
    (ввод был меньше минуты назад). Неизвестно, сколько шла работа, — уведомление показывается.
    #>
    param($Session, [Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Config, [double]$IdleSeconds = 0, [datetime]$Now = [DateTime]::UtcNow)
    if (-not $Config.longTasks.enabled -or $null -eq $Session) { return $false }
    if ($IdleSeconds -ge 60) { return $false }
    $busy = ''
    if ($Session.PSObject.Properties['busySince']) { $busy = [string]$Session.busySince }
    if ($busy -eq '' -and [string]$Session.state -eq 'working') { $busy = [string]$Session.since }
    $start = ConvertTo-NotifierUtc $busy
    if ($null -eq $start) { return $false }
    $end = $Now
    if ($Event.PSObject.Properties['ts']) { $e = ConvertTo-NotifierUtc ([string]$Event.ts); if ($null -ne $e) { $end = $e } }
    return (($end - $start).TotalMinutes -lt [int]$Config.longTasks.minutes)
}

# --- Агенты сеанса ---

function Get-NotifierSessionAgents {
    <#
    .SYNOPSIS
    Агенты сеанса по журналам <журнал без .jsonl>\subagents\agent-*.jsonl: активные — не завершённые (finished в
    agent-*.meta.json) и писавшие в журнал за последние 30 минут: имя (описание задачи) и последнее действие;
    Cost — стоимость всех агентов сеанса. Журналы читаются с места, где остановились, свежие первыми, в пределах
    BudgetMs (по часам Clock); не успели все — Complete = $false, стоимость неполная.
    #>
    param([Parameter(Mandatory = $true)][string]$Transcript, [Parameter(Mandatory = $true)][string]$StateDir, [datetime]$Now = [DateTime]::UtcNow,
        [Diagnostics.Stopwatch]$Clock, [int]$BudgetMs = 0)
    $res = @{ Active = @(); Cost = [double]0; Complete = $true }
    $sub = Join-Path ([IO.Path]::ChangeExtension($Transcript, $null).TrimEnd('.')) 'subagents'
    if (-not [IO.Directory]::Exists($sub)) { return $res }
    $files = @((New-Object IO.DirectoryInfo $sub).GetFiles('*.jsonl') | Sort-Object LastWriteTimeUtc -Descending)
    foreach ($f in $files) {
        if ($Clock -and $BudgetMs -gt 0 -and $Clock.ElapsedMilliseconds -gt $BudgetMs) { $res.Complete = $false; break }
        try { $st = Get-NotifierTranscriptStats -Path $f.FullName -StateDir $StateDir } catch { continue }
        if ($null -eq $st) { continue }
        $res.Cost += [double]$st.cost
        $name = ''; $finished = $false
        $metaPath = [IO.Path]::ChangeExtension($f.FullName, '.meta.json')
        if ([IO.File]::Exists($metaPath)) {
            try {
                $meta = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($metaPath, [Text.Encoding]::UTF8)) -ErrorAction Stop
                if ($meta.PSObject.Properties['finished']) { $finished = [bool]$meta.finished }
                if ($meta.PSObject.Properties['description']) { $name = [string]$meta.description }
            }
            catch { }
        }
        if ($finished -or ($Now - $f.LastWriteTimeUtc).TotalMinutes -gt $script:AgentActiveMinutes) { continue }
        if ($name -eq '') { $name = 'Агент' }
        $res.Active += [pscustomobject][ordered]@{ name = $name; doing = [string]$st.lastTool }
    }
    return $res
}

# --- Изменённые файлы и папка проекта ---

function Get-NotifierSessionFiles {
    <# .SYNOPSIS Полные пути файлов, изменённых в сеансе (до 15, новые первыми). #>
    param($Session)
    if ($null -eq $Session -or -not $Session.PSObject.Properties['stats'] -or $null -eq $Session.stats) { return @() }
    if (-not $Session.stats.PSObject.Properties['fileList']) { return @() }
    $list = @(@($Session.stats.fileList) | Where-Object { $_ -is [string] -and $_ -ne '' } | ForEach-Object { $_ -replace '/', '\' })
    [array]::Reverse($list)
    return $list   # не «, $list»: вызывающие оборачивают в @(), иначе получится массив из одного массива
}

function Get-NotifierSessionFolder {
    <# .SYNOPSIS Папка проекта сеанса (cwd из журнала) или '', если неизвестна или её нет на диске. #>
    param($Session)
    if ($null -eq $Session -or -not $Session.PSObject.Properties['stats'] -or $null -eq $Session.stats) { return '' }
    if (-not $Session.stats.PSObject.Properties['cwd']) { return '' }
    $dir = ([string]$Session.stats.cwd) -replace '/', '\'
    if ($dir -eq '' -or -not [IO.Directory]::Exists($dir)) { return '' }
    return $dir
}

function Get-NotifierCodePath {
    # VS Code: code.cmd из PATH или из обычного места установки.
    $c = Get-Command 'code.cmd' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($p in @("$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd", "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd")) { if ([IO.File]::Exists($p)) { return $p } }
    return ''
}

function Open-NotifierFile {
    <#
    .SYNOPSIS
    Открывает файл в VS Code; без VS Code — показывает его в Проводнике (файл не запускается). Возвращает текст подсказки.
    #>
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not [IO.File]::Exists($Path)) { return "Файла уже нет: $([IO.Path]::GetFileName($Path))" }
    $code = Get-NotifierCodePath
    if ($code) { Start-Process -FilePath $code -ArgumentList ('"' + $Path + '"') -WindowStyle Hidden; return '' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('/select,"' + $Path + '"')
    return ''
}

function Open-NotifierProjectFolder {
    param($Session)
    $dir = Get-NotifierSessionFolder $Session
    if ($dir -eq '') { return 'Папка проекта не найдена' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList ('"' + $dir + '"')
    return ''
}

function Add-NotifierFileItems {
    <# .SYNOPSIS Пункты «файл» (путь относительно папки проекта) в меню или подменю; щелчок открывает файл. #>
    param([Parameter(Mandatory = $true)]$Items, $Session, $Theme)
    $Items.Clear()
    $files = @(Get-NotifierSessionFiles $Session)
    $root = Get-NotifierSessionFolder $Session
    if ($files.Count -eq 0) {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem 'Файлы не менялись'
        $none.Enabled = $false
        [void]$Items.Add($none)
        return
    }
    foreach ($f in $files) {
        $text = $f
        if ($root -and $f.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { $text = $f.Substring($root.Length + 1) }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
        if ($Theme) { $mi.Padding = New-Object System.Windows.Forms.Padding($Theme.S(8), $Theme.S(4), $Theme.S(8), $Theme.S(4)) }
        $mi.Tag = $f
        $mi.ToolTipText = $f
        $mi.add_Click({ $n = Open-NotifierFile -Path ([string]$this.Tag); if ($n) { Show-NotifierActionNotice $n } })
        [void]$Items.Add($mi)
    }
}

function Show-NotifierActionNotice([string]$Text) {
    if ($script:MenuSource -eq 'popover' -and $script:Popover -and -not $script:Popover.IsDisposed) { $script:Popover.Tag.Sub.Text = $Text; $script:PopoverNoticeUntil = [datetime]::UtcNow.AddSeconds(4) }
    else { Show-NotifierNotice $Text }
}

function Invoke-NotifierExtraCardAction {
    <#
    .SYNOPSIS
    Кнопки карточек, которые не отвечают Claude: files (меню изменённых файлов), folder (папка проекта),
    clear (убрать все неактивные сеансы). Возвращает $true, если кнопка обработана.
    #>
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][string]$ActionId, $Control, [System.Drawing.Point]$Location, [string]$Source = 'window')
    $script:MenuSource = $Source
    switch ($ActionId) {
        'files' {
            $theme = $null
            if ($script:SessionsForm -and -not $script:SessionsForm.IsDisposed) { $theme = $script:SessionsForm.Tag.Theme }
            if ($Source -eq 'popover' -and $script:Popover) { $theme = $script:Popover.Tag.Theme }
            if ($null -eq $theme) { $theme = Get-NotifierTheme }
            $menu = New-NotifierMenu -Theme $theme
            Add-NotifierFileItems -Items $menu.Items -Session (Get-NotifierCardSession $Item) -Theme $theme
            if ($Control) { $menu.Show($Control, $Location) }
            return $true
        }
        'folder' { $n = Open-NotifierProjectFolder (Get-NotifierCardSession $Item); if ($n) { Show-NotifierActionNotice $n }; return $true }
        'clear' {
            if (-not $Item.IsGroup -or $Item.Tag -isnot [hashtable] -or -not $Item.Tag.ContainsKey('Ids')) { return $false }
            $ids = @($Item.Tag.Ids)
            $rest = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot | Where-Object { $ids -notcontains [string]$_.session_id })
            Save-NotifierSessions -Sessions $rest -DataRoot $script:TrayDataRoot
            $script:ExpandedGroups.Remove([string]$Item.Tag.Group)
            $script:SessionsDirty = $true
            Show-NotifierActionNotice "Убрано из списка: $(Format-NotifierSessionCount $ids.Count)"
            return $true
        }
    }
    return $false
}

# --- Сеанс завис или упал ---

function ConvertTo-NotifierUtc([string]$Ts) {
    $p = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$p)) { return $p.UtcDateTime }
    return $null
}

function Get-NotifierStallStart {
    <#
    .SYNOPSIS
    Сеанс «Работает», но журнал (и журналы субагентов) не меняется Minutes минут: возвращает момент, с которого тишина
    (UTC), иначе $null. Отсчёт — не раньше начала работы: «Работает» без записей в журнале тоже считается.
    #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$LastWrite, [int]$Minutes, [datetime]$Now = [DateTime]::UtcNow)
    if ([string]$Session.state -ne 'working' -or $Minutes -le 0) { return $null }
    $from = $LastWrite
    $since = ConvertTo-NotifierUtc ([string]$Session.since)
    if ($null -ne $since -and $since -gt $from) { $from = $since }
    if ($from -eq [datetime]::MinValue) { return $null }
    if (($Now - $from).TotalMinutes -ge $Minutes) { return $from }
    return $null
}

function New-NotifierStallEvent {
    param([Parameter(Mandatory = $true)]$Session, [datetime]$From, [hashtable]$Prefs = @{}, [datetime]$Now = [DateTime]::UtcNow)
    $name = Get-NotifierSessionName -Session $Session -Prefs $Prefs
    $mins = [int][Math]::Floor(($Now - $From).TotalMinutes)
    return [pscustomobject][ordered]@{
        v          = 1
        id         = [guid]::NewGuid().ToString()
        ts         = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        type       = 'error'
        option     = 'stalled'     # включается своим тумблером, а не тумблером «Ошибка»
        notifyOnly = $true         # статус сеанса не меняется: если Claude оживёт, карточка сама вернётся к «Работает»
        session_id = [string]$Session.session_id
        origin     = [string]$Session.origin
        project    = [string]$Session.project
        title      = "Сеанс, похоже, остановился $([char]0x00B7) $name"
        preview    = "Журнал сеанса не меняется $mins мин. Возможно, Claude завис, оборвалась связь или долго выполняется команда."
        window     = $Session.window
    }
}

function New-NotifierApiErrorEvent {
    param([Parameter(Mandatory = $true)]$Session, [string]$Text, [hashtable]$Prefs = @{}, [datetime]$Now = [DateTime]::UtcNow)
    $name = Get-NotifierSessionName -Session $Session -Prefs $Prefs
    return [pscustomobject][ordered]@{
        v          = 1
        id         = [guid]::NewGuid().ToString()
        ts         = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        type       = 'error'
        apiError   = $true
        session_id = [string]$Session.session_id
        origin     = [string]$Session.origin
        project    = [string]$Session.project
        title      = "Ошибка $([char]0x00B7) $name"
        preview    = (Format-NotifierApiError $Text)
        window     = $Session.window
    }
}

function Test-NotifierApiErrorDue {
    <#
    .SYNOPSIS
    В журнале работающего сеанса — ошибка API после начала работы, о которой ещё не сообщали, и хук StopFailure
    за ApiErrorGraceSec секунд о ней не сообщил (иначе сеанс уже был бы в статусе «Ошибка»).
    #>
    param([Parameter(Mandatory = $true)]$Session, [AllowEmptyString()][string]$ErrorTs, [datetime]$Now = [DateTime]::UtcNow)
    if ([string]$Session.state -ne 'working' -or $ErrorTs -eq '') { return $false }
    $sid = [string]$Session.session_id
    if ($script:ApiErrorNotified[$sid] -eq $ErrorTs) { return $false }
    $err = ConvertTo-NotifierUtc $ErrorTs
    $since = ConvertTo-NotifierUtc ([string]$Session.since)
    if ($null -eq $err -or ($null -ne $since -and $err -le $since)) { return $false }
    return (($Now - $err).TotalSeconds -ge $script:ApiErrorGraceSec)
}

function Update-NotifierLiveContext {
    <#
    .SYNOPSIS
    Раз в 15 с: для работающих сеансов этого ПК дочитывает журнал (только новую часть) и обновляет
    заполненность контекста в sessions.json; переход порога — уведомление в очередь трея.
    Сеанс «Ждёт ответа», в журнале которого появился новый ответ Claude (продолжил сам — например,
    после отчёта субагента; хук UserPromptSubmit при этом не срабатывает), снова становится «Работает»:
    в очередь идёт служебное событие working, оно же убирает кнопки быстрого ответа.
    То же, если после «Готово» пишут журналы субагентов: Claude запустил агентов в фоне и продолжит сам,
    когда они закончат, — отвечать ему не нужно.
    #>
    param([datetime]$Now = [DateTime]::UtcNow, [string]$DataRoot = $script:TrayDataRoot, [switch]$Force)
    if ($null -eq $script:TrayQueue) { return }
    if (-not $Force -and $Now -lt $script:ContextNextAt) { return }
    $script:ContextNextAt = $Now.AddSeconds($script:ContextIntervalSec)
    $sessions = @(Get-NotifierSessions -DataRoot $DataRoot)
    if ($sessions.Count -eq 0) { return }
    $changed = $false
    $stateDir = Join-Path $DataRoot 'stats'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $prefs = Get-NotifierSessionPrefs -DataRoot $DataRoot
    foreach ($s in $sessions) {
        $tp = ''
        if ($s.PSObject.Properties['transcript']) { $tp = [string]$s.transcript }
        $device = ''
        if ($s.PSObject.Properties['device']) { $device = [string]$s.device }
        if ($tp -eq '' -or $device -ne '') { continue }
        # «Работает», а журнал молчит: отметка на карточке и одно уведомление на каждый такой период тишины.
        $sid = [string]$s.session_id
        $from = $null
        if ($config.stalled.enabled) { $from = Get-NotifierStallStart -Session $s -LastWrite (Get-NotifierJournalWriteTime -Path $tp) -Minutes ([int]$config.stalled.minutes) -Now $Now }
        if ($null -ne $from) {
            $mark = $from.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
            if (-not $s.PSObject.Properties['stalledSince'] -or [string]$s.stalledSince -ne $mark) { $s | Add-Member -NotePropertyName stalledSince -NotePropertyValue $mark -Force; $changed = $true }
            if ($script:StallNotified[$sid] -ne $mark) {
                $script:StallNotified[$sid] = $mark
                $script:TrayQueue.Enqueue((New-NotifierStallEvent -Session $s -From $from -Prefs $prefs -Now $Now))
            }
        }
        elseif ($s.PSObject.Properties['stalledSince']) { $s.PSObject.Properties.Remove('stalledSince'); $changed = $true }
        $old = $null
        if ($s.PSObject.Properties['stats']) { $old = $s.stats }
        # Работающий сеанс — каждый раз; ждущий — если журнал менялся после «Готово»; остальные — пока нет данных о контексте.
        $since = [DateTimeOffset]::MinValue
        $waiting = [string]$s.state -eq 'waiting' -and [DateTimeOffset]::TryParse([string]$s.since, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$since)
        $touched = $false
        $agents = $false
        if ($waiting) {
            try { $touched = [IO.File]::GetLastWriteTimeUtc($tp) -gt $since.UtcDateTime.AddSeconds(1) } catch { }
            # Фоновые агенты: их журналы пишутся после «Готово» (запас 5 с — последние строки обычных субагентов).
            $agents = (Get-NotifierJournalWriteTime -Path $tp -SubagentsOnly) -gt $since.UtcDateTime.AddSeconds(5)
        }
        if ($agents) {
            $script:TrayQueue.Enqueue([pscustomobject]@{ v = 1; type = 'working'; title = 'working'; preview = ''; session_id = [string]$s.session_id
                    ts = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) })
            $waiting = $false   # повторно по ответу в журнале — не нужно
        }
        if ([string]$s.state -ne 'working' -and -not $touched -and $old -and $old.PSObject.Properties['window']) { continue }
        try { $st = Get-NotifierTranscriptStats -Path $tp -StateDir $stateDir } catch { continue }
        if ($null -eq $st) { continue }
        if (Test-NotifierApiErrorDue -Session $s -ErrorTs ([string]$st.apiError) -Now $Now) {
            $script:ApiErrorNotified[$sid] = [string]$st.apiError
            $script:TrayQueue.Enqueue((New-NotifierApiErrorEvent -Session $s -Text ([string]$st.apiErrorText) -Prefs $prefs -Now $Now))
        }
        if ($waiting -and $st.lastActivity -ne '') {
            $last = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($st.lastActivity, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$last) -and $last -gt $since) {
                $script:TrayQueue.Enqueue([pscustomobject]@{ v = 1; type = 'working'; title = 'working'; preview = ''; session_id = [string]$s.session_id
                        ts = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) })
            }
        }
        # Агенты: кто сейчас работает и сколько стоили все агенты сеанса.
        $ag = Get-NotifierSessionAgents -Transcript $tp -StateDir $stateDir -Now $Now -Clock $clock -BudgetMs $script:AgentBudgetMs
        $agentsCost = [double]$ag.Cost
        if (-not $ag.Complete) { $agentsCost = 0; if ($old -and $old.PSObject.Properties['agentsCost']) { $agentsCost = [double]$old.agentsCost } }
        $st.agentsCost = $agentsCost
        $sig = (@($ag.Active) | ForEach-Object { "$($_.name)|$($_.doing)" }) -join "`n"
        $oldSig = ''
        if ($s.PSObject.Properties['agents'] -and $s.agents) { $oldSig = (@($s.agents) | ForEach-Object { "$($_.name)|$($_.doing)" }) -join "`n" }
        if ($sig -ne $oldSig) { $s | Add-Member -NotePropertyName agents -NotePropertyValue @($ag.Active) -Force; $changed = $true }
        if ($old -and $old.PSObject.Properties['window'] -and [int64]$old.context -eq $st.context -and [int64]$old.output -eq $st.output -and [int]$old.tools -eq $st.tools -and
            $old.PSObject.Properties['agentsCost'] -and [double]$old.agentsCost -eq $agentsCost -and
            (Get-NotifierFeedSignature $old) -eq (Get-NotifierFeedSignature $st)) { continue }
        $s | Add-Member -NotePropertyName stats -NotePropertyValue ([pscustomobject]$st) -Force
        $changed = $true
    }
    if ($changed) {
        Save-NotifierSessions -Sessions $sessions -DataRoot $DataRoot
        $script:SessionsDirty = $true
    }
    foreach ($ev in (Get-NotifierContextAlerts -Sessions $sessions -Config $config -Prefs $prefs)) { $script:TrayQueue.Enqueue($ev) }
}

# --- Напоминания о запросах ---

function Get-NotifierRequestAge {
    param([Parameter(Mandatory = $true)]$Request, [datetime]$Now = [DateTime]::UtcNow)
    $created = [DateTimeOffset]::MinValue
    if (-not $Request.PSObject.Properties['created'] -or -not [DateTimeOffset]::TryParse([string]$Request.created, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$created)) { return [TimeSpan]::Zero }
    return ($Now - $created.UtcDateTime)
}

function Test-NotifierRequestOverdue {
    <# .SYNOPSIS Запрос ждёт ответа дольше remindMinutes (0 — напоминания выключены). #>
    param([Parameter(Mandatory = $true)]$Request, [int]$Minutes, [datetime]$Now = [DateTime]::UtcNow)
    if ($Minutes -le 0) { return $false }
    return ((Get-NotifierRequestAge -Request $Request -Now $Now).TotalMinutes -ge $Minutes)
}

function Get-NotifierPermissionReminders {
    <#
    .SYNOPSIS
    Повторные уведомления о запросах без ответа: каждые remindMinutes, не больше 3 раз на запрос.
    Заодно выставляет $script:TrayAlert (точка в трее мигает). Возвращает события.
    #>
    param(
        [Parameter(Mandatory = $true)]$Pending,
        [Parameter(Mandatory = $true)]$Config,
        [AllowEmptyCollection()][object[]]$Sessions = @(),
        [hashtable]$Prefs = @{},
        [datetime]$Now = [DateTime]::UtcNow
    )
    $events = @()
    $mins = [int]$Config.approvals.remindMinutes
    $alive = @{}
    $alert = $false
    foreach ($req in @($Pending.Permissions)) {
        if ($null -eq $req) { continue }
        $id = [string]$req.id
        $alive[$id] = $true
        if (-not (Test-NotifierRequestOverdue -Request $req -Minutes $mins -Now $Now)) { continue }
        $alert = $true
        $r = $script:Reminders[$id]
        if ($null -eq $r) { $r = @{ Count = 0; Last = [datetime]::MinValue }; $script:Reminders[$id] = $r }
        if ($r.Count -ge $script:MaxReminders -or ($Now - $r.Last).TotalMinutes -lt $mins) { continue }
        $r.Count++
        $r.Last = $Now
        $sid = [string]$req.session_id
        if (Test-NotifierSessionMuted $sid $Prefs) { continue }
        $session = @($Sessions | Where-Object { [string]$_.session_id -eq $sid }) | Select-Object -First 1
        # В файле запроса нет проекта и источника — они берутся из сеанса.
        $name = 'Claude'; $project = ''; $origin = ''; $win = $null
        if ($session) {
            $name = Get-NotifierSessionName -Session $session -Prefs $Prefs
            $project = [string]$session.project; $origin = [string]$session.origin; $win = $session.window
        }
        $age = [int][Math]::Floor((Get-NotifierRequestAge -Request $req -Now $Now).TotalMinutes)
        $events += [pscustomobject][ordered]@{
            v          = 1
            id         = [guid]::NewGuid().ToString()
            ts         = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
            type       = 'permission'
            reminder   = $true
            session_id = $sid
            origin     = $origin
            project    = $project
            title      = "Всё ещё ждёт ответа $([char]0x00B7) $name"
            preview    = "$([string]$req.title) $([char]0x2014) ждёт $age мин"
            window     = $win
        }
    }
    foreach ($k in @($script:Reminders.Keys)) { if (-not $alive.ContainsKey($k)) { $script:Reminders.Remove($k) } }
    $script:TrayAlert = $alert
    return $events
}

function Invoke-NotifierReminders {
    <# .SYNOPSIS Из обновления сеансов: напоминания — в очередь трея. #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [string]$DataRoot = $script:TrayDataRoot)
    if ($null -eq $script:TrayQueue) { return }
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $prefs = Get-NotifierSessionPrefs -DataRoot $DataRoot
    foreach ($ev in (Get-NotifierPermissionReminders -Pending $script:Pending -Config $config -Sessions $Sessions -Prefs $prefs)) { $script:TrayQueue.Enqueue($ev) }
}

function Update-NotifierTrayBlink {
    <#
    .SYNOPSIS
    Запрос давно ждёт — точка в трее мигает (обычная ↔ крупная с ореолом, 0,6 с); иначе обычная точка статуса.
    #>
    param([datetime]$Now = [DateTime]::UtcNow, $Icon = $script:TrayState.Icon)
    if ($null -eq $Icon) { return }
    $frame = ''
    if ($script:TrayAlert -and $script:TrayStateShown -eq 'permission') {
        $frame = @('alert', 'permission')[[int]([Math]::Floor($Now.TimeOfDay.TotalMilliseconds / 600) % 2)]
    }
    if ($frame -eq $script:BlinkFrame) { return }
    $script:BlinkFrame = $frame
    if ($frame -eq '') { $Icon.Icon = Get-NotifierDotIcon ([string]$script:TrayStateShown) -Count ([int]$script:TrayCountShown) }
    else { $Icon.Icon = Get-NotifierDotIcon $frame }
}

# --- Горячая клавиша ---

function Register-NotifierHotKey {
    <#
    .SYNOPSIS
    Включает или выключает горячую клавишу мини-окна по config.json: Win+Shift+C, если занята — Ctrl+Alt+C.
    Возвращает текст сочетания или '' (выключено или не удалось).
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    if ($script:HotKey) { $script:HotKey.Dispose(); $script:HotKey = $null }
    if ($script:ReplyHotKey) { $script:ReplyHotKey.Dispose(); $script:ReplyHotKey = $null }
    $script:HotKeyText = ''
    $script:ReplyHotKeyText = ''
    $config = Get-NotifierConfig -DataRoot $DataRoot
    if (-not $config.hotkey.enabled) { return '' }
    $hk = New-Object ClaudeNotifier.Ui.HotKey
    $hk.add_Pressed({ Invoke-NotifierHotKey })
    # auto — Win+Shift+C, если занято — Ctrl+Alt+C; иначе — ровно выбранное сочетание.
    $want = [string]$config.hotkey.keys
    $tries = if ($want -eq '' -or $want -eq 'auto') { @('Win+Shift+C', 'Ctrl+Alt+C') } else { @($want) }
    foreach ($text in $tries) {
        $parsed = ConvertTo-NotifierHotKey $text
        if ($parsed -and $hk.Register($parsed.Mods, $parsed.Key)) { $script:HotKeyText = $text; break }
    }
    if (-not $script:HotKeyText) {
        $hk.Dispose()
        Write-NotifierLog -Level WARN -Message "tray: горячая клавиша не зарегистрирована $([char]0x2014) $($tries -join ' и ') заняты" -DataRoot $DataRoot
        return ''
    }
    $script:HotKey = $hk
    # Вторая клавиша — те же модификаторы и R: шаблоны ответа для сеанса, который ждёт.
    $rtext = Get-NotifierReplyHotKeyText $script:HotKeyText
    $rparsed = ConvertTo-NotifierHotKey $rtext
    if ($rparsed) {
        $rk = New-Object ClaudeNotifier.Ui.HotKey
        $rk.add_Pressed({ Invoke-NotifierReplyHotKey })
        if ($rk.Register($rparsed.Mods, $rparsed.Key)) { $script:ReplyHotKey = $rk; $script:ReplyHotKeyText = $rtext }
        else {
            $rk.Dispose()
            Write-NotifierLog -Level WARN -Message "tray: клавиша ответов $rtext занята другой программой" -DataRoot $DataRoot
        }
    }
    return $script:HotKeyText
}

function Get-NotifierReplyHotKeyText([string]$Main) {
    # «Win+Shift+C» → «Win+Shift+R»; если основная клавиша уже R — «…+T».
    $parts = @($Main -split '\+')
    if ($parts.Count -lt 2) { return '' }
    $key = 'R'
    if ($parts[-1] -eq 'R') { $key = 'T' }
    return ((@($parts[0..($parts.Count - 2)]) + $key) -join '+')
}

function Get-NotifierReplyTargets {
    <#
    .SYNOPSIS
    Сеансы, которые ждут ответа (есть ожидание reply): сначала тот, чьё окно сейчас впереди, затем — недавние.
    #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), [hashtable]$Replies = @{}, [int64]$ForegroundHwnd = 0)
    $list = @($Sessions | Where-Object { $_ -and $Replies.ContainsKey([string]$_.session_id) })
    $front = @($list | Where-Object { $ForegroundHwnd -ne 0 -and $_.window -and [int64]$_.window.hwnd -eq $ForegroundHwnd })
    $rest = @($list | Where-Object { $front -notcontains $_ } | Sort-Object -Property @{ Expression = { [string]$_.updated }; Descending = $true })
    return , @($front + $rest)
}

function Send-NotifierHotKeyReply {
    param([Parameter(Mandatory = $true)]$Session, [AllowEmptyString()][string]$Text)
    $sid = [string]$Session.session_id
    if ($Text -eq '') {
        $script:DialogOpen = $true
        try {
            $r = Show-NotifierDialog -Owner $null -Title "Ответ для «$($Session.project)»" -Message 'Claude получит его как ваше сообщение и продолжит работу.' -Primary 'Отправить' -InputValue ''
        }
        finally { $script:DialogOpen = $false }
        if (-not $r.Ok -or ([string]$r.Value).Trim() -eq '') { return }
        $Text = [string]$r.Value
    }
    if (Write-NotifierReply -SessionId $sid -Text $Text -DataRoot $script:TrayDataRoot) {
        [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $script:TrayDataRoot)
        Show-NotifierNotice "Отправлено: $($Text.Trim())"
    }
    else { Show-NotifierNotice 'Сеанс больше не ждёт ответа' }
    [void](Update-NotifierPending -DataRoot $script:TrayDataRoot)
}

function Add-NotifierReplyItems {
    # Пункты «1 Продолжай» … «0 Свой ответ…» для сеанса в коллекцию меню.
    param($Items, $Session, $Theme, [string[]]$Texts)
    $pad = New-Object System.Windows.Forms.Padding($Theme.S(8), $Theme.S(5), $Theme.S(8), $Theme.S(5))
    for ($i = 0; $i -lt $Texts.Count; $i++) {
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ("&$($i + 1)  " + ($Texts[$i] -replace '&', '&&'))
        $mi.Padding = $pad
        $mi.Tag = @{ Session = $Session; Text = $Texts[$i] }
        $mi.add_Click({ Send-NotifierHotKeyReply -Session $this.Tag.Session -Text $this.Tag.Text })
        [void]$Items.Add($mi)
    }
    $own = New-Object System.Windows.Forms.ToolStripMenuItem '&0  Свой ответ…'
    $own.Padding = $pad
    $own.Tag = @{ Session = $Session; Text = '' }
    $own.add_Click({ Send-NotifierHotKeyReply -Session $this.Tag.Session -Text '' })
    [void]$Items.Add($own)
}

function New-NotifierReplyMenu {
    <#
    .SYNOPSIS
    Меню клавиши ответов: шаблоны для первого ждущего сеанса, остальные ждущие — подменю.
    #>
    param([Parameter(Mandatory = $true)]$Theme, [AllowEmptyCollection()][object[]]$Targets = @(), [string[]]$Texts = @(), [hashtable]$Prefs = @{})
    $menu = New-NotifierMenu -Theme $Theme
    $head = New-Object System.Windows.Forms.ToolStripMenuItem
    $head.Enabled = $false
    $head.Padding = New-Object System.Windows.Forms.Padding($Theme.S(8), $Theme.S(5), $Theme.S(8), $Theme.S(5))
    [void]$menu.Items.Add($head)
    if ($Targets.Count -eq 0) { $head.Text = 'Ни один сеанс не ждёт ответа'; return $menu }
    $first = $Targets[0]
    $head.Text = "Ответ для «$(Get-NotifierSessionName -Session $first -Prefs $Prefs)»" -replace '&', '&&'
    Add-NotifierReplyItems -Items $menu.Items -Session $first -Theme $Theme -Texts $Texts
    if ($Targets.Count -gt 1) {
        [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        foreach ($s in @($Targets | Select-Object -Skip 1)) {
            $sub = New-Object System.Windows.Forms.ToolStripMenuItem ("Для «$(Get-NotifierSessionName -Session $s -Prefs $Prefs)»" -replace '&', '&&')
            $sub.Padding = $head.Padding
            $sub.DropDown.Renderer = $menu.Renderer
            $sub.DropDown.Font = $menu.Font
            Add-NotifierReplyItems -Items $sub.DropDownItems -Session $s -Theme $Theme -Texts $Texts
            [void]$menu.Items.Add($sub)
        }
    }
    return $menu
}

function Invoke-NotifierReplyHotKey {
    <# .SYNOPSIS Клавиша ответов: меню шаблонов у курсора для сеанса, который ждёт ответа. #>
    try {
        [void](Update-NotifierPending -DataRoot $script:TrayDataRoot)
        Import-TrayNative
        $fg = [int64][ClaudeNotifier.TrayNative]::GetForegroundWindow()
        $sessions = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)
        $targets = Get-NotifierReplyTargets -Sessions $sessions -Replies $script:Pending.Replies -ForegroundHwnd $fg
        $prefs = Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot
        if ($script:ReplyMenu) { try { $script:ReplyMenu.Close(); $script:ReplyMenu.Dispose() } catch { } }
        $menu = New-NotifierReplyMenu -Theme (Get-NotifierTheme) -Targets $targets -Texts (Get-NotifierQuickReplyTexts) -Prefs $prefs
        $script:ReplyMenu = $menu
        $menu.Show([System.Windows.Forms.Cursor]::Position)
        # Процесс, получивший WM_HOTKEY, может забрать фокус — тогда цифры и стрелки работают сразу.
        [void][ClaudeNotifier.TrayNative]::SetForegroundWindow($menu.Handle)
        if ($menu.Items.Count -gt 1) { [void]$menu.Items[1].Select() }
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: клавиша ответов: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

function ConvertTo-NotifierHotKey([string]$Text) {
    # «Ctrl+Alt+C» → @{ Mods; Key } для RegisterHotKey; неизвестное — $null.
    $mods = [uint32]0
    $key = $null
    foreach ($part in ($Text -split '\+')) {
        switch ($part) {
            'Win' { $mods = $mods -bor [ClaudeNotifier.Ui.HotKey]::ModWin }
            'Ctrl' { $mods = $mods -bor [ClaudeNotifier.Ui.HotKey]::ModControl }
            'Alt' { $mods = $mods -bor [ClaudeNotifier.Ui.HotKey]::ModAlt }
            'Shift' { $mods = $mods -bor [ClaudeNotifier.Ui.HotKey]::ModShift }
            default { try { $key = [System.Windows.Forms.Keys]$part } catch { return $null } }
        }
    }
    if ($null -eq $key -or $mods -eq 0) { return $null }
    return @{ Mods = $mods; Key = $key }
}

function Invoke-NotifierHotKey {
    <# .SYNOPSIS Горячая клавиша: открыть мини-окно у трея или закрыть открытое. #>
    try {
        # Есть шторка — клавиша раскрывает и сворачивает её; иначе — мини-окно у трея.
        if (Test-NotifierNotchActive) { Switch-NotifierNotch; return }
        if ($script:Popover -and -not $script:Popover.IsDisposed) { Close-NotifierPopover; return }
        Show-NotifierPopover -AtTray
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: горячая клавиша: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

# --- Имя, закрепление, без уведомлений ---

function Invoke-NotifierSessionPrefAction {
    <#
    .SYNOPSIS
    Пункт меню карточки: rename (диалог с полем), pin (закрепить/открепить), mute (без уведомлений / вернуть).
    Возвращает текст подсказки.
    #>
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][ValidateSet('rename', 'pin', 'mute')][string]$Action, [string]$DataRoot = $script:TrayDataRoot, $Owner = $script:SessionsForm)
    $session = $Item.Tag
    if ($session -is [hashtable]) { $session = $session.Session }
    if ($null -eq $session) { return '' }
    $sid = [string]$session.session_id
    $prefs = Get-NotifierSessionPrefs -DataRoot $DataRoot
    $cur = @{ title = ''; pinned = $false; muted = $false }
    if ($prefs.ContainsKey($sid)) { $cur = $prefs[$sid] }
    $notice = ''
    switch ($Action) {
        'rename' {
            $script:DialogOpen = $true
            try {
                $value = [string]$cur.title
                if ($value -eq '') { $value = [string]$session.project }
                $r = Show-NotifierDialog -Owner $Owner -Title 'Имя сеанса' -Message 'Пустое имя — снова имя проекта.' -Primary 'Сохранить' -InputValue $value
            }
            finally { $script:DialogOpen = $false }
            if (-not $r.Ok) { return '' }
            $title = ([string]$r.Value).Trim()
            if ($title -eq [string]$session.project) { $title = '' }
            Set-NotifierSessionPref -SessionId $sid -Name title -Value $title -DataRoot $DataRoot
            $notice = 'Сеанс переименован'
            if ($title -eq '') { $notice = 'Возвращено имя проекта' }
        }
        'pin' {
            Set-NotifierSessionPref -SessionId $sid -Name pinned -Value (-not $cur.pinned) -DataRoot $DataRoot
            $notice = @('Сеанс закреплён сверху', 'Сеанс откреплён')[[int][bool]$cur.pinned]
        }
        'mute' {
            Set-NotifierSessionPref -SessionId $sid -Name muted -Value (-not $cur.muted) -DataRoot $DataRoot
            $notice = @('Уведомления этого сеанса выключены', 'Уведомления этого сеанса включены')[[int][bool]$cur.muted]
        }
    }
    $script:SessionsDirty = $true
    return $notice
}

function New-NotifierSessionMenu {
    <#
    .SYNOPSIS
    Контекстное меню карточки сеанса: перейти к окну, переименовать, закрепить, без уведомлений, убрать.
    Текст пунктов «Закрепить» и «Без уведомлений» меняется по настройкам выбранного сеанса при открытии.
    #>
    param([Parameter(Mandatory = $true)]$Theme)
    $menu = New-NotifierMenu -Theme $Theme -Items @(
        @('Перейти к окну', { Invoke-NotifierMenuAction focus }),
        @('Изменённые файлы', $null),
        @('Открыть папку проекта', { Invoke-NotifierMenuAction folder }),
        '-',
        @('Переименовать…', { Invoke-NotifierMenuAction rename }),
        @('Закрепить сверху', { Invoke-NotifierMenuAction pin }),
        @('Без уведомлений', { Invoke-NotifierMenuAction mute }),
        '-',
        @('Убрать из списка', { Invoke-NotifierMenuAction remove })
    )
    $menu.Items[0].Font = [ClaudeNotifier.Ui.Fonts]::Semibold(9.5)
    $files = $menu.Items[1]
    [void]$files.DropDownItems.Add('(пусто)')   # чтобы у пункта была стрелка подменю
    $files.DropDown.Renderer = $menu.Renderer
    $files.DropDown.Font = $menu.Font
    $menu.Tag = $Theme
    $menu.add_Opening({
            $item = $script:MenuItem
            $pinned = $false; $muted = $false
            if ($item) {
                $s = $item.Tag
                if ($s -is [hashtable]) { $s = $s.Session }
                $prefs = Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot
                $sid = [string]$s.session_id
                if ($prefs.ContainsKey($sid)) { $pinned = [bool]$prefs[$sid].pinned; $muted = [bool]$prefs[$sid].muted }
            }
            $this.Items[5].Text = @('Закрепить сверху', 'Открепить')[[int]$pinned]
            $this.Items[6].Text = @('Без уведомлений', 'Включить уведомления')[[int]$muted]
            # Файлы и папка — только для сеансов этого ПК.
            $session = $null
            if ($item) { $session = Get-NotifierCardSession $item }
            $local = $session -and -not ($session.PSObject.Properties['device'] -and [string]$session.device -ne '')
            Add-NotifierFileItems -Items $this.Items[1].DropDownItems -Session $session -Theme $this.Tag
            $this.Items[1].Enabled = $local -and @(Get-NotifierSessionFiles $session).Count -gt 0
            $this.Items[2].Enabled = $local -and (Get-NotifierSessionFolder $session) -ne ''
        })
    return $menu
}

function Show-NotifierSessionMenu {
    <# .SYNOPSIS Показывает меню карточки у курсора; $Source — 'window' или 'popover' (для подсказки и диалогов). #>
    param([Parameter(Mandatory = $true)]$Menu, [Parameter(Mandatory = $true)]$Cards, [Parameter(Mandatory = $true)]$Item, [System.Drawing.Point]$Location, [string]$Source = 'window')
    $script:MenuItem = $Item
    $script:MenuSource = $Source
    $Menu.Show($Cards, $Location)
}

function Invoke-NotifierMenuAction {
    param([Parameter(Mandatory = $true)][string]$Action)
    $item = $script:MenuItem
    if ($null -eq $item) { return }
    $fromPopover = $script:MenuSource -eq 'popover'
    $owner = $script:SessionsForm
    if ($fromPopover) { $owner = $script:Popover }
    $notice = ''
    switch ($Action) {
        { @('rename', 'pin', 'mute') -contains $_ } { $notice = Invoke-NotifierSessionPrefAction -Item $item -Action $Action -Owner $owner }
        'folder' { $notice = Open-NotifierProjectFolder (Get-NotifierCardSession $item) }
        'focus' {
            $s = $item.Tag; if ($s -is [hashtable]) { $s = $s.Session }
            if ($s.PSObject.Properties['device'] -and [string]$s.device -ne '') { $notice = "Этот сеанс идёт на устройстве «$(Get-NotifierDeviceName ([string]$s.device))»" }
            else {
                $result = Invoke-NotifierSessionFocus -Session $s
                if ($result -eq 'unknown') { $notice = 'Окно этого сеанса не определено' }
                elseif ($result -eq 'closed') { $notice = 'Окно сеанса закрыто — сеанс убран из списка' }
                elseif ($fromPopover) { Close-NotifierPopover }
                elseif ($script:MenuSource -eq 'notch') { Close-NotifierNotch }
            }
        }
        'remove' {
            $s = $item.Tag; if ($s -is [hashtable]) { $s = $s.Session }
            Remove-NotifierSession -SessionId ([string]$s.session_id)
        }
    }
    if ($fromPopover) {
        if ($notice -and $script:Popover -and -not $script:Popover.IsDisposed) { $script:Popover.Tag.Sub.Text = $notice; $script:PopoverNoticeUntil = [datetime]::UtcNow.AddSeconds(4) }
    }
    elseif ($notice) { Show-NotifierNotice $notice }
    [void](Invoke-NotifierSessionsRefresh)
}
