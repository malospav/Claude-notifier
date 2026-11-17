Set-StrictMode -Version 2.0

# Статистика работы с Claude по дням и проектам — из журналов Claude Code на этом ПК
# (~/.claude/projects/<папка проекта>/**/*.jsonl; туда пишут и CLI, и приложение Claude).
# Каждый журнал читается с места, где остановились: итоги по дням и позиция — в <DataRoot>\activity\<хэш пути>.json.
#   tokens  — токены ответов Claude (output_tokens; одно сообщение считается один раз);
#   seconds — активное время: промежутки между соседними записями журнала не длиннее 5 минут
#             (у журналов субагентов время не считается — оно совпадает со временем сеанса);
#   prompts — сообщения пользователя (без результатов инструментов и служебных).
# Проект — папка, в которой лежит журнал: Claude Code называет её путём проекта, где каждый символ кроме
# букв и цифр заменён на «-». Имя проекта — последняя часть того пути из журнала (cwd), что даёт это имя;
# переходы командой cd в другие папки проект не меняют.

$script:RxTimestamp = [regex]'"timestamp":"([^"]+)"'
$script:RxMsgId = [regex]'"id":"(msg_[^"]+)"'
$script:RxOutput = [regex]'"output_tokens":(\d+)'
$script:RxCwd = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
$script:GapSeconds = 300
$script:KeepDays = 21
$script:StateVersion = 4

function Get-ActivityStatePath([string]$Path, [string]$StateDir) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())) } finally { $sha.Dispose() }
    return (Join-Path $StateDir ((-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })) + '.json'))
}

function Get-ActivityDirKey([string]$Path) {
    # Папка проекта журнала: …\projects\<ключ>\<сеанс>.jsonl или …\projects\<ключ>\<сеанс>\subagents\agent-*.jsonl.
    if ([string]::IsNullOrEmpty($Path)) { return '' }
    $dir = Split-Path $Path -Parent
    if ($Path -match '[\\/]subagents[\\/][^\\/]+$') { $dir = Split-Path (Split-Path $dir -Parent) -Parent }
    return (Split-Path $dir -Leaf)
}

function ConvertTo-ActivityDirKey([string]$Cwd) { return ($Cwd -replace '[^A-Za-z0-9]', '-') }

function Get-ActivityProjectName([string]$Cwd) {
    $leaf = ($Cwd.TrimEnd('\', '/') -split '[\\/]')[-1]
    if ($leaf -match '^scratch-\d{4}-\d\d-\d\d') { return 'Черновики' }   # временные папки приложения Claude
    return $leaf
}

function New-ActivityState([string]$Path) {
    return @{ v = $script:StateVersion; path = $Path; dirKey = (Get-ActivityDirKey $Path); sub = ($Path -match '[\\/]subagents[\\/]')
        offset = [int64]0; project = ''; firstCwd = ''; lastTs = ''; lastId = ''; lastOut = [int64]0; lastDay = ''; days = @{} }
}

function Get-DayBucket($State, [string]$Day) {
    if (-not $State.days.ContainsKey($Day)) { $State.days[$Day] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0 } }
    return $State.days[$Day]
}

function Update-ActivityState {
    <# .SYNOPSIS Одна строка журнала → итоги по дням (день — по местному времени записи). #>
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Line)
    $tm = $script:RxTimestamp.Match($Line)
    if (-not $tm.Success) { return }
    $ts = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($tm.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$ts)) { return }
    $day = $ts.ToLocalTime().ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    if ($State.project -eq '') {
        $cm = $script:RxCwd.Match($Line)
        if ($cm.Success) {
            $cwd = $cm.Groups[1].Value.Replace('\\', '\').TrimEnd('\', '/')
            if ($State.firstCwd -eq '') { $State.firstCwd = $cwd }
            if ((ConvertTo-ActivityDirKey $cwd) -eq $State.dirKey) { $State.project = Get-ActivityProjectName $cwd }
        }
    }
    if (-not $State.sub -and $State.lastTs -ne '') {
        $prev = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse($State.lastTs, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$prev)) {
            $gap = ($ts - $prev).TotalSeconds
            if ($gap -gt 0 -and $gap -le $script:GapSeconds) { (Get-DayBucket $State $day).seconds += [int64]$gap }
        }
    }
    if ($State.lastTs -eq '' -or $tm.Groups[1].Value -gt $State.lastTs) { $State.lastTs = $tm.Groups[1].Value }
    if ($Line.Contains('"type":"assistant"') -and $Line.Contains('"usage"')) {
        $id = $script:RxMsgId.Match($Line)
        $msgId = ''
        if ($id.Success) { $msgId = $id.Groups[1].Value }
        if ($msgId -ne $State.lastId) {
            # Одно сообщение — несколько строк с той же usage: прошлое засчитывается, когда началось новое.
            if ($State.lastOut -gt 0 -and $State.lastDay -ne '') { (Get-DayBucket $State $State.lastDay).tokens += $State.lastOut }
            $State.lastId = $msgId; $State.lastOut = [int64]0; $State.lastDay = $day
        }
        $om = $script:RxOutput.Match($Line)
        if ($om.Success) { $State.lastOut = [Math]::Max($State.lastOut, [int64]$om.Groups[1].Value) }
    }
    elseif ($Line.Contains('"type":"user"') -and -not $Line.Contains('"tool_result"') -and -not $Line.Contains('"isMeta":true') -and -not $State.sub) {
        (Get-DayBucket $State $day).prompts++
    }
}

function Read-ActivityState([string]$StatePath, [string]$Path) {
    $state = New-ActivityState $Path
    if (-not (Test-Path -LiteralPath $StatePath -PathType Leaf)) { return $state }
    try {
        $saved = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8)) -ErrorAction Stop
        if ([int]$saved.v -ne $script:StateVersion) { return $state }
        foreach ($k in @('path', 'dirKey', 'offset', 'project', 'firstCwd', 'lastTs', 'lastId', 'lastOut', 'lastDay')) { if ($saved.PSObject.Properties[$k]) { $state[$k] = $saved.$k } }
        $state.offset = [int64]$state.offset; $state.lastOut = [int64]$state.lastOut
        foreach ($k in @('path', 'dirKey', 'project', 'firstCwd', 'lastTs', 'lastId', 'lastDay')) { $state[$k] = [string]$state[$k] }
        $state.sub = ($state.path -match '[\\/]subagents[\\/]')
        if ($saved.PSObject.Properties['days'] -and $saved.days) {
            foreach ($p in $saved.days.PSObject.Properties) {
                $state.days[$p.Name] = @{ tokens = [int64]$p.Value.tokens; seconds = [int64]$p.Value.seconds; prompts = [int]$p.Value.prompts }
            }
        }
    }
    catch { return (New-ActivityState $Path) }
    return $state
}

function Update-NotifierActivityFile {
    <# .SYNOPSIS Дочитывает один журнал и сохраняет итоги. Возвращает $true, если было что читать. #>
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$StateDir, [datetime]$Now = [DateTime]::Now)
    $statePath = Get-ActivityStatePath $Path $StateDir
    $state = Read-ActivityState $statePath $Path
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $state.offset) { $state = New-ActivityState $Path }
        $remaining = $fs.Length - $state.offset
        if ($remaining -le 0) { return $false }
        [void]$fs.Seek($state.offset, [IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] $remaining
        $read = 0
        while ($read -lt $remaining) { $n = $fs.Read($buffer, $read, $remaining - $read); if ($n -le 0) { break }; $read += $n }
        $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
        if ($end -lt 0) { return $false }
        $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
        foreach ($line in $text.Split("`n")) { if ($line.Length -gt 0) { Update-ActivityState -State $state -Line $line } }
        $state.offset += $end + 1
    }
    finally { $fs.Dispose() }
    # Старые дни не нужны: храним три недели.
    $cut = $Now.Date.AddDays(-$script:KeepDays).ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    foreach ($d in @($state.days.Keys)) { if ($d -lt $cut) { $state.days.Remove($d) } }
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $tmp = "$statePath.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $state -Depth 5 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $statePath -Force
    return $true
}

function Get-NotifierProjectsDir {
    $base = $env:CLAUDE_CONFIG_DIR
    if ([string]::IsNullOrEmpty($base)) { $base = Join-Path $env:USERPROFILE '.claude' }
    return (Join-Path $base 'projects')
}

function Update-NotifierActivity {
    <#
    .SYNOPSIS
    Обходит журналы Claude Code, изменённые за последние Days дней, и дочитывает каждый. Возвращает число прочитанных.
    #>
    [CmdletBinding()]
    param([string]$ProjectsDir = (Get-NotifierProjectsDir), [Parameter(Mandatory = $true)][string]$StateDir, [int]$Days = 8, [datetime]$Now = [DateTime]::Now)
    if (-not (Test-Path -LiteralPath $ProjectsDir)) { return 0 }
    $since = $Now.AddDays(-$Days)
    $n = 0
    foreach ($f in (Get-ChildItem -LiteralPath $ProjectsDir -Filter '*.jsonl' -Recurse -File -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $since) { continue }
        try { if (Update-NotifierActivityFile -Path $f.FullName -StateDir $StateDir -Now $Now) { $n++ } } catch { }
    }
    return $n
}

function Get-ActivityStateProject($State, [hashtable]$ByDirKey) {
    if ($State.project) { return $State.project }
    if ($ByDirKey.ContainsKey($State.dirKey)) { return $ByDirKey[$State.dirKey] }   # субагент — по своему сеансу
    if ($State.firstCwd) { return (Get-ActivityProjectName $State.firstCwd) }
    return 'Без проекта'
}

function Get-NotifierActivitySummary {
    <#
    .SYNOPSIS
    Итоги за Days дней (по умолчанию 7, включая сегодня): Days — по дням (date, tokens, seconds, prompts),
    Today и Week — по проектам (project, tokens, seconds, prompts; больше токенов — выше), Total — за весь период.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir, [int]$Days = 7, [datetime]$Now = [DateTime]::Now)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $dates = @(for ($i = $Days - 1; $i -ge 0; $i--) { $Now.Date.AddDays(-$i).ToString('yyyy-MM-dd', $inv) })
    $today = $dates[-1]
    $perDay = @{}; foreach ($d in $dates) { $perDay[$d] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0 } }
    $week = @{}; $todayProjects = @{}
    $states = @()
    if (Test-Path -LiteralPath $StateDir) {
        $states = @(foreach ($f in (Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) { Read-ActivityState $f.FullName '' })
    }
    $byDirKey = @{}
    foreach ($st in $states) { if ($st.project -and -not $byDirKey.ContainsKey($st.dirKey)) { $byDirKey[$st.dirKey] = $st.project } }
    foreach ($st in $states) {
        # Последнее сообщение ещё не засчитано (ждёт следующего) — добавляем здесь.
        if ($st.lastOut -gt 0 -and $st.lastDay -ne '') { (Get-DayBucket $st $st.lastDay).tokens += $st.lastOut }
        $project = Get-ActivityStateProject $st $byDirKey
        foreach ($d in $st.days.Keys) {
            if (-not $perDay.ContainsKey($d)) { continue }
            $b = $st.days[$d]
            $perDay[$d].tokens += $b.tokens; $perDay[$d].seconds += $b.seconds; $perDay[$d].prompts += $b.prompts
            foreach ($target in @(@{ Map = $week; Use = $true }, @{ Map = $todayProjects; Use = ($d -eq $today) })) {
                if (-not $target.Use) { continue }
                if (-not $target.Map.ContainsKey($project)) { $target.Map[$project] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0 } }
                $target.Map[$project].tokens += $b.tokens; $target.Map[$project].seconds += $b.seconds; $target.Map[$project].prompts += $b.prompts
            }
        }
    }
    $toList = {
        param($map)
        @($map.GetEnumerator() | Where-Object { $_.Value.tokens -gt 0 -or $_.Value.seconds -gt 0 -or $_.Value.prompts -gt 0 } |
            Sort-Object -Property @{ Expression = { $_.Value.tokens }; Descending = $true }, @{ Expression = { $_.Key } } |
            ForEach-Object { [pscustomobject]@{ project = $_.Key; tokens = [int64]$_.Value.tokens; seconds = [int64]$_.Value.seconds; prompts = [int]$_.Value.prompts } })
    }
    $dayList = @(foreach ($d in $dates) { [pscustomobject]@{ date = $d; tokens = [int64]$perDay[$d].tokens; seconds = [int64]$perDay[$d].seconds; prompts = [int]$perDay[$d].prompts } })
    $total = [pscustomobject]@{
        tokens  = [int64](($dayList | Measure-Object -Property tokens -Sum).Sum)
        seconds = [int64](($dayList | Measure-Object -Property seconds -Sum).Sum)
        prompts = [int](($dayList | Measure-Object -Property prompts -Sum).Sum)
    }
    return [pscustomobject]@{ Days = $dayList; Today = @(& $toList $todayProjects); Week = @(& $toList $week); Total = $total; Updated = $Now }
}

function Format-NotifierDuration {
    <# .SYNOPSIS Секунды → «меньше минуты», «45 мин», «3 ч 05 мин». #>
    param([int64]$Seconds)
    if ($Seconds -lt 60) { return 'меньше минуты' }
    $m = [int][Math]::Floor($Seconds / 60)
    if ($m -lt 60) { return "$m мин" }
    return ('{0} ч {1:00} мин' -f [int][Math]::Floor($m / 60), ($m % 60))
}

Export-ModuleMember -Function Update-NotifierActivity, Update-NotifierActivityFile, Get-NotifierActivitySummary, Format-NotifierDuration, Get-NotifierProjectsDir
