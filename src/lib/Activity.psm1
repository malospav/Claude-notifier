Set-StrictMode -Version 2.0

# Статистика работы с Claude по дням и проектам — из журналов Claude Code на этом ПК
# (~/.claude/projects/<папка проекта>/**/*.jsonl; туда пишут и CLI, и приложение Claude).
# Каждый журнал читается с места, где остановились: итоги по дням и позиция — в <DataRoot>\activity\<хэш пути>.json.
#   tokens  — токены ответов Claude (output_tokens; одно сообщение считается один раз);
#   seconds — активное время: промежутки между соседними записями журнала не длиннее 5 минут
#             (у журналов субагентов время не считается — оно совпадает со временем сеанса);
#   prompts — сообщения пользователя (без результатов инструментов и служебных);
#   cost    — примерная стоимость в долларах по ценам API Anthropic (вход, кэш, ответ; модель — из записи).
# Проект — папка, в которой лежит журнал: Claude Code называет её путём проекта, где каждый символ кроме
# букв и цифр заменён на «-». Имя проекта — последняя часть того пути из журнала (cwd), что даёт это имя;
# переходы командой cd в другие папки проект не меняют.

$script:RxTimestamp = [regex]'"timestamp":"([^"]+)"'
$script:RxMsgId = [regex]'"id":"(msg_[^"]+)"'
$script:RxOutput = [regex]'"output_tokens":(\d+)'
$script:RxCwd = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
$script:RxInput = [regex]'"input_tokens":(\d+)'
$script:RxCacheRead = [regex]'"cache_read_input_tokens":(\d+)'
$script:RxCacheNew = [regex]'"cache_creation_input_tokens":(\d+)'
$script:RxCache5m = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$script:RxCache1h = [regex]'"ephemeral_1h_input_tokens":(\d+)'
$script:RxModel = [regex]'"model":"(claude-[^"]+)"'
$script:GapSeconds = 300
$script:KeepDays = 21
$script:StateVersion = 5

# Цены API за 1 млн токенов: вход, ответ, чтение кэша. Запись в кэш — 1,25 × вход (на 5 минут) и 2 × вход (на час).
# Первое совпадение по началу имени модели. Модели нет в списке — стоимость не считается.
$script:Prices = @(
    @('^claude-(fable|mythos)-5-2', 8, 40, 0.20),
    @('^claude-(fable|mythos)-5-1', 10, 50, 0.25),
    @('^claude-(fable|mythos)-5', 10, 50, 1.00),
    @('^claude-opus-5-5', 4, 20, 0.20),
    @('^claude-opus-5', 5, 25, 0.50),
    @('^claude-opus-4-[5-9]', 5, 25, 0.50),
    @('^claude-(opus-4|3-opus)', 15, 75, 1.50),
    @('^claude-sonnet-5-5', 2, 10, 0.10),
    @('^claude-sonnet-5', 2, 10, 0.20),
    @('^claude-(sonnet-4|3-[57]-sonnet)', 3, 15, 0.30),
    @('^claude-haiku-5-5', 0.10, 0.50, 0.01),
    @('^claude-haiku-4', 1, 5, 0.10),
    @('^claude-3-5-haiku', 0.80, 4, 0.08),
    @('^claude-3-haiku', 0.25, 1.25, 0.03)
)

function Get-NotifierModelPrice {
    <# .SYNOPSIS Цены модели за 1 млн токенов: @{ Input; Output; CacheRead } или $null, если модель неизвестна. #>
    param([AllowEmptyString()][string]$Model)
    foreach ($p in $script:Prices) {
        if ($Model -match $p[0]) { return @{ Input = [double]$p[1]; Output = [double]$p[2]; CacheRead = [double]$p[3] } }
    }
    return $null
}

function Get-NotifierMessageCost {
    <#
    .SYNOPSIS
    Стоимость одного ответа Claude в долларах по ценам API. Быстрый режим (speed fast) — вдвое дороже;
    у Haiku 5.5 запрос длиннее 100 тыс. токенов — впятеро.
    #>
    param([string]$Model, [int64]$InTokens = 0, [int64]$Output = 0, [int64]$CacheRead = 0, [int64]$Cache5m = 0, [int64]$Cache1h = 0, [switch]$Fast)
    $p = Get-NotifierModelPrice $Model
    if ($null -eq $p) { return [double]0 }
    $k = 1.0
    if ($Model -match '^claude-haiku-5-5' -and ($InTokens + $CacheRead + $Cache5m + $Cache1h) -gt 100000) { $k = 5.0 }
    $usd = ($InTokens * $p.Input + $CacheRead * $p.CacheRead + $Cache5m * 1.25 * $p.Input + $Cache1h * 2 * $p.Input + $Output * $p.Output) * $k / 1000000.0
    if ($Fast) { $usd *= 2 }
    return [double]$usd
}

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
        offset = [int64]0; project = ''; firstCwd = ''; lastTs = ''; lastId = ''; lastOut = [int64]0; lastDay = ''; days = @{}
        lastModel = ''; lastIn = [int64]0; lastRead = [int64]0; last5m = [int64]0; last1h = [int64]0; lastFast = $false }
}

function Get-DayBucket($State, [string]$Day) {
    if (-not $State.days.ContainsKey($Day)) { $State.days[$Day] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0; cost = [double]0 } }
    return $State.days[$Day]
}

function Complete-ActivityMessage($State) {
    # Засчитать последнее сообщение Claude (его токены и стоимость) в его день.
    if ($State.lastDay -eq '' -or $State.lastId -eq '') { return }
    $b = Get-DayBucket $State $State.lastDay
    $b.tokens += $State.lastOut
    $b.cost += Get-NotifierMessageCost -Model $State.lastModel -InTokens $State.lastIn -Output $State.lastOut -CacheRead $State.lastRead -Cache5m $State.last5m -Cache1h $State.last1h -Fast:([bool]$State.lastFast)
}

function Get-MaxInt([regex]$Rx, [string]$Line, [int64]$Old) {
    $m = $Rx.Match($Line)
    if ($m.Success) { return [Math]::Max($Old, [int64]$m.Groups[1].Value) }
    return $Old
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
            Complete-ActivityMessage $State
            $State.lastId = $msgId; $State.lastOut = [int64]0; $State.lastDay = $day
            $State.lastIn = [int64]0; $State.lastRead = [int64]0; $State.last5m = [int64]0; $State.last1h = [int64]0
            $mm = $script:RxModel.Match($Line)
            $State.lastModel = ''
            if ($mm.Success) { $State.lastModel = $mm.Groups[1].Value }
            $State.lastFast = $Line.Contains('"speed":"fast"')
        }
        $State.lastOut = Get-MaxInt $script:RxOutput $Line $State.lastOut
        $State.lastIn = Get-MaxInt $script:RxInput $Line $State.lastIn
        $State.lastRead = Get-MaxInt $script:RxCacheRead $Line $State.lastRead
        # Запись в кэш: по срокам хранения, если они указаны; иначе — вся на 5 минут.
        $c5 = $script:RxCache5m.Match($Line); $c1 = $script:RxCache1h.Match($Line)
        if ($c5.Success -or $c1.Success) {
            if ($c5.Success) { $State.last5m = [Math]::Max($State.last5m, [int64]$c5.Groups[1].Value) }
            if ($c1.Success) { $State.last1h = [Math]::Max($State.last1h, [int64]$c1.Groups[1].Value) }
        }
        else { $State.last5m = Get-MaxInt $script:RxCacheNew $Line $State.last5m }
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
        foreach ($k in @('path', 'dirKey', 'offset', 'project', 'firstCwd', 'lastTs', 'lastId', 'lastOut', 'lastDay', 'lastModel', 'lastIn', 'lastRead', 'last5m', 'last1h', 'lastFast')) { if ($saved.PSObject.Properties[$k]) { $state[$k] = $saved.$k } }
        foreach ($k in @('offset', 'lastOut', 'lastIn', 'lastRead', 'last5m', 'last1h')) { $state[$k] = [int64]$state[$k] }
        $state.lastFast = [bool]$state.lastFast
        foreach ($k in @('path', 'dirKey', 'project', 'firstCwd', 'lastTs', 'lastId', 'lastDay', 'lastModel')) { $state[$k] = [string]$state[$k] }
        $state.sub = ($state.path -match '[\\/]subagents[\\/]')
        if ($saved.PSObject.Properties['days'] -and $saved.days) {
            foreach ($p in $saved.days.PSObject.Properties) {
                $state.days[$p.Name] = @{ tokens = [int64]$p.Value.tokens; seconds = [int64]$p.Value.seconds; prompts = [int]$p.Value.prompts; cost = [double]$p.Value.cost }
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
    Today и Week — по проектам (project, tokens, seconds, prompts, cost; больше токенов — выше), Total — за весь период.
    cost — примерная стоимость в долларах по ценам API.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDir, [int]$Days = 7, [datetime]$Now = [DateTime]::Now)
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $dates = @(for ($i = $Days - 1; $i -ge 0; $i--) { $Now.Date.AddDays(-$i).ToString('yyyy-MM-dd', $inv) })
    $today = $dates[-1]
    $perDay = @{}; foreach ($d in $dates) { $perDay[$d] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0; cost = [double]0 } }
    $week = @{}; $todayProjects = @{}
    $states = @()
    if (Test-Path -LiteralPath $StateDir) {
        $states = @(foreach ($f in (Get-ChildItem -LiteralPath $StateDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) { Read-ActivityState $f.FullName '' })
    }
    $byDirKey = @{}
    foreach ($st in $states) { if ($st.project -and -not $byDirKey.ContainsKey($st.dirKey)) { $byDirKey[$st.dirKey] = $st.project } }
    foreach ($st in $states) {
        # Последнее сообщение ещё не засчитано (ждёт следующего) — добавляем здесь.
        Complete-ActivityMessage $st
        $project = Get-ActivityStateProject $st $byDirKey
        foreach ($d in $st.days.Keys) {
            if (-not $perDay.ContainsKey($d)) { continue }
            $b = $st.days[$d]
            $perDay[$d].tokens += $b.tokens; $perDay[$d].seconds += $b.seconds; $perDay[$d].prompts += $b.prompts; $perDay[$d].cost += $b.cost
            foreach ($target in @(@{ Map = $week; Use = $true }, @{ Map = $todayProjects; Use = ($d -eq $today) })) {
                if (-not $target.Use) { continue }
                if (-not $target.Map.ContainsKey($project)) { $target.Map[$project] = @{ tokens = [int64]0; seconds = [int64]0; prompts = 0; cost = [double]0 } }
                $target.Map[$project].tokens += $b.tokens; $target.Map[$project].seconds += $b.seconds; $target.Map[$project].prompts += $b.prompts; $target.Map[$project].cost += $b.cost
            }
        }
    }
    $toList = {
        param($map)
        @($map.GetEnumerator() | Where-Object { $_.Value.tokens -gt 0 -or $_.Value.seconds -gt 0 -or $_.Value.prompts -gt 0 } |
            Sort-Object -Property @{ Expression = { $_.Value.tokens }; Descending = $true }, @{ Expression = { $_.Key } } |
            ForEach-Object { [pscustomobject]@{ project = $_.Key; tokens = [int64]$_.Value.tokens; seconds = [int64]$_.Value.seconds; prompts = [int]$_.Value.prompts; cost = [double]$_.Value.cost } })
    }
    $dayList = @(foreach ($d in $dates) { [pscustomobject]@{ date = $d; tokens = [int64]$perDay[$d].tokens; seconds = [int64]$perDay[$d].seconds; prompts = [int]$perDay[$d].prompts; cost = [double]$perDay[$d].cost } })
    $total = [pscustomobject]@{
        tokens  = [int64](($dayList | Measure-Object -Property tokens -Sum).Sum)
        seconds = [int64](($dayList | Measure-Object -Property seconds -Sum).Sum)
        prompts = [int](($dayList | Measure-Object -Property prompts -Sum).Sum)
        cost    = [double](($dayList | Measure-Object -Property cost -Sum).Sum)
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

function Format-NotifierCost {
    <# .SYNOPSIS Доллары: «$0», «<$0,01», «$0,42», «$12,40», «$1 240». #>
    param([double]$Usd)
    $ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    if ($Usd -le 0) { return '$0' }
    if ($Usd -lt 0.005) { return '<$0,01' }
    if ($Usd -lt 1000) { return '$' + $Usd.ToString('0.00', $ru) }
    return '$' + ([Math]::Round($Usd)).ToString('#,0', $ru).Replace([char]0x00A0, ' ')
}

Export-ModuleMember -Function Update-NotifierActivity, Update-NotifierActivityFile, Get-NotifierActivitySummary, Format-NotifierDuration, Get-NotifierProjectsDir, Get-NotifierModelPrice, Get-NotifierMessageCost, Format-NotifierCost
