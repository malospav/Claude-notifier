Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Sessions.psm1')

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
$script:EditTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
$script:ShellTools = @('Bash', 'PowerShell')
$script:MaxFiles = 500
$script:KeepCommands = 5

function New-TranscriptState {
    return [ordered]@{ v = 3; offset = [int64]0; started = ''; output = [int64]0; context = [int64]0; tools = 0; prompts = 0; lastId = ''; lastOut = [int64]0
        model = ''; maxCtx = [int64]0; compactions = 0; files = @(); toolCounts = @{}; commands = @(); lastActivity = ''; apiError = ''; apiErrorText = '' }
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

function Add-ToolUses($State, [string]$Line) {
    # Каждый вызов инструмента: имя, изменённый файл (Edit/Write…), команда оболочки (Bash/PowerShell).
    $parts = $Line -split '"type":"tool_use"'
    for ($i = 1; $i -lt $parts.Count; $i++) {
        $seg = $parts[$i]
        $m = $script:RxToolName.Match($seg)
        if (-not $m.Success) { continue }
        $name = $m.Groups[1].Value
        if ($State.toolCounts.ContainsKey($name)) { $State.toolCounts[$name]++ } else { $State.toolCounts[$name] = 1 }
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

function Get-StatePath([string]$TranscriptPath, [string]$StateDir) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($TranscriptPath.ToLowerInvariant())) } finally { $sha.Dispose() }
    return (Join-Path $StateDir ((-join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })) + '.json'))
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
        if ($Line.Contains('"tool_use"')) { Add-ToolUses $State $Line }
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
        # Ответы субагентов (isSidechain) — их собственный контекст, не контекст сеанса.
        if ($Line.Contains('"usage"') -and -not $Line.Contains('"isSidechain":true')) {
            $id = $script:RxMsgId.Match($Line)
            $msgId = ''
            if ($id.Success) { $msgId = $id.Groups[1].Value }
            # Одно сообщение пишется несколькими строками с одной и той же usage: считаем его один раз.
            if ($msgId -ne $State.lastId) {
                $State.output += $State.lastOut
                $State.lastId = $msgId
                $State.lastOut = [int64]0
            }
            $State.lastOut = [Math]::Max($State.lastOut, (First-Int $script:RxOutput $Line))
            $State.context = (First-Int $script:RxInput $Line) + (First-Int $script:RxCacheRead $Line) + (First-Int $script:RxCacheNew $Line)
            if ($State.context -gt $State.maxCtx) { $State.maxCtx = $State.context }
        }
    }
    elseif ($Line.Contains('"type":"user"') -and -not $Line.Contains('"tool_result"') -and -not $Line.Contains('"isMeta":true')) {
        $State.prompts++
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
            if (-not $saved.PSObject.Properties['v'] -or [int]$saved.v -ne 3) { throw 'old state' }   # прежний формат: перечитать журнал целиком
            foreach ($k in @($state.Keys)) { if ($saved.PSObject.Properties[$k]) { $state[$k] = $saved.$k } }
            $state.offset = [int64]$state.offset; $state.output = [int64]$state.output; $state.lastOut = [int64]$state.lastOut; $state.context = [int64]$state.context
            $state.maxCtx = [int64]$state.maxCtx
            $state.files = @(@($state.files) | Where-Object { $_ -is [string] })
            $state.commands = @(@($state.commands) | Where-Object { $_ -is [string] })
            $counts = @{}
            if ($state.toolCounts -is [System.Management.Automation.PSCustomObject]) { foreach ($p in $state.toolCounts.PSObject.Properties) { $counts[$p.Name] = [int]$p.Value } }
            elseif ($state.toolCounts -is [hashtable]) { $counts = $state.toolCounts }
            $state.toolCounts = $counts
        }
        catch { $state = New-TranscriptState }
    }
    $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($fs.Length -lt $state.offset) { $state = New-TranscriptState }
        [void]$fs.Seek($state.offset, [IO.SeekOrigin]::Begin)
        $remaining = $fs.Length - $state.offset
        if ($remaining -gt 0) {
            $buffer = New-Object byte[] $remaining
            $read = 0
            while ($read -lt $remaining) { $n = $fs.Read($buffer, $read, $remaining - $read); if ($n -le 0) { break }; $read += $n }
            # Только целые строки: последняя может дописываться прямо сейчас.
            $end = [Array]::LastIndexOf($buffer, [byte]10, $read - 1)
            if ($end -ge 0) {
                $text = [Text.Encoding]::UTF8.GetString($buffer, 0, $end + 1)
                foreach ($line in $text.Split("`n")) { if ($line.Length -gt 0) { Update-TranscriptState -State $state -Line $line } }
                $state.offset += $end + 1
            }
        }
    }
    finally { $fs.Dispose() }
    try { [IO.File]::WriteAllText($statePath, (ConvertTo-Json -InputObject $state -Compress), (New-Object System.Text.UTF8Encoding $false)) } catch { }
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
        files       = [int]@($state.files).Count
        recentFiles = @(@($state.files) | Select-Object -Last 3 | ForEach-Object { [IO.Path]::GetFileName($_) })
        topTools    = $top
        commands    = @(@($state.commands) | Select-Object -Last 3)
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
    <# .SYNOPSIS Строки подробностей сеанса: начало и длительность, контекст и токены, запросы и действия, ваш запрос. #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow)
    $lines = @()
    $started = $null
    $st = ''
    if ($Session.PSObject.Properties['started']) { $st = [string]$Session.started }
    $parsed = [DateTimeOffset]::MinValue
    if ($st -and [DateTimeOffset]::TryParse($st, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        $local = $parsed.ToLocalTime()
        $when = $local.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        if ($local.Date -ne [DateTime]::Now.Date) { $when = $local.ToString('dd.MM HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
        $lines += "Начат в $when $([char]0x00B7) идёт $(Format-NotifierElapsed -Ts $st -Now $Now)"
    }
    $stats = $null
    if ($Session.PSObject.Properties['stats']) { $stats = $Session.stats }
    if ($stats) {
        $dot = " $([char]0x00B7) "
        $ctx = "Контекст $(Format-NotifierTokens ([int64]$stats.context)) токенов"
        if ($stats.PSObject.Properties['window'] -and [int64]$stats.window -gt 0) {
            $ctx = "Контекст $([int]$stats.percent) % $([char]0x2014) $(Format-NotifierTokens ([int64]$stats.context)) из $(Format-NotifierTokens ([int64]$stats.window))"
        }
        $lines += "$ctx${dot}ответы $(Format-NotifierTokens ([int64]$stats.output))"
        $line = "Запросов $([int]$stats.prompts)${dot}действий $([int]$stats.tools)"
        if ($stats.PSObject.Properties['compactions'] -and [int]$stats.compactions -gt 0) { $line += "${dot}сжатий $([int]$stats.compactions)" }
        $lines += $line
        if ($stats.PSObject.Properties['files'] -and [int]$stats.files -gt 0) {
            $line = "Изменено файлов: $([int]$stats.files)"
            $recent = @($stats.recentFiles | Where-Object { $_ })
            if ($recent.Count -gt 0) { $line += " (последние: $($recent -join ', '))" }
            $lines += $line
        }
        if ($stats.PSObject.Properties['topTools'] -and @($stats.topTools).Count -gt 0) { $lines += "Чаще всего: $((@($stats.topTools)) -join ', ')" }
        if ($stats.PSObject.Properties['commands'] -and @($stats.commands).Count -gt 0) {
            $last = @($stats.commands)[-1]
            $lines += "Последняя команда: $last"
        }
    }
    $prompt = ''
    if ($Session.PSObject.Properties['prompt']) { $prompt = [string]$Session.prompt }
    if ($prompt) { $lines += "Ваш запрос: $prompt" }
    return ($lines -join "`n")
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

Export-ModuleMember -Function Get-NotifierTranscriptStats, Format-NotifierTokens, Format-NotifierSessionDetails, Get-NotifierContextWindow, Get-NotifierJournalWriteTime, Format-NotifierApiError
