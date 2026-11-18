Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Sessions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Activity.psm1')   # цены моделей: Get-NotifierMessageCost
Import-Module (Join-Path $PSScriptRoot 'Text.psm1')       # короткие пути в командах

# Статистика сеанса из журнала Claude Code (transcript_path, JSONL): время начала, размер контекста,
# токены ответов, число запросов и действий. Журнал бывает десятки мегабайт, поэтому он читается
# с места, где остановился прошлый раз: итоги и позиция хранятся в <DataRoot>\stats\<хэш пути>.json.
# Разбор — регулярными выражениями по строкам, без ConvertFrom-Json на каждую строку (в PS 5.1 это медленно).

$script:RxTimestamp = [regex]'"timestamp":"([^"]+)"'
$script:RxMsgId = [regex]'"id":"(msg_[^"]+)"'
$script:RxOutput = [regex]'"output_tokens":(\d+)'
$script:RxInput = [regex]'"input_tokens":(\d+)'
$script:RxCacheRead = [regex]'"cache_read_input_tokens":(\d+)'
$script:RxCacheNew = [regex]'"cache_creation_input_tokens":(\d+)'
$script:RxToolUse = [regex]'"type":"tool_use"'
$script:RxModel = [regex]'"model":"(claude-[^"]+)"'
$script:RxToolName = [regex]'"name":"([^"]+)"'
$script:RxFilePath = [regex]'"(?:file_path|notebook_path)":"((?:[^"\\]|\\.)*)"'
$script:RxCommand = [regex]'"command":"((?:[^"\\]|\\.)*)"'
$script:RxPreTokens = [regex]'"preTokens":(\d+)'
$script:RxText = [regex]'"text":"((?:[^"\\]|\\.)*)"'
$script:RxCwd = [regex]'"cwd":"((?:[^"\\]|\\.)*)"'
$script:RxToolId = [regex]'"id":"(toolu_[^"]+)"'
$script:RxToolResultId = [regex]'"tool_use_id":"(toolu_[^"]+)"'
$script:RxContent = [regex]'"content":"((?:[^"\\]|\\.)*)"'
$script:KeepFeed = 8
$script:RxPattern = [regex]'"(?:pattern|description|url|query)":"((?:[^"\\]|\\.)*)"'
$script:RxCache5m = [regex]'"ephemeral_5m_input_tokens":(\d+)'
$script:RxCache1h = [regex]'"ephemeral_1h_input_tokens":(\d+)'
$script:KeepFileList = 15
$script:EditTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
$script:ShellTools = @('Bash', 'PowerShell')
$script:MaxFiles = 500
$script:KeepCommands = 5
$script:ChunkBytes = 4MB   # сколько журнала читается в память за раз

function New-TranscriptState {
    # feed — лента последних событий: @{ ts; k = you|claude|tool; text; id (у инструмента); ms (сколько шёл) }.
    return [ordered]@{ v = 5; feed = @(); offset = [int64]0; started = ''; output = [int64]0; context = [int64]0; tools = 0; prompts = 0; lastId = ''; lastOut = [int64]0
        model = ''; maxCtx = [int64]0; compactions = 0; files = @(); toolCounts = @{}; commands = @(); lastActivity = ''; apiError = ''; apiErrorText = ''
        cost = [double]0; mIn = [int64]0; mRead = [int64]0; m5 = [int64]0; m1 = [int64]0; mModel = ''; mFast = $false; cwd = ''; cwdOk = $false; dirKey = ''; lastTool = ''; sub = $false }
}

function ConvertFrom-JsonString([string]$Escaped) {
    # Содержимое строки JSON без кавычек → текст (\n, \", \\, \uXXXX).
    try { return [regex]::Unescape($Escaped) } catch { return $Escaped }
}

function Get-NotifierContextWindow {
    <#
    .SYNOPSIS
    Размер окна контекста модели (оценка): 1 млн — у моделей с [1m], у семейства Claude 5 (кроме Haiku)
    и если в сеансе контекст уже был больше 200 тыс.; иначе 200 тыс.
    #>
    param([AllowEmptyString()][string]$Model = '', [int64]$MaxSeen = 0)
    if ($Model -match '\[1m\]' -or $MaxSeen -gt 200000) { return [int64]1000000 }
    if ($Model -match '^claude-(opus|sonnet|fable)-5') { return [int64]1000000 }
    return [int64]200000
}

function Add-ToolUses($State, [string]$Line, [string]$Ts = '', [switch]$Feed) {
    # Каждый вызов инструмента: имя, изменённый файл (Edit/Write…), команда оболочки (Bash/PowerShell).
    $parts = $Line -split '"type":"tool_use"'
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $seg = $parts[$i]
        $m = $script:RxToolName.Match($seg)
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        if ($State.toolCounts.ContainsKey($name)) { $State.toolCounts[$name]++ } else { $State.toolCounts[$name] = 1 }
        # Последнее действие — для строки «что делает агент»: инструмент и его цель (файл, команда, шаблон).
        $target = ''
        $fm = $script:RxFilePath.Match($seg); $cm = $script:RxCommand.Match($seg); $pm = $script:RxPattern.Match($seg)
        if ($fm.Success) { $target = [IO.Path]::GetFileName((ConvertFrom-JsonString $fm.Groups[1].Value)) }
        elseif ($cm.Success) { $target = ((ConvertFrom-JsonString $cm.Groups[1].Value) -split "`n")[0].Trim() }
        elseif ($pm.Success) { $target = ((ConvertFrom-JsonString $pm.Groups[1].Value) -split "`n")[0].Trim() }
        if ($target.Length -gt 70) { $target = $target.Substring(0, 69) + [char]0x2026 }
        $State.lastTool = ($name -replace '^mcp__.*__', '')
        if ($target) { $State.lastTool += ": $target" }
        if ($Feed) {
            $idm = $script:RxToolId.Match($seg)
            $tid = ''
            if ($idm.Success) { $tid = $idm.Groups[1].Value }
            Add-FeedItem $State $Ts 'tool' $State.lastTool $tid
        }
        if ($script:EditTools -contains $name) {
            $f = $script:RxFilePath.Match($seg)
            if ($f.Success) {
                $path = ConvertFrom-JsonString $f.Groups[1].Value
                if (@($State.files) -notcontains $path -and @($State.files).Count -lt $script:MaxFiles) { $State.files = @($State.files) + $path }
            }
        }
        elseif ($script:ShellTools -contains $name) {
            $c = $script:RxCommand.Match($seg)
            if ($c.Success) {
                $cmd = ((ConvertFrom-JsonString $c.Groups[1].Value) -split "`n")[0].Trim()
                if ($cmd.Length -gt 120) { $cmd = $cmd.Substring(0, 119) + [char]0x2026 }
                $State.commands = @(@(@($State.commands) + $cmd) | Select-Object -Last $script:KeepCommands)
            }
        }
    }
}

function Add-FeedItem($State, [string]$Ts, [string]$Kind, [string]$Text, [string]$Id = '') {
    # Лента: последние $KeepFeed событий; текст — первая непустая строка, до 120 знаков.
    $t = (@(($Text -replace "`r", '') -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) + '')[0]
    if ($t -eq '') { return }
    if ($t.Length -gt 120) { $t = $t.Substring(0, 119) + [char]0x2026 }
    $item = [pscustomobject][ordered]@{ ts = $Ts; k = $Kind; text = $t; id = $Id; ms = -1 }
    $list = @(@($State.feed) + $item)   # без конвейера: первый проход по журналу — тысячи строк
    if ($list.Count -gt $script:KeepFeed) { $list = $list[($list.Count - $script:KeepFeed)..($list.Count - 1)] }
    $State.feed = @($list)
}

function Set-FeedToolDone($State, [string]$Line, [string]$Ts) {
    # Результат инструмента: сколько он шёл (от вызова до результата).
    foreach ($m in $script:RxToolResultId.Matches($Line)) {
        foreach ($it in @($State.feed)) {
            if ($it.k -ne 'tool' -or $it.id -ne $m.Groups[1].Value -or [int64]$it.ms -ge 0) { continue }
            $a = [DateTimeOffset]::MinValue; $b = [DateTimeOffset]::MinValue
            $inv = [Globalization.CultureInfo]::InvariantCulture
            if ([DateTimeOffset]::TryParse([string]$it.ts, $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$a) -and
                [DateTimeOffset]::TryParse($Ts, $inv, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$b)) {
                $it.ms = [int64][Math]::Max(0, ($b - $a).TotalMilliseconds)
            }
        }
    }
}

function Get-StatePath([string]$TranscriptPath, [string]$StateDir) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($TranscriptPath.ToLowerInvariant())) } finally { $sha.Dispose() }
    return (Join-Path $StateDir ((-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })) + '.json'))
}

function Get-StateMessageCost($State) {
    return (Get-NotifierMessageCost -Model $State.mModel -InTokens $State.mIn -Output $State.lastOut -CacheRead $State.mRead -Cache5m $State.m5 -Cache1h $State.m1 -Fast:([bool]$State.mFast))
}

function Max-Int([regex]$Rx, [string]$Line, [int64]$Old) {
    $m = $Rx.Match($Line)
    if ($m.Success) { return [Math]::Max($Old, [int64]$m.Groups[1].Value) }
    return $Old
}

function First-Int([regex]$Rx, [string]$Line) {
    $m = $Rx.Match($Line)
    if ($m.Success) { return [int64]$m.Groups[1].Value }
    return [int64]0
}

function Update-TranscriptState {
    <# .SYNOPSIS Обрабатывает одну строку журнала и обновляет итоги. #>
    param([Parameter(Mandatory = $true)]$State, [Parameter(Mandatory = $true)][string]$Line)
    if ($State.started -eq '') {
        $ts = $script:RxTimestamp.Match($Line)
        if ($ts.Success) { $State.started = $ts.Groups[1].Value }
    }
    # Папка проекта: тот cwd, из которого Claude Code назвал папку журнала (каждый символ кроме букв и цифр → «-»);
    # пока такого нет — последний встреченный.
    if (-not $State.cwdOk) {
        $cw = $script:RxCwd.Match($Line)
        if ($cw.Success) {
            $c = (ConvertFrom-JsonString $cw.Groups[1].Value).TrimEnd('\', '/')
            $State.cwd = $c
            if ($State.dirKey -ne '' -and ($c -replace '[^A-Za-z0-9]', '-') -eq $State.dirKey) { $State.cwdOk = $true }
        }
    }
    if ($Line.Contains('"subtype":"compact_boundary"')) {
        # Сжатие истории: контекст сброшен; размер до сжатия подсказывает окно модели.
        $State.compactions++
        $pre = First-Int $script:RxPreTokens $Line
        if ($pre -gt $State.maxCtx) { $State.maxCtx = $pre }
        $State.context = [int64]0
        return
    }
    if ($Line.Contains('"type":"assistant"')) {
        $State.tools += $script:RxToolUse.Matches($Line).Count
        $own = $State.sub -or -not $Line.Contains('"isSidechain":true')
        $tsm = $script:RxTimestamp.Match($Line)
        $lineTs = ''
        if ($tsm.Success) { $lineTs = $tsm.Groups[1].Value }
        if ($own -and $Line.Contains('"type":"text"') -and -not $Line.Contains('"isApiErrorMessage":true')) {
            $tx = $script:RxText.Match($Line)
            if ($tx.Success) { Add-FeedItem $State $lineTs 'claude' (ConvertFrom-JsonString $tx.Groups[1].Value) }
        }
        if ($Line.Contains('"tool_use"')) { Add-ToolUses $State $Line $lineTs -Feed:$own }
        $mm = $script:RxModel.Match($Line)
        if ($mm.Success) { $State.model = $mm.Groups[1].Value }
        # Ошибка API (перегрузка, лимит, обрыв связи): Claude Code пишет её как ответ с isApiErrorMessage.
        if ($Line.Contains('"isApiErrorMessage":true') -and -not $Line.Contains('"isSidechain":true')) {
            $te = $script:RxTimestamp.Match($Line)
            if ($te.Success) { $State.apiError = $te.Groups[1].Value }
            $tx = $script:RxText.Match($Line)
            $text = 'API Error'
            if ($tx.Success) { $text = ((ConvertFrom-JsonString $tx.Groups[1].Value) -split "`n")[0].Trim() }
            if ($text.Length -gt 160) { $text = $text.Substring(0, 159) + [char]0x2026 }
            $State.apiErrorText = $text
            return
        }
        # Время последнего ответа Claude (без субагентов): по нему трей видит, что сеанс снова работает.
        if (-not $Line.Contains('"isSidechain":true')) {
            $ta = $script:RxTimestamp.Match($Line)
            if ($ta.Success -and $ta.Groups[1].Value -gt [string]$State.lastActivity) { $State.lastActivity = $ta.Groups[1].Value }
        }
        # Ответы субагентов (isSidechain) в журнале сеанса — их собственный контекст, не контекст сеанса.
        # В журнале самого субагента (sub) все строки такие — там они и считаются.
        if ($Line.Contains('"usage"') -and ($State.sub -or -not $Line.Contains('"isSidechain":true'))) {
            $id = $script:RxMsgId.Match($Line)
            $msgId = ''
            if ($id.Success) { $msgId = $id.Groups[1].Value }
            # Одно сообщение пишется несколькими строками с одной и той же usage: считаем его один раз.
            if ($msgId -ne $State.lastId) {
                $State.output += $State.lastOut
                $State.cost += Get-StateMessageCost $State
                $State.lastId = $msgId
                $State.lastOut = [int64]0
                $State.mIn = [int64]0; $State.mRead = [int64]0; $State.m5 = [int64]0; $State.m1 = [int64]0
                $State.mModel = ''
                if ($mm.Success) { $State.mModel = $mm.Groups[1].Value }
                $State.mFast = $Line.Contains('"speed":"fast"')
            }
            $State.lastOut = [Math]::Max($State.lastOut, (First-Int $script:RxOutput $Line))
            $State.mIn = Max-Int $script:RxInput $Line $State.mIn
            $State.mRead = Max-Int $script:RxCacheRead $Line $State.mRead
            $c5 = $script:RxCache5m.Match($Line); $c1 = $script:RxCache1h.Match($Line)
            if ($c5.Success -or $c1.Success) { $State.m5 = Max-Int $script:RxCache5m $Line $State.m5; $State.m1 = Max-Int $script:RxCache1h $Line $State.m1 }
            else { $State.m5 = Max-Int $script:RxCacheNew $Line $State.m5 }
            $State.context = (First-Int $script:RxInput $Line) + (First-Int $script:RxCacheRead $Line) + (First-Int $script:RxCacheNew $Line)
            if ($State.context -gt $State.maxCtx) { $State.maxCtx = $State.context }
        }
    }
    elseif ($Line.Contains('"type":"user"') -and $Line.Contains('"tool_result"')) {
        if ($State.sub -or -not $Line.Contains('"isSidechain":true')) {
            $tsm = $script:RxTimestamp.Match($Line)
            if ($tsm.Success) { Set-FeedToolDone $State $Line $tsm.Groups[1].Value }
        }
    }
    elseif ($Line.Contains('"type":"user"') -and -not $Line.Contains('"isMeta":true')) {
        $State.prompts++
        if ($State.sub -or -not $Line.Contains('"isSidechain":true')) {
            $tsm = $script:RxTimestamp.Match($Line)
            $cm = $script:RxContent.Match($Line)
            if (-not $cm.Success) { $cm = $script:RxText.Match($Line) }
            if ($tsm.Success -and $cm.Success) {
                $text = ConvertFrom-JsonString $cm.Groups[1].Value
                # Служебные вставки Claude Code (<command-name>, <local-command-stdout>…) — не ваши сообщения.
                if (-not $text.TrimStart().StartsWith('<')) { Add-FeedItem $State $tsm.Groups[1].Value 'you' $text }
            }
        }
    }
}

function Get-NotifierTranscriptStats {
    <#
    .SYNOPSIS
    Итоги сеанса по журналу: @{ started; context; output; tools; prompts } или $null, если журнала нет.

    .DESCRIPTION
    context — размер контекста последнего ответа (input + cache read + cache creation), output — сумма
    токенов ответов, tools — вызовов инструментов, prompts — сообщений пользователя (без результатов инструментов).
    Читается только новая часть файла; если файл стал короче (перезаписан), подсчёт начинается заново.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory = $true)][string]$StateDir
    )
    if ([string]::IsNullOrEmpty($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    $statePath = Get-StatePath $Path $StateDir
    $state = New-TranscriptState
    if (Test-Path -LiteralPath $statePath) {
        try {
            $saved = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($statePath, [Text.Encoding]::UTF8)) -ErrorAction Stop
            if (-not $saved.PSObject.Properties['v'] -or [int]$saved.v -ne 5) { throw 'old state' }   # прежний формат: перечитать журнал целиком
            foreach ($k in @($state.Keys)) { if ($saved.PSObject.Properties[$k]) { $state[$k] = $saved.$k } }
            $state.offset = [int64]$state.offset; $state.output = [int64]$state.output; $state.lastOut = [int64]$state.lastOut; $state.context = [int64]$state.context
            $state.maxCtx = [int64]$state.maxCtx
            foreach ($k in @('mIn', 'mRead', 'm5', 'm1')) { $state[$k] = [int64]$state[$k] }
            $state.cost = [double]$state.cost; $state.mFast = [bool]$state.mFast; $state.cwdOk = [bool]$state.cwdOk
            $state.files = @(@($state.files) | Where-Object { $_ -is [string] })
            $state.commands = @(@($state.commands) | Where-Object { $_ -is [string] })
            $state.feed = @(@($state.feed) | Where-Object { $_ -and $_.PSObject.Properties['k'] })
            $counts = @{}
            if ($state.toolCounts -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $state.toolCounts.PSObject.Properties) { $counts[$p.Name] = [int]$p.Value } }
            elseif ($state.toolCounts -is [hashtable]) { $counts = $state.toolCounts }
            $state.toolCounts = $counts
        }
        catch { $state = New-TranscriptState }
    }
    $isSub = $Path -match '[\\/]subagents[\\/]'
    $dir = Split-Path $Path -Parent
    if ($isSub) { $dir = Split-Path (Split-Path $dir -Parent) -Parent }
    $dirKey = Split-Path $dir -Leaf
    $state.sub = $isSub; $state.dirKey = $dirKey
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $state.offset) { $state = New-TranscriptState; $state.sub = $isSub; $state.dirKey = $dirKey }
        [void]$fs.Seek($state.offset, [IO.SeekOrigin]::Begin)
        # Кусками по 4 МБ: первый проход по большому журналу не выделяет память под весь хвост сразу.
        while ($fs.Length - $state.offset -gt 0) {
            $want = [int][Math]::Min($fs.Length - $state.offset, $script:ChunkBytes)
            [void]$fs.Seek($state.offset, [IO.SeekOrigin]::Begin)
            $buffer = New-Object byte[] $want
            $read = 0
            while ($read -lt $want) { $n = $fs.Read($buffer, $read, $want - $read); if ($n -le 0) { break }; $read += $n }
            if ($read -le 0) { break }
            # Только целые строки: последняя может дописываться прямо сейчас.
            $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
            if ($end -lt 0) {
                if ($read -eq $script:ChunkBytes) { $state.offset += $read; continue }   # строка длиннее куска — пропустить
                break
            }
            $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
            # Сбой на одной строке не останавливает разбор: иначе смещение не сдвинется и она будет читаться вечно.
            foreach ($line in $text.Split("`n")) { if ($line.Length -gt 0) { try { Update-TranscriptState -State $state -Line $line } catch { } } }
            $state.offset += $end + 1
        }
    }
    finally { $fs.Dispose() }
    # Атомарно (временный файл + замена): оборванная запись не заставит перечитывать журнал с начала.
    try {
        $tmp = "$statePath.tmp-$PID"
        [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $state -Compress), (New-Object System.Text.UTF8Encoding $false))
        Move-Item -LiteralPath $tmp -Destination $statePath -Force
    }
    catch { }
    $window = Get-NotifierContextWindow -Model $state.model -MaxSeen $state.maxCtx
    $top = @($state.toolCounts.GetEnumerator() | Sort-Object -Property @{ Expression = { $_.Value }; Descending = $true }, @{ Expression = { $_.Key } } |
        Select-Object -First 3 | ForEach-Object { "$($_.Key -replace '^mcp__.*__', '') $($_.Value)" })
    return [ordered]@{
        started     = [string]$state.started
        context     = [int64]$state.context
        window      = [int64]$window
        percent     = [int][Math]::Min(100, [Math]::Round(100.0 * $state.context / $window))
        output      = [int64]($state.output + $state.lastOut)
        tools       = [int]$state.tools
        prompts     = [int]$state.prompts
        model       = [string]$state.model
        compactions = [int]$state.compactions
        lastActivity = [string]$state.lastActivity
        apiError    = [string]$state.apiError
        apiErrorText = [string]$state.apiErrorText
        cost        = [double]($state.cost + (Get-StateMessageCost $state))
        cwd         = [string]$state.cwd
        lastTool    = [string]$state.lastTool
        fileList    = @(@($state.files) | Select-Object -Last $script:KeepFileList)
        files       = [int]@($state.files).Count
        recentFiles = @(@($state.files) | Select-Object -Last 3 | ForEach-Object { [IO.Path]::GetFileName($_) })
        topTools    = $top
        commands    = @(@($state.commands) | Select-Object -Last 3)
        feed        = @(@($state.feed) | ForEach-Object { [pscustomobject][ordered]@{ ts = [string]$_.ts; k = [string]$_.k; text = [string]$_.text; ms = [int64]$_.ms } })
    }
}

function Format-NotifierTokens {
    <# .SYNOPSIS 950 → «950», 12 400 → «12 тыс.», 1 250 000 → «1,3 млн». #>
    param([int64]$N)
    if ($N -lt 1000) { return [string]$N }
    $away = [MidpointRounding]::AwayFromZero   # не банковское округление: 1,25 → 1,3
    if ($N -lt 1000000) { return ('{0} тыс.' -f [Math]::Round($N / 1000, $away)) }
    return ('{0} млн' -f ([Math]::Round($N / 1000000, 1, $away)).ToString([Globalization.CultureInfo]::GetCultureInfo('ru-RU')))
}

function Format-NotifierSessionDetails {
    <#
    .SYNOPSIS
    Подробности сеанса таблицей: строки «Подпись<Tab>Значение» (окно рисует подпись серым слева, значение справа;
    для страницы телефона Tab заменяется на «: »). -NoAgents — без строк агентов (карточка показывает их подстроками).
    #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow, [switch]$NoAgents)
    $lines = @()
    $tab = "`t"
    $dot = " $([char]0x00B7) "
    $st = ''
    if ($Session.PSObject.Properties['started']) { $st = [string]$Session.started }
    $parsed = [DateTimeOffset]::MinValue
    if ($st -and [DateTimeOffset]::TryParse($st, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        $local = $parsed.ToLocalTime()
        $when = $local.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if ($local.Date -ne [DateTime]::Now.Date) { $when = $local.ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        $lines += "Начат${tab}в $when${dot}идёт $(Format-NotifierElapsed -Ts $st -Now $Now)"
    }
    $stats = $null
    if ($Session.PSObject.Properties['stats']) { $stats = $Session.stats }
    if ($stats) {
        $ctx = "$(Format-NotifierTokens ([int64]$stats.context)) токенов"
        if ($stats.PSObject.Properties['window'] -and [int64]$stats.window -gt 0) {
            $ctx = "$([int]$stats.percent) % $([char]0x2014) $(Format-NotifierTokens ([int64]$stats.context)) из $(Format-NotifierTokens ([int64]$stats.window))"
        }
        $lines += "Контекст${tab}$ctx${dot}ответы $(Format-NotifierTokens ([int64]$stats.output))"
        $line = "Работа${tab}запросов $([int]$stats.prompts)${dot}действий $([int]$stats.tools)"
        if ($stats.PSObject.Properties['compactions'] -and [int]$stats.compactions -gt 0) { $line += "${dot}сжатий $([int]$stats.compactions)" }
        $lines += $line
        if ($stats.PSObject.Properties['files'] -and [int]$stats.files -gt 0) {
            $line = "Файлы${tab}изменено $([int]$stats.files)"
            $recent = @($stats.recentFiles | Where-Object { $_ })
            if ($recent.Count -gt 0) { $line += ": $($recent -join ', ')" }
            $lines += $line
        }
        if ($stats.PSObject.Properties['topTools'] -and @($stats.topTools).Count -gt 0) { $lines += "Чаще всего${tab}$((@($stats.topTools)) -join ', ')" }
        if ($stats.PSObject.Properties['commands'] -and @($stats.commands).Count -gt 0) {
            $lines += "Команда${tab}$(Format-NotifierShortText (@($stats.commands)[-1]))"
        }
        $cost = 0.0; $agentsCost = 0.0
        if ($stats.PSObject.Properties['cost']) { $cost = [double]$stats.cost }
        if ($stats.PSObject.Properties['agentsCost']) { $agentsCost = [double]$stats.agentsCost }
        if ($cost + $agentsCost -gt 0) {
            $line = "Стоимость${tab}$([char]0x2248) $(Format-NotifierCost ($cost + $agentsCost)) по ценам API"
            if ($agentsCost -gt 0) { $line += " (агенты $(Format-NotifierCost $agentsCost))" }
            $lines += $line
        }
    }
    # Работающие агенты: что поручено и что делает сейчас.
    if (-not $NoAgents -and $Session.PSObject.Properties['agents'] -and [string]$Session.state -eq 'working') {
        foreach ($text in (Format-NotifierAgentLines $Session 4)) { $lines += "Агент${tab}$text" }
    }
    $prompt = ''
    if ($Session.PSObject.Properties['prompt']) { $prompt = [string]$Session.prompt }
    if ($prompt) { $lines += "Ваш запрос${tab}$prompt" }
    # Лента: последние события сеанса — ваши сообщения, ответы Claude, инструменты и сколько они шли.
    if ($stats -and $stats.PSObject.Properties['feed']) {
        $feed = @(@($stats.feed) | Where-Object { $_ } | Select-Object -Last 5)
        for ($i = 0; $i -lt $feed.Count; $i++) {
            $it = $feed[$i]
            $p = [DateTimeOffset]::MinValue
            $when = ''
            if ([DateTimeOffset]::TryParse([string]$it.ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$p)) {
                $when = $p.ToLocalTime().ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            }
            $text = Format-NotifierShortText ([string]$it.text)
            switch ([string]$it.k) {
                'you' { $text = "Вы: $text" }
                'claude' { $text = "Claude: $text" }
                'tool' {
                    $ms = [int64]$it.ms
                    if ($ms -ge 1000) { $text += "${dot}$(Format-NotifierDuration $ms)" }
                    elseif ($ms -lt 0 -and $i -eq $feed.Count - 1 -and [string]$Session.state -eq 'working') { $text += "${dot}идёт" }
                }
            }
            $lines += "$when${tab}$text"
        }
    }
    return ($lines -join "`n")
}

function Format-NotifierDuration([int64]$Ms) {
    # 3 400 → «3 с», 95 000 → «1 мин 35 с», 3 900 000 → «1 ч 5 мин».
    $s = [int64][Math]::Floor($Ms / 1000)
    if ($s -lt 60) { return "$s с" }
    if ($s -lt 3600) { $r = "$([Math]::Floor($s / 60)) мин"; if ($s % 60) { $r += " $($s % 60) с" }; return $r }
    $r = "$([Math]::Floor($s / 3600)) ч"
    if (($s % 3600) -ge 60) { $r += " $([Math]::Floor(($s % 3600) / 60)) мин" }
    return $r
}

function Format-NotifierAgentLines {
    <# .SYNOPSIS Строки работающих агентов: «задача — последнее действие»; больше Max — последняя строка «…и ещё N». #>
    param($Session, [int]$Max = 3)
    $agents = @()
    if ($Session -and $Session.PSObject.Properties['agents']) { $agents = @(@($Session.agents) | Where-Object { $_ }) }
    $out = @()
    foreach ($a in ($agents | Select-Object -First $Max)) {
        $t = [string]$a.name
        if ([string]$a.doing) { $t += " $([char]0x2014) $(Format-NotifierShortText ([string]$a.doing))" }
        $out += $t
    }
    if ($agents.Count -gt $Max) { $out += "$([char]0x2026)и ещё $($agents.Count - $Max)" }
    return $out
}

function Get-NotifierJournalWriteTime {
    <#
    .SYNOPSIS
    Когда журнал сеанса последний раз менялся (UTC): сам журнал и журналы его субагентов
    (<журнал без .jsonl>\subagents\*.jsonl) — пока работает субагент, основной журнал молчит.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [switch]$SubagentsOnly)
    $t = [datetime]::MinValue
    if (-not $SubagentsOnly) { try { if ([IO.File]::Exists($Path)) { $t = [IO.File]::GetLastWriteTimeUtc($Path) } } catch { } }
    $sub = Join-Path ([IO.Path]::ChangeExtension($Path, $null).TrimEnd('.')) 'subagents'
    try {
        if ([IO.Directory]::Exists($sub)) {
            foreach ($f in [IO.Directory]::GetFiles($sub, '*.jsonl')) { $w = [IO.File]::GetLastWriteTimeUtc($f); if ($w -gt $t) { $t = $w } }
        }
    }
    catch { }
    return $t
}

function Test-NotifierHelperTranscript {
    <#
    .SYNOPSIS
    Журнал служебного запуска Claude — сводки сеанса, которую плагин (ECC) делает через «claude -p» при завершении
    сеанса: первый запрос начинается с «Below is a conversation log from a Claude Code coding session».
    $true / $false; $null — журнала ещё нет или первого запроса в нём пока нет (решить позже).
    #>
    param([AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    $reader = $null
    try {
        if (-not [IO.File]::Exists($Path)) { return $null }
        $fs = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        $reader = [IO.StreamReader]::new($fs, [Text.Encoding]::UTF8)
        for ($i = 0; $i -lt 40; $i++) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -notmatch '"type"\s*:\s*"user"') { continue }
            return ($line -match 'Below is a conversation log from a Claude Code coding session')
        }
    }
    catch { }
    finally { if ($reader) { $reader.Dispose() } }
    return $null
}

function Get-NotifierLastAnswer {
    <#
    .SYNOPSIS
    Полный последний ответ Claude из журнала сеанса (последний текстовый блок ответа, без субагентов),
    без разметки Markdown. Читается только хвост файла (по умолчанию 1 МБ). Нет журнала или ответа — ''.
    #>
    param([AllowEmptyString()][string]$Path, [int]$TailBytes = 1048576, [int]$MaxChars = 20000)
    if ([string]::IsNullOrEmpty($Path) -or -not [IO.File]::Exists($Path)) { return '' }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max([int64]0, $fs.Length - $TailBytes)
        [void]$fs.Seek($start, [IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] ($fs.Length - $start)
        $read = 0
        while ($read -lt $buf.Length) { $n = $fs.Read($buf, $read, $buf.Length - $read); if ($n -le 0) { break }; $read += $n }
    }
    finally { $fs.Dispose() }
    $lines = [Text.Encoding]::UTF8.GetString($buf, 0, $read).Split("`n")
    $rx = [regex]'"type":"text","text":"((?:[^"\\]|\\.)*)"'
    for ($i = $lines.Length - 1; $i -ge 0; $i--) {
        $l = $lines[$i]
        if (-not $l.Contains('"type":"assistant"') -or $l.Contains('"isSidechain":true') -or -not $l.Contains('"type":"text"')) { continue }
        $parts = @($rx.Matches($l) | ForEach-Object { ConvertFrom-JsonString $_.Groups[1].Value } | Where-Object { $_.Trim() -ne '' })
        if ($parts.Count -eq 0) { continue }
        $text = ConvertTo-NotifierPlainText (($parts -join "`n`n").Trim())
        if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) + [char]0x2026 }
        return $text
    }
    return ''
}

function Test-NotifierAnswerAsks {
    <#
    .SYNOPSIS
    Ждёт ли ответ Claude ответа от вас: в последних двух непустых строках есть вопрос («…?»). Знак «?» в ссылках
    и в `коде` не считается. Нужно, чтобы кнопки быстрого ответа («Продолжай», «Да», «Нет») не висели
    под ответами, в которых Claude ничего не спрашивал.
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    return ((Get-NotifierAnswerQuestion $Text) -ne '')
}

function Get-NotifierAnswerQuestion {
    <#
    .SYNOPSIS
    Вопрос из конца ответа Claude — последняя из двух последних непустых строк, где есть «?» (без ссылок и `кода`),
    не длиннее MaxLength. Нет вопроса — ''. По нему шторка показывает бегущую строку «Закоммитить и отправить?».
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text, [int]$MaxLength = 90)
    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
    $lines = @($Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
    $last = @($lines | Select-Object -Last 2)
    for ($i = $last.Count - 1; $i -ge 0; $i--) {
        $l = [string]$last[$i]
        $clean = ($l -replace 'https?://\S+', '' -replace '`[^`]*`', '').Trim()
        if ($clean -notmatch '\?') { continue }
        $q = ($l -replace '^\s*[-*•>]\s+', '' -replace '\*\*', '').Trim()
        if ($q.Length -gt $MaxLength) { $q = $q.Substring(0, $MaxLength - 1).TrimEnd() + [char]0x2026 }
        return $q
    }
    return ''
}

$script:AskCache = @{}

function Get-NotifierSessionQuestion {
    <#
    .SYNOPSIS
    Вопрос в конце последнего ответа сеанса — по журналу (transcript); '' — Claude ничего не спросил. Кешируется
    по размеру и времени изменения журнала. Журнала нет (сеанс Mac) — по Fallback (начало ответа из события).
    #>
    param([Parameter(Mandatory = $true)]$Session, [AllowEmptyString()][AllowNull()][string]$Fallback = '')
    $tp = ''
    if ($Session.PSObject.Properties['transcript']) { $tp = [string]$Session.transcript }
    if ($tp -ne '' -and [IO.File]::Exists($tp)) {
        $fi = New-Object IO.FileInfo $tp
        $key = "$($fi.Length)|$($fi.LastWriteTimeUtc.Ticks)"
        $c = $script:AskCache[$tp]
        if ($c -and $c.Key -eq $key) { return $c.Value }
        $v = Get-NotifierAnswerQuestion (Get-NotifierLastAnswer -Path $tp -TailBytes 262144)
        if ($script:AskCache.Count -gt 200) { $script:AskCache.Clear() }
        $script:AskCache[$tp] = @{ Key = $key; Value = $v }
        return $v
    }
    return (Get-NotifierAnswerQuestion $Fallback)
}

function Test-NotifierSessionAsks {
    <# .SYNOPSIS Спрашивает ли Claude что-то в последнем ответе сеанса (см. Get-NotifierSessionQuestion). #>
    param([Parameter(Mandatory = $true)]$Session, [AllowEmptyString()][AllowNull()][string]$Fallback = '')
    return ((Get-NotifierSessionQuestion -Session $Session -Fallback $Fallback) -ne '')
}

function Format-NotifierApiError {
    <# .SYNOPSIS Текст ошибки API из журнала → понятная фраза. #>
    param([AllowEmptyString()][string]$Text)
    if ($Text -match '(?i)overloaded|\b529\b') { return 'Серверы Anthropic перегружены (529). Повторите запрос чуть позже.' }
    if ($Text -match '(?i)rate.?limit|\b429\b') { return 'Достигнут лимит запросов. Подождите и повторите.' }
    if ($Text -match '(?i)usage limit|limit reached|resets') { return "Исчерпан лимит Claude: $Text" }
    if ($Text -match '(?i)timed? ?out|timeout|ECONNRESET|socket|network|fetch failed|connection') { return "Связь с сервером прервалась: $Text" }
    if ($Text -match '(?i)\b5\d\d\b|internal server error|api_error') { return "Ошибка на стороне сервера: $Text" }
    return $Text
}

Export-ModuleMember -Function Test-NotifierHelperTranscript, Get-NotifierLastAnswer,Test-NotifierAnswerAsks, Get-NotifierAnswerQuestion, Get-NotifierSessionQuestion, Test-NotifierSessionAsks, Get-NotifierTranscriptStats, Format-NotifierTokens, Format-NotifierSessionDetails, Format-NotifierDuration, Format-NotifierAgentLines, Get-NotifierContextWindow, Get-NotifierJournalWriteTime, Format-NotifierApiError
