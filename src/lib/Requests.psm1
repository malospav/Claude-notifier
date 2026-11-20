Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

# Ответы из приложения (ADR-008). Хук Claude Code и трей обмениваются файлами в <DataRoot>\requests:
#   perm-<id>.json           запрос разрешения или вопрос Claude (пишет хук PermissionRequest, ждёт решения)
#   perm-<id>.decision.json  решение (пишет трей или веб-API): allow | always | deny, ответы на вопрос
#   reply-<session>.json     хук Stop (asyncRewake) ждёт быстрого ответа на этот сеанс
#   reply-<session>.txt      быстрый ответ (пишет трей или веб-API)
# В запросе есть pid хука: если процесс завершился (вы ответили прямо в Claude, истекло время),
# трей убирает запрос и сразу переводит сеанс в «Работает».

$script:Utf8 = New-Object System.Text.UTF8Encoding $false

function Get-RequestsDir([string]$DataRoot) {
    $dir = Join-Path $DataRoot 'requests'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Write-JsonAtomic([string]$Path, $Object) {
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Object -Depth 12 -Compress), $script:Utf8)
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Read-JsonFile([string]$Path) {
    try { return (ConvertFrom-NotifierJson -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8))) } catch { return $null }
}

function Test-ProcessAlive([int]$ProcessId) {
    if ($ProcessId -le 0) { return $false }
    return ($null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue))
}

function Get-Prop($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($null -eq $p) { return $null }
    return $p.Value
}

function Get-NotifierRequestSummary {
    <#
    .SYNOPSIS
    Что показать пользователю: @{ kind = tool|question|plan; title; detail; options[]; canAlways }.
    question — один вопрос AskUserQuestion без множественного выбора: варианты ответа кнопками.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ToolName, $ToolInput, $Suggestions)
    $detail = ''
    switch -Regex ($ToolName) {
        '^AskUserQuestion$' {
            $qs = @(Get-Prop $ToolInput 'questions')
            if ($qs.Count -ge 1 -and $qs[0]) {
                $q = $qs[0]
                $opts = @(@(Get-Prop $q 'options') | ForEach-Object { [string](Get-Prop $_ 'label') } | Where-Object { $_ -ne '' })
                $single = ($qs.Count -eq 1) -and -not [bool](Get-Prop $q 'multiSelect')
                $text = [string](Get-Prop $q 'question')
                if ($single) { return @{ kind = 'question'; title = $text; detail = ''; options = $opts; canAlways = $false } }
                return @{ kind = 'question-complex'; title = $text; detail = "Вопросов: $($qs.Count) — ответьте в Claude"; options = @(); canAlways = $false }
            }
        }
        '^ExitPlanMode$' { return @{ kind = 'plan'; title = 'Утвердить план?'; detail = [string](Get-Prop $ToolInput 'plan'); options = @(); canAlways = $false } }
        '^Bash$|^PowerShell$' { $detail = [string](Get-Prop $ToolInput 'command') }
        '^(Edit|Write|Read|MultiEdit|NotebookEdit)$' { $detail = [string](Get-Prop $ToolInput 'file_path') }
        '^WebFetch$' { $detail = [string](Get-Prop $ToolInput 'url') }
        '^WebSearch$' { $detail = [string](Get-Prop $ToolInput 'query') }
        default { try { $detail = ConvertTo-Json -InputObject $ToolInput -Depth 4 -Compress } catch { $detail = '' } }
    }
    if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 399) + [char]0x2026 }
    $canAlways = @($Suggestions).Count -gt 0 -and $null -ne $Suggestions
    return @{ kind = 'tool'; title = "Разрешить $($ToolName)?"; detail = $detail; options = @(); canAlways = [bool]$canAlways }
}

# --- Сторона хука ---

function New-NotifierPermissionRequest {
    <#
    .SYNOPSIS
    Записывает запрос разрешения из входа хука PermissionRequest. Возвращает объект запроса (id, session_id, …).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$HookInput,
        [Parameter(Mandatory = $true)][int]$WaitSeconds,
        [string]$DataRoot,
        [string]$Device = ''   # запрос с другого устройства (Mac): его хук спрашивает решение у ПК по сети
    )
    $tool = [string](Get-Prop $HookInput 'tool_name')
    $toolInput = Get-Prop $HookInput 'tool_input'
    $suggestions = Get-Prop $HookInput 'permission_suggestions'
    $summary = Get-NotifierRequestSummary -ToolName $tool -ToolInput $toolInput -Suggestions $suggestions
    $now = [DateTime]::UtcNow
    $req = [pscustomobject][ordered]@{
        id          = [guid]::NewGuid().ToString()
        type        = 'permission'
        session_id  = [string](Get-Prop $HookInput 'session_id')
        pid         = $PID
        created     = $now.ToString('o')
        expires     = $now.AddSeconds($WaitSeconds).ToString('o')
        tool_name   = $tool
        tool_input  = $toolInput
        suggestions = $suggestions
        kind        = $summary.kind
        title       = $summary.title
        detail      = $summary.detail
        options     = @($summary.options)
        canAlways   = $summary.canAlways
        cwd         = [string](Get-Prop $HookInput 'cwd')   # папка проекта — для «На 30 мин»
        device      = $Device
    }
    Write-JsonAtomic (Join-Path (Get-RequestsDir $DataRoot) "perm-$($req.id).json") $req
    return $req
}

function ConvertTo-NotifierDecisionOutput {
    <#
    .SYNOPSIS
    Решение → JSON для Claude Code (hookSpecificOutput PermissionRequest).
    allow / always (+ updatedPermissions из permission_suggestions) / deny; для вопроса — allow с updatedInput.answers.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request, [Parameter(Mandatory = $true)]$Decision)
    $behavior = [string](Get-Prop $Decision 'behavior')
    $d = [ordered]@{}
    if ($behavior -eq 'deny') {
        $d.behavior = 'deny'
        $d.message = 'Пользователь отклонил действие в Claude Notifier.'
    }
    else {
        $d.behavior = 'allow'
        if ($behavior -eq 'always' -and $null -ne $Request.suggestions) { $d.updatedPermissions = @($Request.suggestions) }
        $answer = [string](Get-Prop $Decision 'answer')
        if ($Request.kind -eq 'question' -and $answer -ne '') {
            $newInput = [ordered]@{}
            foreach ($p in $Request.tool_input.PSObject.Properties) { $newInput[$p.Name] = $p.Value }
            $question = [string](@($Request.tool_input.questions)[0].question)
            $newInput.answers = [ordered]@{ $question = $answer }
            $d.updatedInput = $newInput
        }
        elseif ($Request.kind -eq 'plan' -or $Request.kind -eq 'question') {
            # ExitPlanMode и AskUserQuestion требуют updatedInput — передаём вход без изменений.
            $d.updatedInput = $Request.tool_input
        }
    }
    return (ConvertTo-Json -InputObject @{ hookSpecificOutput = [ordered]@{ hookEventName = 'PermissionRequest'; decision = $d } } -Depth 12 -Compress)
}

function Wait-NotifierDecision {
    <#
    .SYNOPSIS
    Ждёт решения по запросу до истечения срока. Возвращает объект решения или $null. Файлы запроса удаляет.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Request, [string]$DataRoot, [int]$PollMs = 250)
    $dir = Get-RequestsDir $DataRoot
    $reqPath = Join-Path $dir "perm-$($Request.id).json"
    $decPath = Join-Path $dir "perm-$($Request.id).decision.json"
    $deadline = [DateTimeOffset]::Parse($Request.expires).UtcDateTime
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if (Test-Path -LiteralPath $decPath) { return (Read-JsonFile $decPath) }
            if (-not (Test-Path -LiteralPath $reqPath)) { return $null }   # трей снял запрос
            Start-Sleep -Milliseconds $PollMs
        }
        return $null
    }
    finally {
        Remove-Item -LiteralPath $reqPath, $decPath -Force -ErrorAction SilentlyContinue
    }
}

function New-NotifierReplyWait {
    <# .SYNOPSIS Отмечает, что сеанс ждёт быстрого ответа (хук Stop с asyncRewake). #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$SessionId,
        [Parameter(Mandatory = $true)][int]$Minutes,
        [string]$DataRoot,
        [string]$Device = '',        # ожидание хука с другого устройства (Mac)
        [int]$TtlSeconds = 0         # > 0 — срок в секундах (Mac продлевает его каждым опросом), вместо Minutes
    )
    $now = [DateTime]::UtcNow
    $exp = if ($TtlSeconds -gt 0) { $now.AddSeconds($TtlSeconds) } else { $now.AddMinutes($Minutes) }
    $wait = [pscustomobject][ordered]@{ type = 'reply'; session_id = $SessionId; pid = $PID; created = $now.ToString('o'); expires = $exp.ToString('o'); device = $Device }
    Write-JsonAtomic (Join-Path (Get-RequestsDir $DataRoot) "reply-$(ConvertTo-SafeName $SessionId).json") $wait
    return $wait
}

function ConvertTo-SafeName([string]$Text) { return ($Text -replace '[^A-Za-z0-9_-]', '_') }

function Wait-NotifierReply {
    <#
    .SYNOPSIS
    Ждёт быстрого ответа для сеанса. Возвращает текст или $null (истекло время, ожидание снято, его занял
    более новый хук). Файлы своего ожидания удаляет.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Wait, [string]$DataRoot, [int]$PollMs = 400)
    $dir = Get-RequestsDir $DataRoot
    $name = ConvertTo-SafeName $Wait.session_id
    $waitPath = Join-Path $dir "reply-$name.json"
    $textPath = Join-Path $dir "reply-$name.txt"
    $deadline = [DateTimeOffset]::Parse($Wait.expires).UtcDateTime
    $mine = $true
    try {
        while ([DateTime]::UtcNow -lt $deadline) {
            if (-not (Test-Path -LiteralPath $waitPath)) { $mine = $false; return $null }
            $cur = Read-JsonFile $waitPath
            if ($cur -and [int](Get-Prop $cur 'pid') -ne $PID) { $mine = $false; return $null }
            if (Test-Path -LiteralPath $textPath) {
                $text = [IO.File]::ReadAllText($textPath, [Text.Encoding]::UTF8)
                Remove-Item -LiteralPath $textPath -Force -ErrorAction SilentlyContinue
                return $text
            }
            Start-Sleep -Milliseconds $PollMs
        }
        return $null
    }
    finally {
        if ($mine) { Remove-Item -LiteralPath $waitPath -Force -ErrorAction SilentlyContinue }
    }
}

# --- Сторона трея и веб-API ---

function Get-NotifierPendingRequests {
    <#
    .SYNOPSIS
    Действующие запросы: @{ Permissions = [...]; Replies = @{ session_id = wait } ; Gone = [session_id…] }.
    Запросы, чей хук уже завершился или чей срок истёк, удаляются; их сеансы — в Gone (для смены статуса).
    #>
    [CmdletBinding()]
    param([string]$DataRoot)
    $dir = Get-RequestsDir $DataRoot
    $now = [DateTime]::UtcNow
    $perms = @(); $replies = @{}; $gone = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue)) {
        if ($f.Name -like '*.decision.json' -or $f.Name -like '*.tmp-*') { continue }
        $r = Read-JsonFile $f.FullName
        if ($null -eq $r) { continue }
        $expired = $false
        try { $expired = [DateTimeOffset]::Parse([string]$r.expires).UtcDateTime -lt $now } catch { $expired = $true }
        if ($expired -or -not (Test-ProcessAlive ([int](Get-Prop $r 'pid')))) {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
            if ($r.type -eq 'permission') {
                Remove-Item -LiteralPath ($f.FullName -replace '\.json$', '.decision.json') -Force -ErrorAction SilentlyContinue
                $gone += [string]$r.session_id
            }
            continue
        }
        if ($r.type -eq 'permission') {
            if (-not (Test-Path -LiteralPath ($f.FullName -replace '\.json$', '.decision.json'))) { $perms += $r }
        }
        elseif ($r.type -eq 'reply') { $replies[[string]$r.session_id] = $r }
    }
    return @{ Permissions = $perms; Replies = $replies; Gone = $gone }
}

function Write-NotifierDecision {
    <#
    .SYNOPSIS
    Решение по запросу разрешения: allow | always | deny, для вопроса — Answer (вариант ответа).
    Возвращает session_id запроса или $null, если запроса уже нет.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RequestId,
        [Parameter(Mandatory = $true)][ValidateSet('allow', 'always', 'deny')][string]$Behavior,
        [string]$Answer = '',
        [string]$DataRoot
    )
    if ($RequestId -notmatch '^[0-9a-fA-F-]{36}$') { return $null }
    $dir = Get-RequestsDir $DataRoot
    $reqPath = Join-Path $dir "perm-$RequestId.json"
    if (-not (Test-Path -LiteralPath $reqPath)) { return $null }
    if (Test-Path -LiteralPath (Join-Path $dir "perm-$RequestId.decision.json")) { return $null }   # уже решено
    $req = Read-JsonFile $reqPath
    Write-JsonAtomic (Join-Path $dir "perm-$RequestId.decision.json") ([ordered]@{ behavior = $Behavior; answer = $Answer; at = [DateTime]::UtcNow.ToString('o') })
    return [string]$req.session_id
}

function Write-NotifierReply {
    <# .SYNOPSIS Быстрый ответ сеансу. $true — сеанс ждал ответа и получит его. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SessionId, [Parameter(Mandatory = $true)][string]$Text, [string]$DataRoot)
    $text = $Text.Trim()
    if ($text -eq '') { return $false }
    if ($text.Length -gt 4000) { $text = $text.Substring(0, 4000) }
    $dir = Get-RequestsDir $DataRoot
    $name = ConvertTo-SafeName $SessionId
    if (-not (Test-Path -LiteralPath (Join-Path $dir "reply-$name.json"))) { return $false }
    Write-NotifierTextAtomic -Path (Join-Path $dir "reply-$name.txt") -Text $text   # целиком: хук не прочтёт половину ответа
    return $true
}

# --- Запросы с другого устройства (Mac) ---
# Хук на Mac создаёт запрос или ожидание через сервер ПК (pid в нём — трея, он жив) и опрашивает ПК.
# Каждый опрос продлевает срок на TtlSeconds: перестал опрашивать (вы ответили прямо в Claude на Mac, сеть
# пропала) — через TtlSeconds запрос истекает, трей его убирает и переводит сеанс в «Работает».

function Set-RequestExpiry([string]$Path, $Object, [int]$Seconds) {
    $Object.expires = [DateTime]::UtcNow.AddSeconds($Seconds).ToString('o')
    Write-JsonAtomic $Path $Object
}

function Get-NotifierRemoteDecision {
    <#
    .SYNOPSIS
    Опрос хука Mac: решение по его запросу. @{ Status = pending | decided | gone; Output = JSON для Claude Code }.
    Только своё устройство (Device); pending — срок продлевается; decided — файлы запроса удаляются.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RequestId, [Parameter(Mandatory = $true)][string]$Device, [string]$DataRoot, [int]$TtlSeconds = 20)
    if ($RequestId -notmatch '^[0-9a-fA-F-]{36}$') { return @{ Status = 'gone'; Output = '' } }
    $dir = Get-RequestsDir $DataRoot
    $reqPath = Join-Path $dir "perm-$RequestId.json"
    $decPath = Join-Path $dir "perm-$RequestId.decision.json"
    $req = if (Test-Path -LiteralPath $reqPath) { Read-JsonFile $reqPath } else { $null }
    if ($null -eq $req -or [string](Get-Prop $req 'device') -ne $Device) { return @{ Status = 'gone'; Output = '' } }
    if (Test-Path -LiteralPath $decPath) {
        $dec = Read-JsonFile $decPath
        Remove-Item -LiteralPath $reqPath, $decPath -Force -ErrorAction SilentlyContinue
        if ($null -eq $dec) { return @{ Status = 'gone'; Output = '' } }
        return @{ Status = 'decided'; Output = (ConvertTo-NotifierDecisionOutput -Request $req -Decision $dec) }
    }
    Set-RequestExpiry $reqPath $req $TtlSeconds
    return @{ Status = 'pending'; Output = '' }
}

function Remove-NotifierRequest {
    <# .SYNOPSIS Хук Mac закончил ждать (решили в Claude, истёк срок): убрать его запрос. Только своё устройство. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$RequestId, [Parameter(Mandatory = $true)][string]$Device, [string]$DataRoot)
    if ($RequestId -notmatch '^[0-9a-fA-F-]{36}$') { return $false }
    $dir = Get-RequestsDir $DataRoot
    $reqPath = Join-Path $dir "perm-$RequestId.json"
    $req = if (Test-Path -LiteralPath $reqPath) { Read-JsonFile $reqPath } else { $null }
    if ($null -eq $req -or [string](Get-Prop $req 'device') -ne $Device) { return $false }
    Remove-Item -LiteralPath $reqPath, (Join-Path $dir "perm-$RequestId.decision.json") -Force -ErrorAction SilentlyContinue
    return $true
}

function Get-NotifierRemoteReply {
    <#
    .SYNOPSIS
    Опрос хука Mac: быстрый ответ его сеансу. @{ Status = pending | replied | gone; Text }. Только своё устройство;
    pending — срок ожидания продлевается; replied — ожидание и текст удаляются.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SessionId, [Parameter(Mandatory = $true)][string]$Device, [string]$DataRoot, [int]$TtlSeconds = 30)
    $dir = Get-RequestsDir $DataRoot
    $name = ConvertTo-SafeName $SessionId
    $waitPath = Join-Path $dir "reply-$name.json"
    $textPath = Join-Path $dir "reply-$name.txt"
    $wait = if (Test-Path -LiteralPath $waitPath) { Read-JsonFile $waitPath } else { $null }
    if ($null -eq $wait -or [string](Get-Prop $wait 'device') -ne $Device) { return @{ Status = 'gone'; Text = '' } }
    if (Test-Path -LiteralPath $textPath) {
        $text = [IO.File]::ReadAllText($textPath, [Text.Encoding]::UTF8)
        Remove-Item -LiteralPath $textPath, $waitPath -Force -ErrorAction SilentlyContinue
        return @{ Status = 'replied'; Text = $text }
    }
    Set-RequestExpiry $waitPath $wait $TtlSeconds
    return @{ Status = 'pending'; Text = '' }
}

function Remove-NotifierReplyWait {
    <# .SYNOPSIS Снимает ожидание быстрого ответа (вы написали прямо в Claude — ждущий хук завершится сам). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SessionId, [string]$DataRoot)
    $dir = Get-RequestsDir $DataRoot
    Remove-Item -LiteralPath (Join-Path $dir "reply-$(ConvertTo-SafeName $SessionId).json") -Force -ErrorAction SilentlyContinue
}

# --- Разрешение по шаблону: «Разрешать такие 30 минут» ---
# DataRoot\autoallow.json — [{ cwd; project; tool; prefix; until (ISO UTC); title }]. Хук разрешения (hook-bridge)
# проверяет правила до показа запроса: подходит — разрешает сам. Правило привязано к папке проекта (полный путь).
#   • Bash / PowerShell — шаблон — начало команды (первые два слова, «npm test»). Команда с цепочкой, фоном,
#     перенаправлением или подстановкой (; & | ` < > $( ${ перевод строки) под шаблон не попадает никогда;
#     для оболочек и интерпретаторов (bash -c, python -c, node -e, env, sudo…) правило не делается вовсе.
#   • Edit / Write / MultiEdit / NotebookEdit — любые правки, но только файлов внутри папки проекта.
#   • WebFetch — тот же домен.
#   • Остальные инструменты (MCP и прочее) — правила нет: кнопка «На 30 мин» не показывается.
$script:AutoAllowShellTools = @('Bash', 'PowerShell')
$script:AutoAllowEditTools = @('Edit', 'Write', 'MultiEdit', 'NotebookEdit')
# Оболочки, интерпретаторы и обёртки: «bash -c …» по шаблону открыл бы любой код.
$script:AutoAllowNoPrefix = @('bash', 'sh', 'zsh', 'fish', 'dash', 'ksh', 'env', 'sudo', 'su', 'doas', 'xargs', 'eval', 'exec', 'source', '.',
    'python', 'python3', 'py', 'node', 'deno', 'bun', 'npx', 'bunx', 'pnpx', 'ruby', 'perl', 'php', 'lua', 'pwsh', 'powershell', 'powershell.exe',
    'pwsh.exe', 'cmd', 'cmd.exe', 'wsl', 'start', 'invoke-expression', 'iex', 'invoke-command', 'start-process', 'nohup', 'time', 'watch', 'timeout', 'nice')

function Get-NotifierCommandText([string]$ToolName, $ToolInput) {
    if ($ToolInput -and $ToolInput.PSObject.Properties['command']) { return ([string]$ToolInput.command).Trim() }
    return ''
}

function ConvertTo-NotifierCwdKey([string]$Cwd) {
    <# .SYNOPSIS Папка проекта для сравнения правил: полный путь без хвостового разделителя, «\» вместо «/». #>
    if ([string]::IsNullOrWhiteSpace($Cwd)) { return '' }
    return ($Cwd.Trim().Replace('/', '\')).TrimEnd('\')
}

function Test-NotifierPathInside([string]$Path, [string]$Cwd) {
    <# .SYNOPSIS Файл внутри папки проекта (после нормализации «..» и «.»), без выхода наружу. #>
    $root = ConvertTo-NotifierCwdKey $Cwd
    if ($root -eq '' -or [string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $p = $Path.Replace('/', '\')
        if (-not [IO.Path]::IsPathRooted($p)) { $p = Join-Path $root $p }
        $full = [IO.Path]::GetFullPath($p)
        $rootFull = [IO.Path]::GetFullPath($root + '\').TrimEnd('\')
        return $full.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)
    }
    catch { return $false }
}

function Get-NotifierAutoAllowPrefix {
    <#
    .SYNOPSIS
    Шаблон для правила из запроса: Bash / PowerShell — первые два слова команды; WebFetch — домен; правка
    файлов — '' (любые правки внутри папки проекта). $null — для такого запроса правило не делается.
    #>
    param([string]$ToolName, $ToolInput)
    if ($script:AutoAllowShellTools -contains $ToolName) {
        $cmd = Get-NotifierCommandText $ToolName $ToolInput
        if ($cmd -eq '' -or (Test-NotifierShellChain $cmd)) { return $null }
        $words = @($cmd -split '\s+' | Where-Object { $_ -ne '' })
        $first = ([IO.Path]::GetFileName($words[0])).ToLowerInvariant()
        if ($script:AutoAllowNoPrefix -contains $first) { return $null }
        if ($words.Count -gt 1 -and $words[1] -match '^-(c|e|-eval|-exec|command)$') { return $null }   # git -c, … -e / --eval
        return (@($words | Select-Object -First 2) -join ' ')
    }
    if ($ToolName -eq 'WebFetch') {
        $u = $null
        if ($ToolInput -and $ToolInput.PSObject.Properties['url'] -and [Uri]::TryCreate([string]$ToolInput.url, [UriKind]::Absolute, [ref]$u) -and $u.Host) { return $u.Host.ToLowerInvariant() }
        return $null
    }
    if ($script:AutoAllowEditTools -contains $ToolName) { return '' }
    return $null
}

function Test-NotifierShellChain([string]$Command) {
    <# .SYNOPSIS В команде есть цепочка, фон, перенаправление или подстановка — такую по шаблону не разрешаем. #>
    return [bool]($Command -match '[;&|`<>\r\n]|\$\(|\$\{|\$''|\p{Cc}')
}

function Get-NotifierAutoAllowRules {
    <# .SYNOPSIS Действующие правила (истёкшие и без папки проекта отброшены). #>
    [CmdletBinding()]
    param([string]$DataRoot, [datetime]$Now = [DateTime]::UtcNow)
    $path = Join-Path $DataRoot 'autoallow.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    # PowerShell 5.1 отдаёт JSON-массив одним объектом — разворачиваем конвейером.
    try { $list = @(ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop | ForEach-Object { $_ }) } catch { return @() }
    $out = @()
    foreach ($r in $list) {
        if ($null -eq $r -or -not $r.PSObject.Properties['cwd'] -or [string]$r.cwd -eq '') { continue }   # правила до привязки к папке — не действуют
        $until = [DateTimeOffset]::MinValue
        if (-not [DateTimeOffset]::TryParse([string]$r.until, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$until)) { continue }
        if ($until.UtcDateTime -le $Now) { continue }
        $out += $r
    }
    return $out
}

function Save-NotifierAutoAllowRules {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Rules, [string]$DataRoot)
    $json = if ($Rules.Count -eq 0) { '[]' } else { ConvertTo-Json -InputObject @($Rules) -Depth 4 -Compress }
    if (-not $json.StartsWith('[')) { $json = "[$json]" }
    Write-NotifierTextAtomic -Path (Join-Path $DataRoot 'autoallow.json') -Text $json
}

function Add-NotifierAutoAllowRule {
    <#
    .SYNOPSIS
    Новое правило «разрешать такие» на Minutes минут для папки проекта Cwd (то же правило — продлевается).
    Возвращает правило или $null (для такого запроса правило не делается).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Cwd, [Parameter(Mandatory = $true)][string]$ToolName, $ToolInput, [int]$Minutes = 30,
        [string]$DataRoot, [datetime]$Now = [DateTime]::UtcNow)
    $key = ConvertTo-NotifierCwdKey $Cwd
    $prefix = Get-NotifierAutoAllowPrefix -ToolName $ToolName -ToolInput $ToolInput
    if ($null -eq $prefix -or $key -eq '') { return $null }
    $project = @($key -split '\\')[-1]
    $title = if ($prefix) { "$ToolName $([char]0x00B7) $prefix" } elseif ($script:AutoAllowEditTools -contains $ToolName) { "$ToolName $([char]0x00B7) файлы проекта" } else { "$ToolName $([char]0x00B7) любые" }
    $rule = [pscustomobject][ordered]@{ cwd = $key; project = $project; tool = $ToolName; prefix = $prefix; until = $Now.AddMinutes($Minutes).ToString('o'); title = $title }
    $rules = @(Get-NotifierAutoAllowRules -DataRoot $DataRoot -Now $Now | Where-Object { -not ([string]$_.cwd -eq $key -and $_.tool -eq $ToolName -and [string]$_.prefix -eq $prefix) })
    $rules += $rule
    Save-NotifierAutoAllowRules -Rules $rules -DataRoot $DataRoot
    return $rule
}

function Remove-NotifierAutoAllowRule {
    <# .SYNOPSIS Убрать правило по номеру (как в Get-NotifierAutoAllowRules). #>
    [CmdletBinding()]
    param([int]$Index, [string]$DataRoot)
    $rules = @(Get-NotifierAutoAllowRules -DataRoot $DataRoot)
    if ($Index -lt 0 -or $Index -ge $rules.Count) { return }
    $keep = @(); for ($i = 0; $i -lt $rules.Count; $i++) { if ($i -ne $Index) { $keep += $rules[$i] } }
    Save-NotifierAutoAllowRules -Rules $keep -DataRoot $DataRoot
}

function Test-NotifierAutoAllow {
    <#
    .SYNOPSIS
    Подходит ли запрос под действующее правило: та же папка проекта и инструмент; Bash / PowerShell — команда
    начинается с шаблона (целым словом) и без цепочек; правка — файл внутри папки проекта; WebFetch — тот же
    домен. Возвращает правило или $null.
    #>
    [CmdletBinding()]
    param([string]$Cwd, [string]$ToolName, $ToolInput, [string]$DataRoot, [datetime]$Now = [DateTime]::UtcNow)
    $key = ConvertTo-NotifierCwdKey $Cwd
    if ($key -eq '' -or $ToolName -eq '') { return $null }
    foreach ($r in @(Get-NotifierAutoAllowRules -DataRoot $DataRoot -Now $Now)) {
        if (-not [string]::Equals([string]$r.cwd, $key, [StringComparison]::OrdinalIgnoreCase) -or [string]$r.tool -ne $ToolName) { continue }
        $prefix = [string]$r.prefix
        if ($script:AutoAllowShellTools -contains $ToolName) {
            $cmd = Get-NotifierCommandText $ToolName $ToolInput
            if ($cmd -eq '' -or (Test-NotifierShellChain $cmd) -or $prefix -eq '') { continue }
            if ($cmd -ceq $prefix -or $cmd.StartsWith($prefix + ' ', [StringComparison]::Ordinal)) { return $r }
            continue
        }
        if ($ToolName -eq 'WebFetch') {
            $u = $null
            if ($ToolInput -and $ToolInput.PSObject.Properties['url'] -and [Uri]::TryCreate([string]$ToolInput.url, [UriKind]::Absolute, [ref]$u) -and $u.Host.ToLowerInvariant() -eq $prefix) { return $r }
            continue
        }
        if ($script:AutoAllowEditTools -contains $ToolName) {
            $fp = ''
            if ($ToolInput -and $ToolInput.PSObject.Properties['file_path']) { $fp = [string]$ToolInput.file_path }
            elseif ($ToolInput -and $ToolInput.PSObject.Properties['notebook_path']) { $fp = [string]$ToolInput.notebook_path }
            if (Test-NotifierPathInside -Path $fp -Cwd $key) { return $r }
            continue
        }
    }
    return $null
}

function Write-NotifierTextAtomic {
    <#
    .SYNOPSIS
    Записать текст в файл целиком или никак: во временный файл рядом, затем замена ([IO.File]::Replace —
    атомарно на NTFS). Оборванная запись (сбой, выключение) не оставляет пустой или половинный файл.
    #>
    param([Parameter(Mandatory = $true)][string]$Path, [AllowEmptyString()][string]$Text, [switch]$Bom)
    $tmp = "$Path.tmp-$PID-$([Environment]::TickCount)"
    [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding ([bool]$Bom)))
    if (Test-Path -LiteralPath $Path) {
        try { [IO.File]::Replace($tmp, $Path, $null); return } catch { }
        # Replace недоступен (файл занят) — удалить и переименовать.
        try { [IO.File]::Delete($Path) } catch { }
    }
    [IO.File]::Move($tmp, $Path)
}

Export-ModuleMember -Function Write-NotifierTextAtomic, Test-NotifierPathInside, ConvertTo-NotifierCwdKey, Get-NotifierAutoAllowPrefix, Test-NotifierShellChain, Get-NotifierAutoAllowRules, Add-NotifierAutoAllowRule, Remove-NotifierAutoAllowRule, Test-NotifierAutoAllow, Get-NotifierRequestSummary, New-NotifierPermissionRequest, ConvertTo-NotifierDecisionOutput, Wait-NotifierDecision, New-NotifierReplyWait, Wait-NotifierReply, Get-NotifierPendingRequests, Write-NotifierDecision, Write-NotifierReply, Remove-NotifierReplyWait, Get-NotifierRemoteDecision, Remove-NotifierRequest, Get-NotifierRemoteReply
