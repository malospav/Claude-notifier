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
    try { return (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)) -ErrorAction Stop) } catch { return $null }
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
    param([Parameter(Mandatory = $true)]$HookInput, [Parameter(Mandatory = $true)][int]$WaitSeconds, [string]$DataRoot)
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
    param([Parameter(Mandatory = $true)][string]$SessionId, [Parameter(Mandatory = $true)][int]$Minutes, [string]$DataRoot)
    $now = [DateTime]::UtcNow
    $wait = [pscustomobject][ordered]@{ type = 'reply'; session_id = $SessionId; pid = $PID; created = $now.ToString('o'); expires = $now.AddMinutes($Minutes).ToString('o') }
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
    [IO.File]::WriteAllText((Join-Path $dir "reply-$name.txt"), $text, $script:Utf8)
    return $true
}

function Remove-NotifierReplyWait {
    <# .SYNOPSIS Снимает ожидание быстрого ответа (вы написали прямо в Claude — ждущий хук завершится сам). #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$SessionId, [string]$DataRoot)
    $dir = Get-RequestsDir $DataRoot
    Remove-Item -LiteralPath (Join-Path $dir "reply-$(ConvertTo-SafeName $SessionId).json") -Force -ErrorAction SilentlyContinue
}

Export-ModuleMember -Function Get-NotifierRequestSummary, New-NotifierPermissionRequest, ConvertTo-NotifierDecisionOutput, Wait-NotifierDecision, New-NotifierReplyWait, Wait-NotifierReply, Get-NotifierPendingRequests, Write-NotifierDecision, Write-NotifierReply, Remove-NotifierReplyWait
