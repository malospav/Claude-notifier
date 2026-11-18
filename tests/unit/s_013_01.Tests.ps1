BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)

    function Write-Lines([string]$Path, [string[]]$Lines, [switch]$Append) {
        $text = ($Lines -join "`n") + "`n"
        if ($Append) { [IO.File]::AppendAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
        else { [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
    }
    function Iso([datetime]$T) { return $T.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
    function New-Card([string]$Id, [string]$Project, [string]$State, [switch]$Pinned) {
        $c = New-Object ClaudeNotifier.Ui.CardItem
        $c.Id = $Id; $c.Section = 'Этот ПК'; $c.Title = $Project; $c.State = $State; $c.Pinned = [bool]$Pinned
        $c.Tag = [pscustomobject]@{ session_id = $Id; project = $Project; state = $State }
        return $c
    }
}

Describe 's_013_01 · завис или упал, «Готово» после долгих задач, группы проектов, стоимость' {
    It 'стоимость ответа по ценам API: вход, ответ, кэш 5 мин и 1 ч, быстрый режим, длинный запрос Haiku 5.5' {
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -InTokens 1000000 | Should -Be 4
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -Output 1000000 | Should -Be 20
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -CacheRead 1000000 | Should -Be 0.2
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -Cache5m 1000000 | Should -Be 5
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -Cache1h 1000000 | Should -Be 8
        Get-NotifierMessageCost -Model 'claude-opus-5-5' -Output 1000000 -Fast | Should -Be 40
        Get-NotifierMessageCost -Model 'claude-fable-5-2' -InTokens 1000000 | Should -Be 8
        Get-NotifierMessageCost -Model 'claude-sonnet-4-5-20250929' -InTokens 1000000 | Should -Be 3
        Get-NotifierMessageCost -Model 'claude-haiku-5-5' -InTokens 50000 | Should -Be 0.005
        Get-NotifierMessageCost -Model 'claude-haiku-5-5' -InTokens 200000 | Should -Be 0.1
        Get-NotifierMessageCost -Model 'gpt-x' -InTokens 1000000 | Should -Be 0
        Format-NotifierCost 0 | Should -Be '$0'
        Format-NotifierCost 0.001 | Should -Be '<$0,01'
        Format-NotifierCost 12.4 | Should -Be '$12,40'
        Format-NotifierCost 1240.2 | Should -Be '$1 240'
    }

    It 'статистика: стоимость по дням и проектам, одно сообщение в нескольких строках — один раз' {
        $pd = Join-Path $TestDrive 'projects'
        $dir = Join-Path $pd 'C--dev-shop'
        New-Item -ItemType Directory $dir -Force | Out-Null
        $t = [DateTime]::UtcNow.AddMinutes(-10)
        $u1 = '"usage":{"input_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_read_input_tokens":0,"output_tokens":10,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}'
        $u2 = '"usage":{"input_tokens":1000000,"cache_creation_input_tokens":1000000,"cache_read_input_tokens":0,"output_tokens":1000000,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1000000}}'
        Write-Lines (Join-Path $dir 'a.jsonl') @(
            "{`"type`":`"user`",`"timestamp`":`"$(Iso $t)`",`"cwd`":`"C:\\dev\\shop`",`"message`":{`"content`":`"x`"}}",
            "{`"type`":`"assistant`",`"timestamp`":`"$(Iso $t.AddSeconds(5))`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"msg_1`",$u1}}",
            "{`"type`":`"assistant`",`"timestamp`":`"$(Iso $t.AddSeconds(6))`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"msg_1`",$u2}}")
        $sd = Join-Path $TestDrive 'act'
        [void](Update-NotifierActivity -ProjectsDir $pd -StateDir $sd)
        $s = Get-NotifierActivitySummary -StateDir $sd
        # Вход $4 + запись в кэш на час $8 + ответ $20 — сообщение засчитано один раз.
        [Math]::Round((@($s.Days)[-1]).cost, 6) | Should -Be 32
        [Math]::Round(@($s.Week)[0].cost, 6) | Should -Be 32
        @($s.Week)[0].project | Should -Be 'shop'
        [Math]::Round($s.Total.cost, 6) | Should -Be 32
        $cards = ConvertTo-NotifierStatsCards -Summary $s
        $cards[0].Meta | Should -Match '\$32,00'
    }

    It 'журнал: ошибка API запоминается (время и текст), понятная фраза для перегрузки и лимита' {
        $tr = Join-Path $TestDrive 'err.jsonl'
        Write-Lines $tr @(
            '{"type":"assistant","timestamp":"2026-11-17T07:01:00.000Z","message":{"model":"claude-opus-5-5","id":"msg_1","content":[],"usage":{"input_tokens":1,"output_tokens":1}}}',
            '{"type":"assistant","isApiErrorMessage":true,"timestamp":"2026-11-17T07:02:00.000Z","message":{"model":"<synthetic>","id":"x","content":[{"type":"text","text":"API Error: 529 {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}"}]}}')
        $s = Get-NotifierTranscriptStats -Path $tr -StateDir (Join-Path $TestDrive 'st')
        $s.apiError | Should -Be '2026-11-17T07:02:00.000Z'
        $s.apiErrorText | Should -Match '^API Error: 529'
        $s.lastActivity | Should -Be '2026-11-17T07:01:00.000Z'   # ошибка — не работа Claude
        Format-NotifierApiError $s.apiErrorText | Should -Match 'перегружены'
        Format-NotifierApiError 'API Error: Rate limit reached' | Should -Match 'лимит запросов'
        Format-NotifierApiError 'что-то новое' | Should -Be 'что-то новое'
    }

    It 'время изменения журнала учитывает журналы субагентов' {
        $tr = Join-Path $TestDrive 'sess.jsonl'
        Write-Lines $tr @('{}')
        (Get-Item $tr).LastWriteTimeUtc = [datetime]'2026-11-17T07:00:00Z'
        Get-NotifierJournalWriteTime -Path $tr | Should -Be ([datetime]'2026-11-17T07:00:00Z').ToUniversalTime()
        $sub = Join-Path $TestDrive 'sess\subagents'
        New-Item -ItemType Directory $sub -Force | Out-Null
        Write-Lines (Join-Path $sub 'agent-1.jsonl') @('{}')
        (Get-Item (Join-Path $sub 'agent-1.jsonl')).LastWriteTimeUtc = [datetime]'2026-11-17T07:20:00Z'
        Get-NotifierJournalWriteTime -Path $tr | Should -Be ([datetime]'2026-11-17T07:20:00Z').ToUniversalTime()
    }

    It 'тишина в журнале: считается от последней записи, но не раньше начала работы; только для «Работает»' {
        $u = { param($t) ([datetime]$t).ToUniversalTime() }
        $now = & $u '2026-11-17T08:00:00Z'
        $s = [pscustomobject]@{ session_id = 's'; state = 'working'; since = '2026-11-17T07:40:00.000Z' }
        Get-NotifierStallStart -Session $s -LastWrite (& $u '2026-11-17T07:45:00Z') -Minutes 10 -Now $now | Should -Be (& $u '2026-11-17T07:45:00Z')
        Get-NotifierStallStart -Session $s -LastWrite (& $u '2026-11-17T07:55:00Z') -Minutes 10 -Now $now | Should -Be $null
        Get-NotifierStallStart -Session $s -LastWrite (& $u '2026-11-17T06:00:00Z') -Minutes 10 -Now $now | Should -Be (& $u '2026-11-17T07:40:00Z')
        $s.state = 'waiting'
        Get-NotifierStallStart -Session $s -LastWrite (& $u '2026-11-17T06:00:00Z') -Minutes 10 -Now $now | Should -Be $null
    }

    It 'трей: сеанс молчит 10 мин — одно уведомление, отметка на карточке и на телефоне; журнал ожил — отметка снята' {
        $script:TrayDataRoot = Join-Path $TestDrive 'stall'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:StallNotified = @{}
        $now = [DateTime]::UtcNow
        $tr = Join-Path $TestDrive 'stall.jsonl'
        Write-Lines $tr @("{`"type`":`"assistant`",`"timestamp`":`"$(Iso $now.AddMinutes(-15))`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"msg_1`",`"content`":[],`"usage`":{`"input_tokens`":1,`"output_tokens`":1}}}")
        (Get-Item $tr).LastWriteTimeUtc = $now.AddMinutes(-15)
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'S'; project = 'shop'; origin = 'cli'; device = ''; state = 'working'; since = (Iso $now.AddMinutes(-20)); updated = ''; preview = ''; transcript = $tr; window = $null })
        Update-NotifierLiveContext -Force -Now $now
        $ev = @($script:TrayQueue.ToArray() | Where-Object { $_.title -like 'Сеанс, похоже, остановился*' })
        $ev.Count | Should -Be 1
        $ev[0].title | Should -Be 'Сеанс, похоже, остановился · shop'
        $ev[0].notifyOnly | Should -Be $true
        $ev[0].preview | Should -Match 'не меняется 15 мин'
        $s = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]
        $s.stalledSince | Should -Not -BeNullOrEmpty
        $card = ConvertTo-NotifierSessionCard -Session $s -Now $now
        $card.State | Should -Be 'error'
        $card.StateText | Should -Be 'Похоже, остановился'
        $card.Right | Should -Be '15 мин'
        $ctx = @{ Network = (Get-NotifierNetwork -DataRoot $script:TrayDataRoot); DataRoot = $script:TrayDataRoot; PcName = 'PC' }
        $p = Get-NotifierSessionsPayload -Ctx $ctx
        $p.sessions[0].state_text | Should -Be 'Похоже, остановился'
        # Повторно о той же тишине — не сообщает.
        Update-NotifierLiveContext -Force -Now $now.AddMinutes(1)
        @($script:TrayQueue.ToArray() | Where-Object { $_.title -like 'Сеанс, похоже*' }).Count | Should -Be 1
        # Журнал ожил — отметка снята.
        Write-Lines $tr @('{"type":"system","subtype":"informational"}') -Append
        Update-NotifierLiveContext -Force -Now ([DateTime]::UtcNow)
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).PSObject.Properties['stalledSince'] | Should -Be $null
    }

    It 'трей: «остановился» не меняет статус сеанса; выключено в настройках — не показывается' {
        $script:TrayDataRoot = Join-Path $TestDrive 'stall-batch'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'S'; project = 'shop'; origin = 'cli'; device = ''; state = 'working'; since = ''; updated = ''; window = $null })
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $session = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue((New-NotifierStallEvent -Session $session -From ([DateTime]::UtcNow.AddMinutes(-12))))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should -Be 'working'
        # Тумблер «Ошибка» выключен — «остановился» всё равно приходит (свой тумблер); выключен свой — нет.
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"events":{"error":{"enabled":false,"sound":""}}}')
        $q.Enqueue((New-NotifierStallEvent -Session $session -From ([DateTime]::UtcNow.AddMinutes(-12))))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 2 -Exactly -Scope It
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"stalled":{"enabled":false}}')
        $q.Enqueue((New-NotifierStallEvent -Session $session -From ([DateTime]::UtcNow.AddMinutes(-12))))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 2 -Exactly -Scope It
    }

    It 'трей: ошибка API в журнале работающего сеанса — уведомление «Ошибка» (после паузы для хука), один раз' {
        $script:TrayDataRoot = Join-Path $TestDrive 'apierr'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:ApiErrorNotified = @{}
        $now = [DateTime]::UtcNow
        $tr = Join-Path $TestDrive 'apierr.jsonl'
        Write-Lines $tr @("{`"type`":`"assistant`",`"isApiErrorMessage`":true,`"timestamp`":`"$(Iso $now.AddSeconds(-5))`",`"message`":{`"model`":`"<synthetic>`",`"content`":[{`"type`":`"text`",`"text`":`"API Error: Rate limit reached`"}]}}")
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'E'; project = 'shop'; origin = 'desktop'; device = ''; state = 'working'; since = (Iso $now.AddMinutes(-2)); updated = ''; transcript = $tr; window = $null })
        Update-NotifierLiveContext -Force -Now $now
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'error' }).Count | Should -Be 0   # ждём хук StopFailure
        Update-NotifierLiveContext -Force -Now $now.AddSeconds(30)
        $ev = @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'error' })
        $ev.Count | Should -Be 1
        $ev[0].title | Should -Be 'Ошибка · shop'
        $ev[0].preview | Should -Match 'лимит запросов'
        Update-NotifierLiveContext -Force -Now $now.AddSeconds(60)
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'error' }).Count | Should -Be 1
        Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput | Out-Null
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should -Be 'error'
        # Ошибка до начала работы (старая) — не сообщается.
        $s = [pscustomobject]@{ session_id = 'F'; state = 'working'; since = (Iso $now) }
        Test-NotifierApiErrorDue -Session $s -ErrorTs (Iso $now.AddMinutes(-1)) -Now $now.AddMinutes(1) | Should -Be $false
    }

    It 'после «Готово» работают фоновые агенты (пишут свои журналы) — сеанс «Работает», быстрый ответ убран' {
        $script:TrayDataRoot = Join-Path $TestDrive 'bg'
        New-Item -ItemType Directory (Join-Path $script:TrayDataRoot 'requests') -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $now = [DateTime]::UtcNow
        $tr = Join-Path $TestDrive 'bg.jsonl'
        Write-Lines $tr @("{`"type`":`"assistant`",`"timestamp`":`"$(Iso $now.AddMinutes(-10))`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"msg_1`",`"content`":[],`"usage`":{`"input_tokens`":1,`"output_tokens`":1}}}")
        (Get-Item $tr).LastWriteTimeUtc = $now.AddMinutes(-10)
        $sub = Join-Path $TestDrive 'bg\subagents'
        New-Item -ItemType Directory $sub -Force | Out-Null
        $agent = Join-Path $sub 'agent-1.jsonl'
        Write-Lines $agent @('{}')
        (Get-Item $agent).LastWriteTimeUtc = $now.AddMinutes(-10).AddSeconds(2)   # обычный субагент закончил до «Готово»
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'B'; project = 'shop'; origin = 'desktop'; device = ''; state = 'waiting'; since = (Iso $now.AddMinutes(-10)); updated = ''; preview = ''; transcript = $tr; window = $null
                stats = [pscustomobject]@{ context = 1; window = 200000; percent = 1; output = 1; tools = 0; prompts = 0 } })
        [void](New-NotifierReplyWait -SessionId 'B' -Minutes 30 -DataRoot $script:TrayDataRoot)
        Update-NotifierLiveContext -Force -Now $now
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'working' }).Count | Should -Be 0
        (Get-Item $agent).LastWriteTimeUtc = $now.AddMinutes(-1)   # фоновый агент пишет после «Готово»
        Update-NotifierLiveContext -Force -Now $now
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'working' }).Count | Should -Be 1
        Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput | Out-Null
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should -Be 'working'
        (Get-NotifierPendingRequests -DataRoot $script:TrayDataRoot).Replies.ContainsKey('B') | Should -Be $false
    }

    It 'сеанс помнит, с какого момента занят задачей: «Нужно разрешение» — та же задача, после ожидания — новая' {
        $ev = { param($type, $ts) [pscustomobject]@{ type = $type; session_id = 'b'; ts = $ts } }
        $l = Update-NotifierSessionList -Sessions @() -Event (& $ev 'working' '2026-11-17T07:00:00Z')
        $l[0].busySince | Should -Be '2026-11-17T07:00:00Z'
        $l = Update-NotifierSessionList -Sessions $l -Event (& $ev 'permission' '2026-11-17T07:03:00Z')
        $l = Update-NotifierSessionList -Sessions $l -Event (& $ev 'working' '2026-11-17T07:04:00Z')
        $l[0].busySince | Should -Be '2026-11-17T07:00:00Z'
        $l = Update-NotifierSessionList -Sessions $l -Event (& $ev 'done' '2026-11-17T07:06:00Z')
        $l[0].busySince | Should -Be '2026-11-17T07:00:00Z'
        $l = Update-NotifierSessionList -Sessions $l -Event (& $ev 'working' '2026-11-17T07:10:00Z')
        $l[0].busySince | Should -Be '2026-11-17T07:10:00Z'
    }

    It '«Готово» после короткой задачи, пока вы за ПК, — без уведомления; долгая задача или вас нет — с уведомлением' {
        $cfg = Get-NotifierDefaultConfig
        $s = [pscustomobject]@{ session_id = 'q'; state = 'working'; since = '2026-11-17T07:00:00Z'; busySince = '2026-11-17T07:00:00Z' }
        $done = { param($ts) [pscustomobject]@{ type = 'done'; session_id = 'q'; ts = $ts } }
        Test-NotifierQuickTask -Session $s -Event (& $done '2026-11-17T07:01:00Z') -Config $cfg -IdleSeconds 5 | Should -Be $true
        Test-NotifierQuickTask -Session $s -Event (& $done '2026-11-17T07:05:00Z') -Config $cfg -IdleSeconds 5 | Should -Be $false
        Test-NotifierQuickTask -Session $s -Event (& $done '2026-11-17T07:01:00Z') -Config $cfg -IdleSeconds 300 | Should -Be $false
        Test-NotifierQuickTask -Session $null -Event (& $done '2026-11-17T07:01:00Z') -Config $cfg | Should -Be $false
        $cfg.longTasks.enabled = $false
        Test-NotifierQuickTask -Session $s -Event (& $done '2026-11-17T07:01:00Z') -Config $cfg -IdleSeconds 5 | Should -Be $false
    }

    It 'трей: короткое «Готово» — в истории, но без уведомления и звука' {
        $script:TrayDataRoot = Join-Path $TestDrive 'quick'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $now = [DateTime]::UtcNow
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'Q'; project = 'shop'; origin = 'cli'; device = ''; state = 'working'; since = (Iso $now.AddSeconds(-30)); busySince = (Iso $now.AddSeconds(-30)); updated = ''; window = $null })
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        Mock Get-NotifierIdleSeconds { 1 }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'd1'; type = 'done'; title = 'Готово'; preview = 'ok'; session_id = 'Q'; ts = (Iso $now) })
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 0 -Exactly -Scope It
        Assert-MockCalled Invoke-NotifierSound -Times 0 -Exactly -Scope It
        @(Get-NotifierHistory -DataRoot $script:TrayDataRoot | Where-Object { $_.id -eq 'd1' }).Count | Should -Be 1
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should -Be 'waiting'
    }

    It 'группы: от 4 сеансов сеансы проекта сворачиваются; свёрнутая группа показывает запросы; закреплённые — отдельно' {
        $cards = @(
            (New-Card 'p' 'shop' 'working' -Pinned),
            (New-Card 'a1' 'shop' 'permission'),
            (New-Card 'a2' 'shop' 'working'),
            (New-Card 'a3' 'shop' 'waiting'),
            (New-Card 'b1' 'api' 'working'))
        $l = Get-NotifierGroupedCards -Cards $cards -MinSessions 4 -Expanded @{}
        (@($l) | ForEach-Object { $_.Id }) -join ',' | Should -Be 'p,group:Этот ПК|shop,a1,b1'
        $g = $l[1]
        $g.IsGroup | Should -Be $true
        $g.GroupOpen | Should -Be $false
        $g.Title | Should -Be 'shop'
        $g.State | Should -Be 'permission'
        $g.StateText | Should -Be '3 сеанса'
        $g.Meta | Should -Be 'Нужно разрешение 1 · Ждёт ответа 1 · Работает 1'
        $l[2].Child | Should -Be $true
        $l = Get-NotifierGroupedCards -Cards $cards -MinSessions 4 -Expanded @{ 'Этот ПК|shop' = $true }
        (@($l) | ForEach-Object { $_.Id }) -join ',' | Should -Be 'p,group:Этот ПК|shop,a1,a2,a3,b1'
        $l[1].GroupOpen | Should -Be $true
        (@(Get-NotifierGroupedCards -Cards $cards -MinSessions 6) | ForEach-Object { $_.Id }) -join ',' | Should -Be 'p,a1,a2,a3,b1'
        (@(Get-NotifierGroupedCards -Cards $cards -MinSessions 0) | ForEach-Object { $_.Id }) -join ',' | Should -Be 'p,a1,a2,a3,b1'
        Format-NotifierSessionCount 1 | Should -Be '1 сеанс'
        Format-NotifierSessionCount 5 | Should -Be '5 сеансов'
        Format-NotifierSessionCount 12 | Should -Be '12 сеансов'
        Format-NotifierSessionCount 22 | Should -Be '22 сеанса'
    }

    It 'группы в окне: щелчок по строке-группе раскрывает и сворачивает её; отрисовка со стрелкой и отступом' {
        $script:TrayDataRoot = Join-Path $TestDrive 'groups'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:ExpandedGroups = @{}
        $mk = { param($id, $p) [pscustomobject]@{ session_id = $id; project = $p; origin = 'cli'; device = ''; state = 'working'; since = ''; updated = $id; preview = ''; window = $null } }
        $sessions = @((& $mk 'x1' 'shop'), (& $mk 'x2' 'shop'), (& $mk 'x3' 'shop'), (& $mk 'y1' 'api'))
        $list = New-Object ClaudeNotifier.Ui.CardList
        try {
            $list.Size = New-Object System.Drawing.Size(500, 400)
            [void](Update-NotifierSessionsView -Cards $list -Sessions $sessions)
            $list.Count | Should -Be 2
            $g = @(for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] }) | Where-Object { $_.IsGroup }
            $g.Title | Should -Be 'shop'
            Switch-NotifierSessionGroup -Item $g
            [void](Update-NotifierSessionsView -Cards $list -Sessions $sessions)
            $list.Count | Should -Be 5
            @(@(for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] }) | Where-Object { $_.Child }).Count | Should -Be 3
            $bmp = New-Object System.Drawing.Bitmap 500, 400
            $list.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 500, 400)))
            $bmp.Dispose()
            Switch-NotifierSessionGroup -Item $g
            [void](Update-NotifierSessionsView -Cards $list -Sessions $sessions)
            $list.Count | Should -Be 2
            # Группировка выключена в настройках — обычный список.
            [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"groups":{"enabled":false}}')
            [void](Update-NotifierSessionsView -Cards $list -Sessions $sessions)
            $list.Count | Should -Be 4
        }
        finally { $list.Dispose() }
    }

    It 'настройки: значения по умолчанию, неверные — по умолчанию; тумблеры в группе «Внимание»' {
        $script:TrayDataRoot = Join-Path $TestDrive 'cfg13'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.stalled.enabled | Should -Be $true; $c.stalled.minutes | Should -Be 10
        $c.longTasks.enabled | Should -Be $true; $c.longTasks.minutes | Should -Be 2
        $c.groups.enabled | Should -Be $true; $c.groups.minSessions | Should -Be 4
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"stalled":{"minutes":1},"longTasks":{"minutes":5},"groups":{"minSessions":1}}')
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.stalled.minutes | Should -Be 10
        $c.longTasks.minutes | Should -Be 5
        $c.groups.minSessions | Should -Be 4
        Remove-Item (Join-Path $script:TrayDataRoot 'config.json')
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $ui = $script:SessionsForm.Tag.Settings
            foreach ($k in @('stalled', 'longTasks', 'groups')) { $ui.Switches[$k].Checked | Should -Be $true }
            $ui.Switches['groups'].Toggle()
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).groups.enabled | Should -Be $false
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).groups.minSessions | Should -Be 4
            Set-NotifierOptionValue -Name longTasks -Value $false
            Update-NotifierSettingsView
            $ui.Switches['longTasks'].Checked | Should -Be $false
            $ui.HotkeyRow.Tag.Title.Text | Should -Be 'Горячая клавиша'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}
