$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
. (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

function Write-Lines([string]$Path, [string[]]$Lines) {
    [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), (New-Object Text.UTF8Encoding $false))
}
function Iso([datetime]$T) { return $T.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
function Msg([string]$Id, [string]$Tools = '', [switch]$Side, [int]$Out = 1000000) {
    $sc = ''; if ($Side) { $sc = '"isSidechain":true,' }
    return "{`"type`":`"assistant`",$sc`"timestamp`":`"2026-11-18T07:00:00.000Z`",`"cwd`":`"C:\\dev\\shop`",`"message`":{`"model`":`"claude-opus-5-5`",`"id`":`"$Id`",`"content`":[$Tools],`"usage`":{`"input_tokens`":1000000,`"cache_read_input_tokens`":0,`"cache_creation_input_tokens`":0,`"output_tokens`":$Out}}}"
}
function New-Card([string]$Id, [string]$State, [int]$AgoMin, [switch]$Pinned) {
    $c = New-Object ClaudeNotifier.Ui.CardItem
    $c.Id = $Id; $c.Section = 'Этот ПК'; $c.Title = $Id; $c.State = $State; $c.Pinned = [bool]$Pinned
    $c.Tag = [pscustomobject]@{ session_id = $Id; project = $Id; state = $State; since = (Iso ([DateTime]::UtcNow.AddMinutes(-$AgoMin))) }
    return $c
}

Describe 's_013_02 · неактивные сеансы, агенты на карточке, изменённые файлы, стоимость сеанса' {
    It 'журнал: стоимость сеанса (сообщение один раз), папка проекта по имени папки журнала, последнее действие, список файлов' {
        $dir = Join-Path $TestDrive 'C--dev-shop'
        New-Item -ItemType Directory $dir -Force | Out-Null
        $tr = Join-Path $dir 's1.jsonl'
        $edit = '{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"C:\\dev\\shop\\src\\a.ts"}}'
        $bash = '{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"npm run build\nsecond"}}'
        Write-Lines $tr @(
            '{"type":"user","timestamp":"2026-11-18T06:59:00.000Z","cwd":"C:\\Users\\me\\scratch","message":{"content":"x"}}',
            (Msg 'msg_1' $edit), (Msg 'msg_1' $edit),
            (Msg 'msg_2' $bash -Out 0),
            (Msg 'msg_s' '' -Side))   # ответ субагента в журнале сеанса — не в стоимость сеанса
        $s = Get-NotifierTranscriptStats -Path $tr -StateDir (Join-Path $TestDrive 'st')
        [Math]::Round($s.cost, 6) | Should Be 28   # msg_1: $4 + $20; msg_2: $4
        $s.cwd | Should Be 'C:\dev\shop'
        $s.lastTool | Should Be 'Bash: npm run build'
        @($s.fileList) -join ',' | Should Be 'C:\dev\shop\src\a.ts'
        $d = Format-NotifierSessionDetails -Session ([pscustomobject]@{ session_id = 'x'; state = 'waiting'; stats = [pscustomobject]@{ context = 1; output = 1; tools = 1; prompts = 1; cost = 12.4; agentsCost = 3.1 } })
        $d | Should Match 'Стоимость ≈ \$15,50 по ценам API \(агенты \$3,10\)'
    }

    It 'агенты: активные — не завершённые и писавшие недавно, с описанием и последним действием; стоимость — всех' {
        $root = Join-Path $TestDrive 'C--dev-site'
        $sub = Join-Path $root 'sess\subagents'
        New-Item -ItemType Directory $sub -Force | Out-Null
        $tr = Join-Path $root 'sess.jsonl'
        Write-Lines $tr @('{}')
        Write-Lines (Join-Path $sub 'agent-a.jsonl') @((Msg 'msg_a' '{"type":"tool_use","id":"t","name":"Bash","input":{"command":"npm test"}}' -Side -Out 0))
        [IO.File]::WriteAllText((Join-Path $sub 'agent-a.meta.json'), '{"description":"Собрать сайт A","finished":false}')
        Write-Lines (Join-Path $sub 'agent-b.jsonl') @((Msg 'msg_b' '' -Side -Out 0))
        [IO.File]::WriteAllText((Join-Path $sub 'agent-b.meta.json'), '{"description":"Готовый","finished":true}')
        $r = Get-NotifierSessionAgents -Transcript $tr -StateDir (Join-Path $TestDrive 'st2')
        @($r.Active).Count | Should Be 1
        $r.Active[0].name | Should Be 'Собрать сайт A'
        $r.Active[0].doing | Should Be 'Bash: npm test'
        [Math]::Round($r.Cost, 6) | Should Be 8
        $r.Complete | Should Be $true
        # Давно молчащий незавершённый агент — не активный.
        (Get-Item (Join-Path $sub 'agent-a.jsonl')).LastWriteTimeUtc = [DateTime]::UtcNow.AddHours(-2)
        @((Get-NotifierSessionAgents -Transcript $tr -StateDir (Join-Path $TestDrive 'st2')).Active).Count | Should Be 0
        # Время вышло — стоимость неполная.
        $clock = [Diagnostics.Stopwatch]::StartNew(); Start-Sleep -Milliseconds 30
        (Get-NotifierSessionAgents -Transcript $tr -StateDir (Join-Path $TestDrive 'st3') -Clock $clock -BudgetMs 1).Complete | Should Be $false
    }

    It 'трей: у работающего сеанса — «Работает агент», агенты в подробностях, стоимость агентов' {
        $script:TrayDataRoot = Join-Path $TestDrive 'live'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $root = Join-Path $TestDrive 'C--dev-live'
        $sub = Join-Path $root 'L\subagents'
        New-Item -ItemType Directory $sub -Force | Out-Null
        $tr = Join-Path $root 'L.jsonl'
        Write-Lines $tr @((Msg 'msg_1' '' -Out 0))
        Write-Lines (Join-Path $sub 'agent-1.jsonl') @((Msg 'msg_x' '{"type":"tool_use","id":"t","name":"Write","input":{"file_path":"C:\\dev\\site\\index.html"}}' -Side -Out 0))
        [IO.File]::WriteAllText((Join-Path $sub 'agent-1.meta.json'), '{"description":"Сайт A"}')
        $now = Iso ([DateTime]::UtcNow)
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'L'; project = 'site'; origin = 'cli'; device = ''; state = 'working'; since = $now; updated = $now; preview = ''; transcript = $tr; window = $null })
        Update-NotifierLiveContext -Force
        $s = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0]
        @($s.agents).Count | Should Be 1
        [Math]::Round([double]$s.stats.agentsCost, 6) | Should Be 4
        $card = ConvertTo-NotifierSessionCard -Session $s
        $card.StateText | Should Be 'Работает агент'
        $card.Details | Should Match 'Агент: Сайт A — Write: index\.html'
        $card.Details | Should Match 'Стоимость ≈ \$8,00 по ценам API \(агенты \$4,00\)'
        # Событие хука не теряет агентов до следующего прохода трея.
        $l = Update-NotifierSessionList -Sessions @($s) -Event ([pscustomobject]@{ type = 'working'; session_id = 'L'; ts = $now })
        @($l[0].agents).Count | Should Be 1
        Get-NotifierAgentsStateText ([pscustomobject]@{ state = 'working'; agents = @(1, 2) }) | Should Be 'Работают агенты · 2'
        Get-NotifierAgentsStateText ([pscustomobject]@{ state = 'waiting'; agents = @(1) }) | Should Be ''
        $ctx = @{ Network = (Get-NotifierNetwork -DataRoot $script:TrayDataRoot); DataRoot = $script:TrayDataRoot; PcName = 'PC' }
        (Get-NotifierSessionsPayload -Ctx $ctx).sessions[0].state_text | Should Be 'Работает агент'
    }

    It 'неактивные: «Ждёт ответа» дольше 2 ч — в конце группы строкой «Неактивные»; раскрытая — сеансы и «Убрать все»' {
        $cards = @((New-Card 'old1' 'waiting' 300), (New-Card 'w' 'working' 1), (New-Card 'old2' 'waiting' 200), (New-Card 'fresh' 'waiting' 10), (New-Card 'pin' 'waiting' 500 -Pinned))
        $l = Get-NotifierGroupedCards -Cards $cards -MinSessions 0 -InactiveHours 2 -Expanded @{}
        (@($l) | ForEach-Object { $_.Id }) -join ',' | Should Be 'w,fresh,pin,group:inactive|Этот ПК'
        $g = $l[3]
        $g.Title | Should Be 'Неактивные'
        $g.StateText | Should Be '2 сеанса'
        $g.Meta | Should Be 'ждут ответа дольше 2 ч'
        $g.HollowDot | Should Be $true
        $l = Get-NotifierGroupedCards -Cards $cards -MinSessions 0 -InactiveHours 2 -Expanded @{ 'inactive|Этот ПК' = $true }
        (@($l) | ForEach-Object { $_.Id }) -join ',' | Should Be 'w,fresh,pin,group:inactive|Этот ПК,old1,old2'
        $l[3].ForceExpand | Should Be $true
        $l[3].Actions[0] | Should Match '^clear\|Убрать все из списка'
        (@(Get-NotifierGroupedCards -Cards $cards -MinSessions 0 -InactiveHours 0) | ForEach-Object { $_.Id }) -join ',' | Should Be 'old1,w,old2,fresh,pin'
    }

    It '«Убрать все из списка» убирает неактивные сеансы' {
        $script:TrayDataRoot = Join-Path $TestDrive 'clear'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $mk = { param($id) [pscustomobject]@{ session_id = $id; project = 'p'; origin = 'cli'; device = ''; state = 'waiting'; since = ''; updated = ''; preview = ''; window = $null } }
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @((& $mk 'a'), (& $mk 'b'), (& $mk 'c'))
        $script:ExpandedGroups = @{ 'inactive|Этот ПК' = $true }
        $g = New-Object ClaudeNotifier.Ui.CardItem
        $g.IsGroup = $true
        $g.Tag = @{ Group = 'inactive|Этот ПК'; Ids = @('a', 'c') }
        Invoke-NotifierExtraCardAction -Item $g -ActionId clear | Should Be $true
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | ForEach-Object { $_.session_id }) -join ',' | Should Be 'b'
        $script:ExpandedGroups.Count | Should Be 0
    }

    It 'карточка без запроса: кнопки «Изменённые файлы · N» и «Папка проекта»; список файлов — новые первыми, относительно папки' {
        $proj = Join-Path $TestDrive 'proj'
        New-Item -ItemType Directory $proj -Force | Out-Null
        $s = [pscustomobject]@{ session_id = 'f'; project = 'proj'; origin = 'cli'; device = ''; state = 'working'; since = ''; updated = ''; preview = ''; window = $null
            stats = [pscustomobject]@{ context = 1; output = 1; tools = 1; prompts = 1; cwd = ($proj -replace '\\', '/'); fileList = @("$proj\a.ts", "$($proj -replace '\\', '/')/src/b.ts") } }
        $card = ConvertTo-NotifierSessionCard -Session $s
        $card.Actions -join ';' | Should Be 'files|Изменённые файлы · 2|secondary;folder|Папка проекта|secondary'
        (Get-NotifierSessionFiles $s) -join ',' | Should Be "$proj\src\b.ts,$proj\a.ts"
        $menu = New-Object System.Windows.Forms.ContextMenuStrip
        try {
            Add-NotifierFileItems -Items $menu.Items -Session $s
            (@($menu.Items) | ForEach-Object { $_.Text }) -join ',' | Should Be 'src\b.ts,a.ts'
            Add-NotifierFileItems -Items $menu.Items -Session ([pscustomobject]@{ session_id = 'n' })
            $menu.Items[0].Enabled | Should Be $false
        }
        finally { $menu.Dispose() }
        Open-NotifierFile -Path "$proj\нет.ts" | Should Be 'Файла уже нет: нет.ts'
        Get-NotifierSessionFolder ([pscustomobject]@{ stats = [pscustomobject]@{ cwd = 'C:\нет\такой' } }) | Should Be ''
        # Сеанс другого устройства — без кнопок.
        $s.device = 'mac'
        (ConvertTo-NotifierSessionCard -Session $s).Actions.Length | Should Be 0
    }

    It 'настройки: «Убирать давние сеансы» — 2 ч по умолчанию, тумблер в группе «Внимание»' {
        $script:TrayDataRoot = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.inactive.enabled | Should Be $true
        $c.inactive.hours | Should Be 2
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $ui = $script:SessionsForm.Tag.Settings
            $ui.Switches['inactive'].Checked | Should Be $true
            $ui.Switches['inactive'].Toggle()
            (Get-NotifierConfig -DataRoot $script:TrayDataRoot).inactive.enabled | Should Be $false
            $ui.HotkeyRow.Tag.Title.Text | Should Be 'Горячая клавиша'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}
