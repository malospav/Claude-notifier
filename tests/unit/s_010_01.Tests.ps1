$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Requests.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Transcript.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Shortcut.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Server.psm1') -Force
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray
. (Join-Path $repoRoot 'src\hook-bridge.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

function New-PermInput([string]$Tool = 'Bash', $ToolInput = @{ command = 'git push' }, $Suggestions = $null, [string]$Sid = 's1') {
    $o = [ordered]@{ session_id = $Sid; cwd = 'C:\dev\proj'; hook_event_name = 'PermissionRequest'; tool_name = $Tool; tool_input = $ToolInput }
    if ($Suggestions) { $o.permission_suggestions = $Suggestions }
    return (ConvertTo-Json -InputObject $o -Depth 8 -Compress)
}

Describe 's_010_01 · журнал сеанса' {
    It 'итоги: начало, контекст, токены ответов (без повторов одного сообщения), запросы, действия; чтение с места остановки' {
        $root = Join-Path $TestDrive 'tr'
        New-Item -ItemType Directory $root -Force | Out-Null
        $file = Join-Path $root 't.jsonl'
        $lines = @(
            '{"type":"user","timestamp":"2026-11-17T07:00:00.000Z","message":{"role":"user","content":"привет"}}',
            '{"type":"assistant","timestamp":"2026-11-17T07:00:05.000Z","message":{"id":"msg_1","content":[{"type":"text"}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":5,"output_tokens":40}}}',
            '{"type":"assistant","timestamp":"2026-11-17T07:00:06.000Z","message":{"id":"msg_1","content":[{"type":"tool_use","id":"t1"}],"usage":{"input_tokens":10,"cache_read_input_tokens":1000,"cache_creation_input_tokens":5,"output_tokens":50}}}',
            '{"type":"user","timestamp":"2026-11-17T07:00:07.000Z","message":{"content":[{"type":"tool_result"}]}}',
            '{"type":"user","isMeta":true,"message":{"content":"meta"}}'
        )
        [IO.File]::WriteAllText($file, (($lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
        $s = Get-NotifierTranscriptStats -Path $file -StateDir (Join-Path $root 'state')
        $s.started | Should Be '2026-11-17T07:00:00.000Z'
        $s.output | Should Be 50
        $s.context | Should Be 1015
        $s.tools | Should Be 1
        $s.prompts | Should Be 1
        [IO.File]::AppendAllText($file, '{"type":"assistant","message":{"id":"msg_2","content":[{"type":"tool_use"},{"type":"tool_use"}],"usage":{"input_tokens":1,"cache_read_input_tokens":2000,"cache_creation_input_tokens":0,"output_tokens":30}}}' + "`n" + '{"type":"user","message":{"content":"ещё"}}' + "`n" + '{"type":"assis')
        $s2 = Get-NotifierTranscriptStats -Path $file -StateDir (Join-Path $root 'state')
        $s2.output | Should Be 80
        $s2.context | Should Be 2001
        $s2.tools | Should Be 3
        $s2.prompts | Should Be 2
        Get-NotifierTranscriptStats -Path (Join-Path $root 'нет.jsonl') -StateDir (Join-Path $root 'state') | Should Be $null
        Get-NotifierTranscriptStats -Path '' -StateDir (Join-Path $root 'state') | Should Be $null
    }

    It 'формат токенов и подробностей сеанса' {
        Format-NotifierTokens 950 | Should Be '950'
        Format-NotifierTokens 12400 | Should Be '12 тыс.'
        Format-NotifierTokens 1250000 | Should Be '1,3 млн'
        $now = [DateTime]::UtcNow
        $d = Format-NotifierSessionDetails -Now $now -Session ([pscustomobject]@{ started = $now.AddMinutes(-75).ToString('o'); prompt = 'Сделай тесты'; stats = [pscustomobject]@{ context = 721350; output = 885560; tools = 861; prompts = 51 } })
        $d | Should Match '^Начат	в \d\d:\d\d · идёт 1 ч 15 мин'
        $d | Should Match 'Контекст	721 тыс\. токенов · ответы 886 тыс\.'
        $d | Should Match 'Работа	запросов 51 · действий 861'
        $d | Should Match 'Ваш запрос	Сделай тесты$'
        Format-NotifierSessionDetails -Session ([pscustomobject]@{ session_id = 'x' }) | Should Be ''
    }
}

Describe 's_010_01 · запросы разрешения' {
    It 'сводка: Bash — команда; AskUserQuestion — варианты; несколько вопросов — ответ в Claude; план' {
        $b = Get-NotifierRequestSummary -ToolName Bash -ToolInput ([pscustomobject]@{ command = 'rm -rf x' }) -Suggestions @([pscustomobject]@{ type = 'addRules' })
        $b.kind | Should Be 'tool'; $b.title | Should Be 'Разрешить Bash?'; $b.detail | Should Be 'rm -rf x'; $b.canAlways | Should Be $true
        (Get-NotifierRequestSummary -ToolName Edit -ToolInput ([pscustomobject]@{ file_path = 'C:\a.txt' }) -Suggestions $null).canAlways | Should Be $false
        $q = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Какой вариант?'; multiSelect = $false; options = @([pscustomobject]@{ label = 'A' }, [pscustomobject]@{ label = 'B' }) }) }
        $s = Get-NotifierRequestSummary -ToolName AskUserQuestion -ToolInput $q -Suggestions $null
        $s.kind | Should Be 'question'; ($s.options -join ',') | Should Be 'A,B'; $s.title | Should Be 'Какой вариант?'
        $q2 = [pscustomobject]@{ questions = @($q.questions[0], $q.questions[0]) }
        (Get-NotifierRequestSummary -ToolName AskUserQuestion -ToolInput $q2 -Suggestions $null).kind | Should Be 'question-complex'
        (Get-NotifierRequestSummary -ToolName ExitPlanMode -ToolInput ([pscustomobject]@{ plan = 'План' }) -Suggestions $null).kind | Should Be 'plan'
    }

    It 'запрос → решение → ответ Claude: allow, always (+правила), deny, ответ на вопрос' {
        $root = Join-Path $TestDrive 'perm'
        $sugg = @([pscustomobject]@{ type = 'addRules'; behavior = 'allow'; destination = 'localSettings'; rules = @([pscustomobject]@{ toolName = 'Bash'; ruleContent = 'git push' }) })
        $req = New-NotifierPermissionRequest -HookInput (ConvertFrom-Json (New-PermInput -Suggestions $sugg)) -WaitSeconds 60 -DataRoot $root
        (Get-NotifierPendingRequests -DataRoot $root).Permissions.Count | Should Be 1
        Write-NotifierDecision -RequestId $req.id -Behavior always -DataRoot $root | Should Be 's1'
        (Get-NotifierPendingRequests -DataRoot $root).Permissions.Count | Should Be 0   # решение записано — больше не ждёт
        $dec = Wait-NotifierDecision -Request $req -DataRoot $root
        $dec.behavior | Should Be 'always'
        $out = ConvertTo-NotifierDecisionOutput -Request $req -Decision $dec | ConvertFrom-Json
        $out.hookSpecificOutput.hookEventName | Should Be 'PermissionRequest'
        $out.hookSpecificOutput.decision.behavior | Should Be 'allow'
        $out.hookSpecificOutput.decision.updatedPermissions[0].rules[0].ruleContent | Should Be 'git push'
        Test-Path (Join-Path $root "requests\perm-$($req.id).json") | Should Be $false
        $deny = ConvertTo-NotifierDecisionOutput -Request $req -Decision ([pscustomobject]@{ behavior = 'deny' }) | ConvertFrom-Json
        $deny.hookSpecificOutput.decision.behavior | Should Be 'deny'
        $deny.hookSpecificOutput.decision.message | Should Match 'отклонил'
        $qIn = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Какой?'; multiSelect = $false; options = @([pscustomobject]@{ label = 'A' }) }) }
        $qreq = New-NotifierPermissionRequest -HookInput (ConvertFrom-Json (New-PermInput -Tool AskUserQuestion -ToolInput $qIn)) -WaitSeconds 60 -DataRoot $root
        $qout = ConvertTo-NotifierDecisionOutput -Request $qreq -Decision ([pscustomobject]@{ behavior = 'allow'; answer = 'A' }) | ConvertFrom-Json
        $qout.hookSpecificOutput.decision.updatedInput.answers.'Какой?' | Should Be 'A'
        $qout.hookSpecificOutput.decision.updatedInput.questions[0].question | Should Be 'Какой?'
        Write-NotifierDecision -RequestId 'not-a-guid' -Behavior allow -DataRoot $root | Should Be $null
        Write-NotifierDecision -RequestId '00000000-0000-0000-0000-000000000000' -Behavior allow -DataRoot $root | Should Be $null
    }

    It 'хук завершился (ответ дали в Claude) → запрос убирается, сеанс в Gone; истёкший срок — тоже' {
        $root = Join-Path $TestDrive 'gone'
        $dir = Join-Path $root 'requests'
        New-Item -ItemType Directory $dir -Force | Out-Null
        $exp = [DateTime]::UtcNow.AddMinutes(5).ToString('o')
        [IO.File]::WriteAllText("$dir\perm-a.json", (ConvertTo-Json -Compress @{ id = 'a'; type = 'permission'; session_id = 'dead'; pid = 999999; expires = $exp }))
        [IO.File]::WriteAllText("$dir\perm-b.json", (ConvertTo-Json -Compress @{ id = 'b'; type = 'permission'; session_id = 'old'; pid = $PID; expires = [DateTime]::UtcNow.AddMinutes(-1).ToString('o') }))
        [IO.File]::WriteAllText("$dir\perm-c.json", (ConvertTo-Json -Compress @{ id = 'c'; type = 'permission'; session_id = 'live'; pid = $PID; expires = $exp }))
        $p = Get-NotifierPendingRequests -DataRoot $root
        (@($p.Gone) | Sort-Object) -join ',' | Should Be 'dead,old'
        @($p.Permissions).Count | Should Be 1
        $p.Permissions[0].session_id | Should Be 'live'
        Test-Path "$dir\perm-a.json" | Should Be $false
    }

    It 'хук: доставка не удалась → без ответа (решает Claude); в CLI по умолчанию не ждёт; выключено → не ждёт' {
        $root = Join-Path $TestDrive 'hook'
        New-Item -ItemType Directory $root -Force | Out-Null
        $old = $env:CLAUDE_CODE_ENTRYPOINT
        try {
            $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
            Mock Send-NotifierEventToTray { 'undelivered' }
            Invoke-NotifierPermissionHook -InputJson (New-PermInput) -DataRoot $root | Should Be ''
            @(Get-ChildItem (Join-Path $root 'requests') -Filter 'perm-*.json').Count | Should Be 0
            $env:CLAUDE_CODE_ENTRYPOINT = 'cli'
            Mock Send-NotifierEventToTray { throw 'не должен вызываться' }
            Invoke-NotifierPermissionHook -InputJson (New-PermInput) -DataRoot $root | Should Be ''
            $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
            Set-NotifierConfigValue -Name approvals -Value ([pscustomobject]@{ enabled = $false }) -DataRoot $root
            Invoke-NotifierPermissionHook -InputJson (New-PermInput) -DataRoot $root | Should Be ''
        }
        finally { $env:CLAUDE_CODE_ENTRYPOINT = $old }
    }

    It 'хук: решение из приложения возвращается Claude JSON-ом' {
        $root = Join-Path $TestDrive 'hook2'
        New-Item -ItemType Directory $root -Force | Out-Null
        $old = $env:CLAUDE_CODE_ENTRYPOINT
        try {
            $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
            # «Трей» отвечает сразу, как только получил событие запроса.
            Mock Send-NotifierEventToTray { [void](Write-NotifierDecision -RequestId $Event.request_id -Behavior allow -DataRoot $DataRoot); 'sent' }
            Mock Get-SessionWindow { @{ hwnd = 0; pid = 0 } }
            $out = Invoke-NotifierPermissionHook -InputJson (New-PermInput) -DataRoot $root
            ($out | ConvertFrom-Json).hookSpecificOutput.decision.behavior | Should Be 'allow'
            Assert-MockCalled Send-NotifierEventToTray -Times 1 -Scope It -ParameterFilter { $Event.type -eq 'request' -and $Event.preview -eq 'Разрешить Bash?' -and $Event.title -like 'Нужно разрешение*' }
        }
        finally { $env:CLAUDE_CODE_ENTRYPOINT = $old }
    }
}

Describe 's_010_01 · быстрые ответы' {
    It 'ожидание → ответ из приложения → текст для Claude; новый хук вытесняет старое ожидание' {
        $root = Join-Path $TestDrive 'reply'
        $w = New-NotifierReplyWait -SessionId 's/1' -Minutes 5 -DataRoot $root
        (Get-NotifierPendingRequests -DataRoot $root).Replies.ContainsKey('s/1') | Should Be $true
        Write-NotifierReply -SessionId 's/1' -Text '  Продолжай  ' -DataRoot $root | Should Be $true
        Wait-NotifierReply -Wait $w -DataRoot $root | Should Be 'Продолжай'
        (Get-NotifierPendingRequests -DataRoot $root).Replies.Count | Should Be 0
        Write-NotifierReply -SessionId 's/1' -Text 'x' -DataRoot $root | Should Be $false   # никто не ждёт
        $w2 = New-NotifierReplyWait -SessionId 's2' -Minutes 5 -DataRoot $root
        Remove-NotifierReplyWait -SessionId 's2' -DataRoot $root
        Wait-NotifierReply -Wait $w2 -DataRoot $root | Should Be $null
        Write-NotifierReply -SessionId 's3' -Text '   ' -DataRoot $root | Should Be $false
    }

    It 'хук Stop (asyncRewake): быстрые ответы выключены → ничего; включены → текст с пояснением' {
        $root = Join-Path $TestDrive 'replyhook'
        New-Item -ItemType Directory $root -Force | Out-Null
        Set-NotifierConfigValue -Name quickReplies -Value ([pscustomobject]@{ enabled = $false }) -DataRoot $root
        Invoke-NotifierReplyHook -InputJson '{"session_id":"q1"}' -DataRoot $root | Should Be $null
        Set-NotifierConfigValue -Name quickReplies -Value ([pscustomobject]@{ enabled = $true; minutes = 1 }) -DataRoot $root
        Mock Wait-NotifierReply { 'Да' }
        Invoke-NotifierReplyHook -InputJson '{"session_id":"q1"}' -DataRoot $root | Should Match 'Claude Notifier[\s\S]*Да$'
    }
}

Describe 's_010_01 · трей: запросы в карточках' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('t-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory "$script:TrayDataRoot\requests" -Force | Out-Null
        $script:SessionsForm = $null
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @(
            [pscustomobject]@{ session_id = 'p'; project = 'proj'; origin = 'desktop'; device = ''; state = 'permission'; since = $now; updated = $now; preview = ''; window = $null },
            [pscustomobject]@{ session_id = 'w'; project = 'web'; origin = 'cli'; device = ''; state = 'waiting'; since = $now; updated = $now; preview = 'готово'; window = $null }
        )
    }

    It 'карточка с запросом раскрыта и с кнопками; «Разрешить» пишет решение и переводит сеанс в «Работает»' {
        $req = New-NotifierPermissionRequest -HookInput (ConvertFrom-Json (New-PermInput -Sid 'p')) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        $card.ForceExpand | Should Be $true
        $card.RequestTitle | Should Be 'Разрешить Bash?'
        ($card.Actions -join ';') | Should Be 'allow|Разрешить|primary;deny|Запретить|destructive'
        Invoke-NotifierCardAction -Item $card -ActionId allow | Should Be 'Разрешено'
        (Get-Content (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") -Raw | ConvertFrom-Json).behavior | Should Be 'allow'
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | Where-Object { $_.session_id -eq 'p' }).state | Should Be 'working'
        Invoke-NotifierCardAction -Item $card -ActionId deny | Should Be 'Запрос уже решён в Claude'
    }

    It 'вопрос: варианты кнопками, ответ уходит в решение' {
        $qIn = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'Какой?'; multiSelect = $false; options = @([pscustomobject]@{ label = 'Синий' }, [pscustomobject]@{ label = 'Красный' }) }) }
        $req = New-NotifierPermissionRequest -HookInput (ConvertFrom-Json (New-PermInput -Tool AskUserQuestion -ToolInput $qIn -Sid 'p')) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        ($card.Actions -join ';') | Should Be 'answer:0|Синий|primary;answer:1|Красный|secondary;answer-custom|Свой ответ…|secondary'
        Invoke-NotifierCardAction -Item $card -ActionId 'answer:1' | Should Be 'Ответ: Красный'
        (Get-Content (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") -Raw -Encoding UTF8 | ConvertFrom-Json).answer | Should Be 'Красный'
    }

    It 'быстрый ответ: кнопки у сеанса, который ждёт; ответ записывается, сеанс работает' {
        [void](New-NotifierReplyWait -SessionId 'w' -Minutes 5 -DataRoot $script:TrayDataRoot)
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | Where-Object { $_.session_id -eq 'w' })
        $card.RequestTitle | Should Be 'Быстрый ответ'
        ($card.Actions -join ';') | Should Be 'reply:0|Продолжай|secondary;reply:1|Да|secondary;reply:2|Нет|secondary;reply-custom|Ответить…|primary'
        Invoke-NotifierCardAction -Item $card -ActionId 'reply:0' | Should Be 'Отправлено: Продолжай'
        Get-Content (Join-Path $script:TrayDataRoot 'requests\reply-w.txt') -Raw -Encoding UTF8 | Should Be 'Продолжай'
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | Where-Object { $_.session_id -eq 'w' }).state | Should Be 'working'
    }

    It 'запрос исчез без решения (ответили в Claude) → сеанс «Работает»' {
        $dir = Join-Path $script:TrayDataRoot 'requests'
        [IO.File]::WriteAllText("$dir\perm-x.json", (ConvertTo-Json -Compress @{ id = 'x'; type = 'permission'; session_id = 'p'; pid = 999999; expires = [DateTime]::UtcNow.AddMinutes(5).ToString('o') }))
        Update-NotifierPending | Should Be $true
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | Where-Object { $_.session_id -eq 'p' }).state | Should Be 'working'
    }

    It 'дубль уведомления: запрос, затем «Нужно разрешение» от Claude по тому же сеансу в течение 30 с' {
        $now = [DateTime]::UtcNow
        Test-NotifierDuplicatePermissionToast -Now $now -Event ([pscustomobject]@{ type = 'request'; session_id = 'd' }) | Should Be $false
        Test-NotifierDuplicatePermissionToast -Now $now.AddSeconds(5) -Event ([pscustomobject]@{ type = 'permission'; session_id = 'd' }) | Should Be $true
        Test-NotifierDuplicatePermissionToast -Now $now.AddSeconds(45) -Event ([pscustomobject]@{ type = 'permission'; session_id = 'd' }) | Should Be $false
        Test-NotifierDuplicatePermissionToast -Now $now -Event ([pscustomobject]@{ type = 'permission'; session_id = 'other' }) | Should Be $false
    }

    It 'событие запроса: уведомление «Нужно разрешение», статус сеанса; новый запрос в Claude снимает ожидание ответа' {
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        [void](New-NotifierReplyWait -SessionId 'w' -Minutes 5 -DataRoot $script:TrayDataRoot)
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue([pscustomobject]@{ v = 1; type = 'request'; title = 'Нужно разрешение · proj'; preview = 'Разрешить Bash?'; session_id = 'p2'; ts = [DateTime]::UtcNow.ToString('o'); origin = 'desktop'; project = 'proj'; window = $null })
        $q.Enqueue([pscustomobject]@{ v = 1; type = 'permission'; title = 'Нужно разрешение · proj'; preview = 'Claude needs permission'; session_id = 'p2'; ts = [DateTime]::UtcNow.ToString('o'); origin = 'desktop'; project = 'proj'; window = $null })
        $q.Enqueue([pscustomobject]@{ v = 1; type = 'working'; title = 'w'; preview = ''; session_id = 'w'; ts = [DateTime]::UtcNow.ToString('o') })
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | Where-Object { $_.session_id -eq 'p2' }).state | Should Be 'permission'
        Test-Path (Join-Path $script:TrayDataRoot 'requests\reply-w.json') | Should Be $false
    }
}

Describe 's_010_01 · веб-API ответов' {
    It '/api/sessions показывает запрос и возможность ответа; /api/decision и /api/reply записывают ответ' {
        $root = Join-Path $TestDrive 'api'
        New-Item -ItemType Directory $root -Force | Out-Null
        $ctx = @{ Network = (Get-NotifierNetwork -DataRoot $root); Pairing = $null; InstallCodes = @{}; Events = (New-Object System.Collections.ArrayList); NetworkDirty = $false; Paired = $null; DataRoot = $root; Address = '192.168.1.5'; PcName = 'PC' }
        $tok = (Add-NotifierDevice -Network $ctx.Network -Name 'iPhone').Token
        $h = @{ cookie = "cn_token=$tok" }
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $root -Sessions @(
            [pscustomobject]@{ session_id = 'p'; project = 'proj'; origin = 'desktop'; device = ''; state = 'permission'; since = $now; updated = $now; preview = ''; window = $null },
            [pscustomobject]@{ session_id = 'w'; project = 'web'; origin = 'cli'; device = ''; state = 'waiting'; since = $now; updated = $now; preview = ''; window = $null })
        $req = New-NotifierPermissionRequest -HookInput (ConvertFrom-Json (New-PermInput -Sid 'p')) -WaitSeconds 60 -DataRoot $root
        [void](New-NotifierReplyWait -SessionId 'w' -Minutes 5 -DataRoot $root)
        $req1 = @{ Method = 'GET'; Path = '/api/sessions'; Body = ''; Headers = $h; Query = @{}; TooLarge = $false; Remote = 'x' }
        $data = (Invoke-NotifierHttpRequest -Request $req1 -Ctx $ctx).Body | ConvertFrom-Json
        $p = @($data.sessions | Where-Object { $_.id -eq 'p' })[0]
        $p.request.title | Should Be 'Разрешить Bash?'
        (@($data.sessions | Where-Object { $_.id -eq 'w' })[0]).can_reply | Should Be $true
        $dec = @{ Method = 'POST'; Path = '/api/decision'; Body = (ConvertTo-Json @{ id = $req.id; behavior = 'allow' }); Headers = $h; Query = @{}; TooLarge = $false; Remote = 'x' }
        (Invoke-NotifierHttpRequest -Request $dec -Ctx $ctx).Status | Should Be 200
        $ctx.Events[0].type | Should Be 'working'
        $ctx.Events[0].session_id | Should Be 'p'
        (Invoke-NotifierHttpRequest -Request $dec -Ctx $ctx).Status | Should Be 410   # уже решено — второе решение не принимается
        $rep = @{ Method = 'POST'; Path = '/api/reply'; Body = (ConvertTo-Json @{ session = 'w'; text = 'Да' }); Headers = $h; Query = @{}; TooLarge = $false; Remote = 'x' }
        (Invoke-NotifierHttpRequest -Request $rep -Ctx $ctx).Status | Should Be 200
        $bad = @{ Method = 'POST'; Path = '/api/decision'; Body = '{"id":"x","behavior":"maybe"}'; Headers = $h; Query = @{}; TooLarge = $false; Remote = 'x' }
        (Invoke-NotifierHttpRequest -Request $bad -Ctx $ctx).Status | Should Be 400
        $gone = @{ Method = 'POST'; Path = '/api/reply'; Body = '{"session":"nobody","text":"x"}'; Headers = $h; Query = @{}; TooLarge = $false; Remote = 'x' }
        (Invoke-NotifierHttpRequest -Request $gone -Ctx $ctx).Status | Should Be 410
        $noauth = @{ Method = 'POST'; Path = '/api/decision'; Body = '{}'; Headers = @{}; Query = @{}; TooLarge = $false; Remote = 'x' }
        (Invoke-NotifierHttpRequest -Request $noauth -Ctx $ctx).Status | Should Be 401
    }
}

Describe 's_010_01 · настройки, автозапуск, мини-окно' {
    It 'config.json: разделы approvals / quickReplies / showPrompt — значения по умолчанию и проверка' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory $root -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $root
        $c.approvals.enabled | Should Be $true; $c.approvals.waitSeconds | Should Be 600; $c.approvals.cliWaitSeconds | Should Be 0
        $c.quickReplies.minutes | Should Be 60; $c.showPrompt | Should Be $false
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"approvals":{"enabled":false,"waitSeconds":5},"quickReplies":{"minutes":30},"showPrompt":true}', [Text.Encoding]::UTF8)
        $c = Get-NotifierConfig -DataRoot $root
        $c.approvals.enabled | Should Be $false
        $c.approvals.waitSeconds | Should Be 600   # 5 вне диапазона → по умолчанию
        $c.quickReplies.minutes | Should Be 30
        $c.showPrompt | Should Be $true
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match "approvals.waitSeconds"
    }

    It 'настройки из окна сохраняются в config.json' {
        $script:TrayDataRoot = Join-Path $TestDrive 'set'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Set-NotifierEventOption -Type done -Enabled $false
        Set-NotifierEventOption -Type error -Sound 'C:\s.wav'
        Set-NotifierOptionValue -Name quickReplies -Value $false
        Set-NotifierOptionValue -Name showPrompt -Value $true
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.events.done.enabled | Should Be $false
        $c.events.error.sound | Should Be 'C:\s.wav'
        $c.events.permission.enabled | Should Be $true
        $c.quickReplies.enabled | Should Be $false
        $c.showPrompt | Should Be $true
        Format-NotifierSoundName '' | Should Be 'Системный звук'
        Format-NotifierSoundName 'C:\x\bell.wav' | Should Be 'bell'
    }

    It 'вкладка «Настройки» строится и отражает config.json' {
        $script:TrayDataRoot = Join-Path $TestDrive 'setui'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Set-NotifierEventOption -Type limit -Enabled $false
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $ui = $script:SessionsForm.Tag.Settings
            $ui.Switches['event.limit'].Checked | Should Be $false
            $ui.Switches['event.done'].Checked | Should Be $true
            $ui.Switches['approvals'].Checked | Should Be $true
            Set-NotifierEventOption -Type limit -Enabled $true
            Update-NotifierSettingsView
            $ui.Switches['event.limit'].Checked | Should Be $true
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 2
            $script:SessionsForm.Tag.Title.Text | Should Be 'Настройки'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }

    It 'автозапуск: ярлык в «Автозагрузке» без -Show; выключение удаляет' {
        $startup = Join-Path $TestDrive 'startup'
        Test-NotifierAutostart -StartupDir $startup | Should Be $false
        Set-NotifierAutostart -Enabled $true -AppRoot 'C:\app' -StartupDir $startup
        Test-NotifierAutostart -StartupDir $startup | Should Be $true
        (Read-NotifierShortcut -Path (Get-NotifierAutostartPath -StartupDir $startup)).Arguments | Should Match 'ClaudeNotifier\.Tray\.ps1"$'
        Set-NotifierAutostart -Enabled $false -AppRoot 'C:\app' -StartupDir $startup
        Test-NotifierAutostart -StartupDir $startup | Should Be $false
    }

    It 'мини-окно: у нижнего края рабочей области рядом с курсором, в пределах экрана' {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $r = Get-NotifierPopoverBounds -Size (New-Object System.Drawing.Size(380, 400)) -Cursor (New-Object System.Drawing.Point(($wa.Right - 20), ($wa.Bottom + 10)))
        $r.Right | Should Not BeGreaterThan $wa.Right
        $r.Bottom | Should Not BeGreaterThan $wa.Bottom
        $r.Width | Should Be 380
        $script:TrayDataRoot = Join-Path $TestDrive 'pop'
        $p = New-NotifierPopover
        try { $p.Tag.Cards.EmptyTitle | Should Be 'Сеансов нет' } finally { $p.Dispose() }
    }

    It 'список: строка с запросом раскрыта; кнопка действия вызывает событие act:<id>' {
        $cards = New-Object ClaudeNotifier.Ui.CardList
        $cards.Size = New-Object System.Drawing.Size(420, 400)
        $c = New-Object ClaudeNotifier.Ui.CardItem
        $c.Id = 'a'; $c.Title = 'proj'; $c.State = 'working'; $c.RequestTitle = 'Разрешить?'; $c.Actions = [string[]]@('allow|Разрешить|primary'); $c.ForceExpand = $true; $c.Details = "строка 1`nстрока 2"
        $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'; $list.Add($c)
        $cards.SetItems($list)
        $script:got = $null
        $cards.add_ItemAction({ param($s, $e) $script:got = $e.Action })
        $cards.InvokeAction(0, 'allow')
        $script:got | Should Be 'act:allow'
        $bmp = New-Object System.Drawing.Bitmap 420, 400
        $cards.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 420, 400)))
        $bmp.Dispose(); $cards.Dispose()
    }
}
