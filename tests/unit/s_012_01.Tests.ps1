$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray
. (Join-Path $repoRoot 'src\hook-bridge.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

function Write-Lines([string]$Path, [string[]]$Lines, [switch]$Append) {
    $text = ($Lines -join "`n") + "`n"
    if ($Append) { [IO.File]::AppendAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
    else { [IO.File]::WriteAllText($Path, $text, (New-Object Text.UTF8Encoding $false)) }
}

$script:T1 = @(
    '{"type":"user","timestamp":"2026-11-17T07:00:00.000Z","cwd":"C:\\dev\\shop","message":{"content":"x"}}',
    '{"type":"assistant","timestamp":"2026-11-17T07:01:00.000Z","message":{"model":"claude-sonnet-4-5","id":"msg_1","content":[{"type":"tool_use","id":"toolu_1","name":"Edit","input":{"file_path":"C:\\dev\\shop\\a.ps1","old_string":"x"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":100000,"cache_creation_input_tokens":40000,"output_tokens":50}}}',
    '{"type":"assistant","timestamp":"2026-11-17T07:02:00.000Z","message":{"model":"claude-sonnet-4-5","id":"msg_2","content":[{"type":"tool_use","id":"toolu_2","name":"Bash","input":{"command":"git status \"x\"\nsecond line","description":"d"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":170000,"cache_creation_input_tokens":0,"output_tokens":20}}}',
    '{"type":"assistant","isSidechain":true,"timestamp":"2026-11-17T07:02:30.000Z","message":{"model":"claude-haiku-4-5","id":"msg_s","content":[],"usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1}}}',
    '{"type":"assistant","timestamp":"2026-11-17T07:03:00.000Z","message":{"model":"claude-sonnet-4-5","id":"msg_3","content":[{"type":"tool_use","id":"toolu_3","name":"mcp__srv__do_it","input":{}},{"type":"tool_use","id":"toolu_4","name":"Write","input":{"file_path":"C:\\dev\\shop\\b.md","content":"y"}},{"type":"tool_use","id":"toolu_5","name":"Edit","input":{"file_path":"C:\\dev\\shop\\a.ps1"}}],"usage":{"input_tokens":10,"cache_read_input_tokens":170000,"cache_creation_input_tokens":0,"output_tokens":5}}}'
)

Describe 's_012_01 · контекст, подробности, напоминания, горячая клавиша, имя и закрепление' {
    It 'журнал: заполненность контекста, окно модели, файлы, инструменты, команды; субагент не меняет контекст' {
        $tr = Join-Path $TestDrive 'a.jsonl'
        Write-Lines $tr $script:T1
        $s = Get-NotifierTranscriptStats -Path $tr -StateDir (Join-Path $TestDrive 'st')
        $s.context | Should Be 170010
        $s.window | Should Be 200000
        $s.percent | Should Be 85
        $s.model | Should Be 'claude-sonnet-4-5'
        $s.files | Should Be 2
        ($s.recentFiles -join ',') | Should Be 'a.ps1,b.md'
        ($s.topTools -join ',') | Should Be 'Edit 2,Bash 1,do_it 1'
        ($s.commands -join '|') | Should Be 'git status "x"'
        # Сжатие: контекст сброшен, окно по размеру до сжатия — 1 млн.
        Write-Lines $tr @('{"type":"system","subtype":"compact_boundary","timestamp":"2026-11-17T07:04:00.000Z","compactMetadata":{"trigger":"auto","preTokens":250000}}') -Append
        $s = Get-NotifierTranscriptStats -Path $tr -StateDir (Join-Path $TestDrive 'st')
        $s.context | Should Be 0
        $s.window | Should Be 1000000
        $s.compactions | Should Be 1
        $s.tools | Should Be 5
    }

    It 'окно контекста: [1m], Claude 5 (кроме Haiku), больше 200 тыс. — 1 млн; иначе 200 тыс.' {
        Get-NotifierContextWindow -Model 'claude-sonnet-4-5' | Should Be 200000
        Get-NotifierContextWindow -Model 'claude-sonnet-4-5[1m]' | Should Be 1000000
        Get-NotifierContextWindow -Model 'claude-opus-5-5' | Should Be 1000000
        Get-NotifierContextWindow -Model 'claude-haiku-5-5' | Should Be 200000
        Get-NotifierContextWindow -Model 'claude-haiku-4-5' -MaxSeen 300000 | Should Be 1000000
    }

    It 'старое состояние журнала (без версии) — журнал перечитывается целиком' {
        $tr = Join-Path $TestDrive 'old.jsonl'
        Write-Lines $tr $script:T1
        $sd = Join-Path $TestDrive 'st-old'
        [void](Get-NotifierTranscriptStats -Path $tr -StateDir $sd)
        $stateFile = @(Get-ChildItem $sd -Filter *.json)[0].FullName
        [IO.File]::WriteAllText($stateFile, ('{"offset":' + (Get-Item $tr).Length + ',"context":1,"output":1,"tools":0,"prompts":0}'))
        (Get-NotifierTranscriptStats -Path $tr -StateDir $sd).files | Should Be 2
    }

    It 'подробности карточки: контекст в процентах, файлы, инструменты, последняя команда' {
        $session = [pscustomobject]@{ session_id = 's'; started = ''; prompt = ''; stats = [pscustomobject]@{ context = 170010; window = 200000; percent = 85; output = 75; tools = 4; prompts = 1; compactions = 2; files = 2; recentFiles = @('a.ps1', 'b.md'); topTools = @('Edit 2', 'Bash 1'); commands = @('npm test') } }
        $d = Format-NotifierSessionDetails -Session $session
        $d | Should Match 'Контекст	85 % — 170 тыс\. из 200 тыс\.'
        $d | Should Match 'сжатий 2'
        $d | Should Match 'Файлы	изменено 2: a\.ps1, b\.md'
        $d | Should Match 'Чаще всего	Edit 2, Bash 1'
        $d | Should Match 'Команда	npm test'
    }

    It 'хук передаёт путь журнала, сеанс его хранит' {
        $root = Join-Path $TestDrive 'br'
        New-Item -ItemType Directory $root -Force | Out-Null
        $ev = [pscustomobject]@{ type = 'working'; session_id = 'x'; ts = '2026-11-17T07:00:00Z' }
        Add-NotifierEventDetails -Event $ev -Kind prompt -InputJson '{"session_id":"x","transcript_path":"C:\\t\\x.jsonl"}' -Config (Get-NotifierConfig -DataRoot $root) -DataRoot $root
        $ev.transcript | Should Be 'C:\t\x.jsonl'
        $l = Update-NotifierSessionList -Sessions @() -Event $ev
        $l[0].transcript | Should Be 'C:\t\x.jsonl'
        $l = Update-NotifierSessionList -Sessions $l -Event ([pscustomobject]@{ type = 'done'; session_id = 'x'; ts = '2026-11-17T07:01:00Z' })
        $l[0].transcript | Should Be 'C:\t\x.jsonl'
    }

    It 'настройки: напоминания 3 мин, контекст 85 %, горячая клавиша; неверные значения — по умолчанию' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory $root -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $root
        $c.approvals.remindMinutes | Should Be 3
        $c.context.enabled | Should Be $true
        $c.context.warnPercent | Should Be 85
        $c.hotkey.enabled | Should Be $true
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"approvals":{"remindMinutes":0},"context":{"enabled":false,"warnPercent":20},"hotkey":{"enabled":false}}')
        $c = Get-NotifierConfig -DataRoot $root
        $c.approvals.remindMinutes | Should Be 0
        $c.context.enabled | Should Be $false
        $c.context.warnPercent | Should Be 85
        $c.hotkey.enabled | Should Be $false
    }

    It 'предупреждение о контексте: один раз за переход порога, снова — после сжатия; без уведомлений и выключено — без события' {
        $script:ContextWarned = @{}
        $cfg = Get-NotifierDefaultConfig
        $mk = { param($pct) [pscustomobject]@{ session_id = 'c1'; project = 'shop'; origin = 'cli'; window = $null; stats = [pscustomobject]@{ context = $pct * 2000; window = 200000; percent = $pct } } }
        @(Get-NotifierContextAlerts -Sessions @(& $mk 80) -Config $cfg).Count | Should Be 0
        $ev = @(Get-NotifierContextAlerts -Sessions @(& $mk 86) -Config $cfg)
        $ev.Count | Should Be 1
        $ev[0].type | Should Be 'limit'
        $ev[0].context | Should Be $true
        $ev[0].title | Should Be 'Контекст почти заполнен · shop'
        $ev[0].preview | Should Match 'Заполнено 86 %'
        @(Get-NotifierContextAlerts -Sessions @(& $mk 90) -Config $cfg).Count | Should Be 0
        @(Get-NotifierContextAlerts -Sessions @(& $mk 10) -Config $cfg).Count | Should Be 0
        @(Get-NotifierContextAlerts -Sessions @(& $mk 88) -Config $cfg).Count | Should Be 1
        @(Get-NotifierContextAlerts -Sessions @(& $mk 10) -Config $cfg).Count | Should Be 0
        @(Get-NotifierContextAlerts -Sessions @(& $mk 88) -Config $cfg -Prefs @{ c1 = @{ title = 'Мой'; pinned = $false; muted = $true } }).Count | Should Be 0
        [void](Get-NotifierContextAlerts -Sessions @(& $mk 10) -Config $cfg)
        $cfg.context.enabled = $false
        @(Get-NotifierContextAlerts -Sessions @(& $mk 88) -Config $cfg).Count | Should Be 0
    }

    It 'трей раз в 15 с обновляет контекст работающего сеанса и ставит предупреждение в очередь' {
        $script:TrayDataRoot = Join-Path $TestDrive 'live'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $script:ContextWarned = @{}
        $tr = Join-Path $TestDrive 'live.jsonl'
        Write-Lines $tr $script:T1
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'L'; project = 'shop'; origin = 'cli'; device = ''; state = 'working'; since = ''; updated = ''; transcript = $tr; window = $null })
        Update-NotifierLiveContext -Force
        $s = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]
        $s.stats.percent | Should Be 85
        $ev = $null
        $script:TrayQueue.TryDequeue([ref]$ev) | Should Be $true
        $ev.title | Should Match 'Контекст почти заполнен'
        # Без изменений журнала и до 15 с — ничего не делает.
        Update-NotifierLiveContext
        $script:TrayQueue.IsEmpty | Should Be $true
    }

    It 'сеанс «Ждёт ответа», который продолжил сам (новый ответ в журнале), снова «Работает», быстрые ответы убираются' {
        $script:TrayDataRoot = Join-Path $TestDrive 'resume'
        New-Item -ItemType Directory (Join-Path $script:TrayDataRoot 'requests') -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $tr = Join-Path $TestDrive 'resume.jsonl'
        Write-Lines $tr $script:T1   # последний ответ — 07:03
        $sess = { param($since) [pscustomobject]@{ session_id = 'R'; project = 'shop'; origin = 'desktop'; device = ''; state = 'waiting'; since = $since; updated = $since; transcript = $tr; window = $null } }
        # Ждёт по-настоящему: «Готово» в 07:03:30, журнал после этого не менялся по смыслу.
        (Get-Item $tr).LastWriteTimeUtc = [datetime]'2026-11-17T07:03:30Z'
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @(& $sess '2026-11-17T07:03:30.000Z')
        Update-NotifierLiveContext -Force
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'working' }).Count | Should Be 0
        # Журнал дописан после «Готово», но новых ответов нет (служебная строка) — по-прежнему ждёт.
        Write-Lines $tr @('{"type":"system","subtype":"stop_hook_summary","timestamp":"2026-11-17T07:03:31.000Z"}') -Append
        Update-NotifierLiveContext -Force
        @($script:TrayQueue.ToArray() | Where-Object { $_.type -eq 'working' }).Count | Should Be 0
        # Claude продолжил: новый ответ после «Готово».
        Write-Lines $tr @('{"type":"assistant","timestamp":"2026-11-17T07:05:00.000Z","message":{"model":"claude-sonnet-4-5","id":"msg_9","content":[],"usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":3}}}') -Append
        [void](New-NotifierReplyWait -SessionId 'R' -Minutes 5 -DataRoot $script:TrayDataRoot)
        Update-NotifierLiveContext -Force
        Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput | Out-Null
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]).state | Should Be 'working'
        (Get-NotifierPendingRequests -DataRoot $script:TrayDataRoot).Replies.ContainsKey('R') | Should Be $false
    }

    It 'служебное сообщение (отчёт субагента) не сохраняется как «ваш запрос»' {
        $root = Join-Path $TestDrive 'pr'
        New-Item -ItemType Directory $root -Force | Out-Null
        $cfg = Get-NotifierConfig -DataRoot $root; $cfg.showPrompt = $true
        $ev = [pscustomobject]@{ type = 'working' }
        Add-NotifierEventDetails -Event $ev -Kind prompt -InputJson '{"session_id":"x","prompt":"<agent-message from=\"a1\"> [Subagent hand-back] report"}' -Config $cfg -DataRoot $root
        $null -eq $ev.PSObject.Properties['prompt'] | Should Be $true
        Add-NotifierEventDetails -Event $ev -Kind prompt -InputJson '{"session_id":"x","prompt":"Сделай <b>жирным</b>"}' -Config $cfg -DataRoot $root
        $ev.prompt | Should Be 'Сделай <b>жирным</b>'
    }

    It 'напоминания: через remindMinutes, не чаще раза в remindMinutes, не больше 3 раз; мигание точки' {
        $script:Reminders = @{}
        $cfg = Get-NotifierDefaultConfig
        $now = [DateTime]::UtcNow
        $req = [pscustomobject]@{ id = 'r1'; session_id = 's1'; created = $now.AddMinutes(-4).ToString('o'); title = 'Bash: npm i' }   # как у хука: без проекта
        $pending = @{ Permissions = @($req); Replies = @{}; Gone = @() }
        $sess = @([pscustomobject]@{ session_id = 's1'; project = 'shop'; origin = 'cli'; window = $null })
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now)[0].title | Should Be 'Всё ещё ждёт ответа · Claude'   # сеанс не найден
        $script:Reminders = @{}
        $ev = @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Sessions $sess -Now $now)
        $ev.Count | Should Be 1
        $ev[0].type | Should Be 'permission'
        $ev[0].reminder | Should Be $true
        $ev[0].title | Should Be 'Всё ещё ждёт ответа · shop'
        $ev[0].project | Should Be 'shop'
        $ev[0].origin | Should Be 'cli'
        $ev[0].preview | Should Be 'Bash: npm i — ждёт 4 мин'
        $script:TrayAlert | Should Be $true
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now.AddMinutes(1)).Count | Should Be 0
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now.AddMinutes(3)).Count | Should Be 1
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now.AddMinutes(6)).Count | Should Be 1
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now.AddMinutes(9)).Count | Should Be 0
        # Запрос решён — счётчик забыт, мигание выключено.
        [void](Get-NotifierPermissionReminders -Pending @{ Permissions = @() } -Config $cfg -Now $now)
        $script:Reminders.Count | Should Be 0
        $script:TrayAlert | Should Be $false
        # Без уведомлений: не напоминает, но точка мигает; remindMinutes = 0 — ничего.
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Prefs @{ s1 = @{ title = ''; pinned = $false; muted = $true } } -Now $now).Count | Should Be 0
        $script:TrayAlert | Should Be $true
        $cfg.approvals.remindMinutes = 0
        $script:Reminders = @{}
        @(Get-NotifierPermissionReminders -Pending $pending -Config $cfg -Now $now).Count | Should Be 0
        $script:TrayAlert | Should Be $false
    }

    It 'точка в трее мигает, пока запрос давно ждёт; потом — обычная' {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        try {
            $script:TrayStateShown = 'permission'; $script:BlinkFrame = ''
            $script:TrayAlert = $true
            $t0 = [datetime]'2026-11-17T10:00:00.000'
            Update-NotifierTrayBlink -Now $t0 -Icon $icon
            $a = $script:BlinkFrame
            Update-NotifierTrayBlink -Now $t0.AddMilliseconds(600) -Icon $icon
            $script:BlinkFrame | Should Not Be $a
            @($a, $script:BlinkFrame) -contains 'alert' | Should Be $true
            $script:TrayAlert = $false
            Update-NotifierTrayBlink -Now $t0 -Icon $icon
            $script:BlinkFrame | Should Be ''
            [object]::ReferenceEquals($icon.Icon, (Get-NotifierDotIcon 'permission')) | Should Be $true
        }
        finally { $icon.Dispose() }
    }

    It 'трей: сеанс без уведомлений молчит; предупреждение о контексте — независимо от тумблера «Лимит»; напоминание — не дубль' {
        $script:TrayDataRoot = Join-Path $TestDrive 'batch'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"events":{"limit":{"enabled":false,"sound":""}}}')
        Set-NotifierSessionPref -SessionId 'muted' -Name muted -Value $true -DataRoot $script:TrayDataRoot
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'e1'; type = 'done'; title = 'Готово'; preview = ''; session_id = 'muted'; ts = '2026-11-17T07:00:00Z' })
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'e2'; type = 'limit'; context = $true; title = 'Контекст почти заполнен · a'; preview = ''; session_id = 'other'; ts = '2026-11-17T07:00:00Z' })
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'e3'; type = 'limit'; title = 'Лимит'; preview = ''; ts = '2026-11-17T07:00:00Z' })
        $script:RecentRequest = @{ r = [DateTime]::UtcNow }
        $q.Enqueue([pscustomobject]@{ v = 1; id = 'e4'; type = 'permission'; reminder = $true; title = 'Всё ещё ждёт'; preview = ''; session_id = 'r'; ts = '2026-11-17T07:00:00Z' })
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 2 -Exactly -Scope It
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It -ParameterFilter { $Event.id -eq 'e2' }
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It -ParameterFilter { $Event.id -eq 'e4' }
        @(Get-NotifierSessions -DataRoot $script:TrayDataRoot | Where-Object { $_.session_id -eq 'muted' }).Count | Should Be 1   # статус всё равно обновлён
    }

    It 'настройки сеанса: имя, закрепление, без уведомлений; пустые записи и старые переименования удаляются' {
        $root = Join-Path $TestDrive 'prefs'
        Set-NotifierSessionPref -SessionId 'a' -Name title -Value '  Магазин  ' -DataRoot $root
        Set-NotifierSessionPref -SessionId 'a' -Name pinned -Value $true -DataRoot $root
        Set-NotifierSessionPref -SessionId 'b' -Name title -Value 'Старый' -DataRoot $root -Now ([DateTime]::UtcNow.AddDays(-40))
        Set-NotifierSessionPref -SessionId 'm' -Name muted -Value $true -DataRoot $root -Now ([DateTime]::UtcNow.AddDays(-40))
        $p = Get-NotifierSessionPrefs -DataRoot $root
        $p['a'].title | Should Be 'Магазин'
        $p['a'].pinned | Should Be $true
        $p['b'].title | Should Be 'Старый'
        Set-NotifierSessionPref -SessionId 'c' -Name muted -Value $true -DataRoot $root
        $p = Get-NotifierSessionPrefs -DataRoot $root
        $p.ContainsKey('b') | Should Be $false   # переименование старше 30 дней — удалено
        $p['m'].muted | Should Be $true          # «без уведомлений» не истекает
        # Повреждённый файл не стирается молча: копия .corrupt и запись в журнал
        [IO.File]::WriteAllText((Join-Path $root 'session-prefs.json'), '{bad', [Text.Encoding]::UTF8)
        (Get-NotifierSessionPrefs -DataRoot $root).Count | Should Be 0
        Test-Path (Join-Path $root 'session-prefs.json.corrupt') | Should Be $true
        Set-NotifierSessionPref -SessionId 'c' -Name muted -Value $true -DataRoot $root
        Set-NotifierSessionPref -SessionId 'c' -Name muted -Value $false -DataRoot $root
        (Get-NotifierSessionPrefs -DataRoot $root).ContainsKey('c') | Should Be $false
        Get-NotifierSessionPrefs -DataRoot (Join-Path $TestDrive 'нет') | Should BeOfType [hashtable]
    }

    It 'закреплённые — выше всех; карточка: своё имя, проект во второй строке, значки и контекст' {
        $a = [pscustomobject]@{ session_id = 'a'; project = 'shop'; origin = 'desktop'; device = ''; state = 'permission'; since = ''; updated = '2'; preview = ''; window = $null }
        $b = [pscustomobject]@{ session_id = 'b'; project = 'api'; origin = 'cli'; device = ''; state = 'working'; since = ''; updated = '1'; preview = ''; window = $null
            stats = [pscustomobject]@{ context = 1; window = 200000; percent = 72; output = 1; tools = 0; prompts = 0 } }
        (Get-NotifierSortedSessions -Sessions @($a, $b))[0].session_id | Should Be 'a'
        (Get-NotifierSortedSessions -Sessions @($a, $b) -Pinned @('b'))[0].session_id | Should Be 'b'
        $prefs = @{ b = @{ title = 'Бэкенд'; pinned = $true; muted = $true } }
        $c = ConvertTo-NotifierSessionCard -Session $b -Prefs $prefs -ContextWarn 80
        $c.Title | Should Be 'Бэкенд'
        $c.Meta | Should Be 'Терминал · api'
        $c.Pinned | Should Be $true
        $c.Muted | Should Be $true
        $c.ContextPercent | Should Be 72
        $c.ContextWarn | Should Be 80
        (ConvertTo-NotifierSessionCard -Session $a).ContextPercent | Should Be -1
        # Отрисовка со значками и полоской контекста не падает.
        $list = New-Object ClaudeNotifier.Ui.CardList
        try {
            $list.Size = New-Object System.Drawing.Size(500, 300)
            $items = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
            $c.Urgent = $true; $items.Add($c)
            $list.SetItems($items)
            $bmp = New-Object System.Drawing.Bitmap 500, 300
            $list.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, 500, 300)))
            $bmp.Dispose()
        }
        finally { $list.Dispose() }
    }

    It 'меню карточки: переименовать (пустое имя — имя проекта), закрепить, без уведомлений' {
        $script:TrayDataRoot = Join-Path $TestDrive 'menu'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $s = [pscustomobject]@{ session_id = 'm'; project = 'shop'; origin = 'cli'; device = ''; state = 'waiting'; since = ''; updated = ''; preview = ''; window = $null }
        $item = New-Object ClaudeNotifier.Ui.CardItem
        $item.Tag = $s
        $script:dialogValue = 'Магазин'
        Mock Show-NotifierDialog { @{ Ok = $true; Value = $script:dialogValue } }
        Invoke-NotifierSessionPrefAction -Item $item -Action rename | Should Be 'Сеанс переименован'
        (Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot)['m'].title | Should Be 'Магазин'
        $script:dialogValue = 'shop'
        Invoke-NotifierSessionPrefAction -Item $item -Action rename | Should Be 'Возвращено имя проекта'
        Invoke-NotifierSessionPrefAction -Item $item -Action pin | Should Be 'Сеанс закреплён сверху'
        Invoke-NotifierSessionPrefAction -Item $item -Action pin | Should Be 'Сеанс откреплён'
        Invoke-NotifierSessionPrefAction -Item $item -Action mute | Should Be 'Уведомления этого сеанса выключены'
        (Get-NotifierSessionPrefs -DataRoot $script:TrayDataRoot)['m'].muted | Should Be $true
        $item.Tag = @{ Session = $s; Request = $null }   # карточка с запросом
        Invoke-NotifierSessionPrefAction -Item $item -Action mute | Should Be 'Уведомления этого сеанса включены'
    }

    It 'страница телефона: своё имя, закрепление сверху, процент контекста' {
        $root = Join-Path $TestDrive 'api'
        New-Item -ItemType Directory $root -Force | Out-Null
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $root -Sessions @(
            [pscustomobject]@{ session_id = 'p'; project = 'shop'; origin = 'cli'; device = ''; state = 'permission'; since = $now; updated = $now; preview = ''; window = $null },
            [pscustomobject]@{ session_id = 'q'; project = 'api'; origin = 'cli'; device = ''; state = 'working'; since = $now; updated = $now; preview = ''; window = $null
                stats = [pscustomobject]@{ context = 1; window = 200000; percent = 64; output = 0; tools = 0; prompts = 0 } })
        Set-NotifierSessionPref -SessionId 'q' -Name title -Value 'Бэкенд' -DataRoot $root
        Set-NotifierSessionPref -SessionId 'q' -Name pinned -Value $true -DataRoot $root
        $ctx = @{ Network = (Get-NotifierNetwork -DataRoot $root); DataRoot = $root; PcName = 'PC' }
        $p = Get-NotifierSessionsPayload -Ctx $ctx
        $p.sessions[0].id | Should Be 'q'
        $p.sessions[0].title | Should Be 'Бэкенд'
        $p.sessions[0].pinned | Should Be $true
        $p.sessions[0].context | Should Be 64
        $p.sessions[1].title | Should Be 'shop'
        $p.sessions[1].context | Should Be -1
    }

    It 'горячая клавиша: выключена — не регистрируется; нажатие открывает мини-окно у трея, повторное — закрывает' {
        $script:TrayDataRoot = Join-Path $TestDrive 'hk'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"hotkey":{"enabled":false}}')
        Register-NotifierHotKey | Should Be ''
        $script:HotKey | Should Be $null
        Remove-Item (Join-Path $script:TrayDataRoot 'config.json')
        $text = Register-NotifierHotKey
        try {
            if ($text) { $script:HotKey.Registered | Should Be $true; @('Win+Shift+C', 'Ctrl+Alt+C') -contains $text | Should Be $true }
            $hk = New-Object ClaudeNotifier.Ui.HotKey
            $hk.add_Pressed({ Invoke-NotifierHotKey })
            $script:PopoverClosedAt = [datetime]::MinValue
            $hk.Raise()
            $script:Popover | Should Not Be $null
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $b = $script:Popover.Bounds
            ($b.Right -le $wa.Right -and $b.Bottom -le $wa.Bottom) | Should Be $true
            ($b.Right -ge $wa.Right - 40) | Should Be $true
            $hk.Raise()
            $script:Popover | Should Be $null
            $hk.Dispose()
        }
        finally {
            if ($script:HotKey) { $script:HotKey.Dispose(); $script:HotKey = $null }
            Close-NotifierPopover
        }
    }

    It 'настройки: группа «Внимание» — тумблеры контекста, напоминаний и горячей клавиши' {
        $script:TrayDataRoot = Join-Path $TestDrive 'set'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $ui = $script:SessionsForm.Tag.Settings
            $ui.Switches['context'].Checked | Should Be $true
            $ui.Switches['remind'].Checked | Should Be $true
            Set-NotifierOptionValue -Name approvals -Field remindMinutes -Value 0
            Set-NotifierOptionValue -Name context -Value $false
            Set-NotifierOptionValue -Name hotkey -Value $false
            Update-NotifierSettingsView
            $ui.Switches['remind'].Checked | Should Be $false
            $ui.Switches['context'].Checked | Should Be $false
            $ui.Switches['hotkey'].Checked | Should Be $false
            $ui.HotkeyRow.Tag.Subtitle.Text | Should Match 'Выключена'
            $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
            $c.approvals.waitSeconds | Should Be 600   # остальные поля раздела сохранены
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}
