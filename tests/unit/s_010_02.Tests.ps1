BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray
    . (Join-Path $repoRoot 'src\hook-bridge.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
}

Describe 's_010_02 · подробности сеанса в хуке' {
    It 'служебный Claude внутри другого сеанса (сводка через «claude -p»): не сеанс, ни разрешения, ни быстрого ответа' {
        # Claude Code — claude.exe не из папки самого приложения Claude
        Test-NotifierClaudeCodePath 'C:\Users\u\AppData\Local\Claude-Data\c\claude-code\2.1.326\d\claude.exe' | Should -Be $true
        Test-NotifierClaudeCodePath 'C:\Users\u\.local\bin\claude.exe' | Should -Be $true
        Test-NotifierClaudeCodePath 'C:\Program Files\WindowsApps\Claude_6.6395.0.0_x64__pzs8sxrjxfjjc\app\claude.exe' | Should -Be $false
        Test-NotifierClaudeCodePath 'C:\Users\u\AppData\Local\AnthropicClaude\app-1.0.0\claude.exe' | Should -Be $false
        Test-NotifierClaudeCodePath '' | Should -Be $false
        [ClaudeNotifier.Ui.ProcInfo]::IsClaudeCodePath('C:\x\claude-code\2\claude.exe') | Should -Be $true
        [ClaudeNotifier.Ui.ProcInfo]::IsClaudeCodePath('C:\Program Files\WindowsApps\Claude_6\app\claude.exe') | Should -Be $false
        # Обычный запуск этих тестов — не вложенный
        Test-NotifierNestedClaude | Should -Be $false
        $root = Join-Path $TestDrive 'nested'
        New-Item -ItemType Directory $root -Force | Out-Null
        $json = '{"session_id":"helper","cwd":"C:\\dev\\x","last_assistant_message":"## Session Summary\nПродолжить?"}'
        Mock Test-NotifierNestedClaude { $true }
        Mock Send-NotifierEventToTray { 'sent' }
        Invoke-NotifierHookBridge -Kind sessionstart -InputJson $json -DataRoot $root | Should -Be 'nested'
        Assert-MockCalled Send-NotifierEventToTray -Times 0 -Exactly -Scope It
        Invoke-NotifierReplyHook -InputJson $json -DataRoot $root | Should -Be $null
        Invoke-NotifierPermissionHook -InputJson '{"session_id":"helper","tool_name":"Bash","tool_input":{"command":"ls"}}' -DataRoot $root | Should -Be ''
        @(Get-ChildItem (Join-Path $root 'requests') -ErrorAction SilentlyContinue).Count | Should -Be 0   # ни ожиданий, ни запросов
        # Хук от curl: трей отбрасывает вложенный вызов, обычный — принимает
        $call = New-Object ClaudeNotifier.Ui.HookCall
        $call.Kind = 'stop'; $call.Body = $json; $call.Nested = $true
        ConvertFrom-NotifierHookCall -Call $call -DataRoot $root | Should -Be $null
        $call.Nested = $false
        (ConvertFrom-NotifierHookCall -Call $call -DataRoot $root).session_id | Should -Be 'helper'
        Mock Test-NotifierNestedClaude { $false }   # в Pester 3 мок живёт до конца Describe — вернуть обычное поведение
    }

    It 'сводка ECC: распознаётся по переменной окружения, по журналу; уже попавший в список сеанс убирается' {
        $old = $env:ECC_LLM_SUMMARY_SUBPROCESS
        try {
            $env:ECC_LLM_SUMMARY_SUBPROCESS = '1'
            # В отдельном процессе (он наследует переменную, как хук вложенного Claude) — мимо мока из прошлого теста
            $win = Join-Path $repoRoot 'src\lib\Window.psm1'
            (& powershell -NoProfile -Command "Import-Module '$win'; Test-NotifierNestedClaude") | Should -Be 'True'
        }
        finally { $env:ECC_LLM_SUMMARY_SUBPROCESS = $old }
        $root = Join-Path $TestDrive 'helper'
        New-Item -ItemType Directory $root -Force | Out-Null
        $utf8 = New-Object Text.UTF8Encoding $false
        $help = Join-Path $root 'h.jsonl'
        [IO.File]::WriteAllText($help, '{"type":"queue-operation","sessionId":"h"}' + "`n" + '{"type":"user","message":{"role":"user","content":"Below is a conversation log from a Claude Code coding session.\n\n## x"}}' + "`n", $utf8)
        $mine = Join-Path $root 'm.jsonl'
        [IO.File]::WriteAllText($mine, '{"type":"user","message":{"role":"user","content":"Сделай шторку"}}' + "`n", $utf8)
        Test-NotifierHelperTranscript -Path $help | Should -Be $true
        Test-NotifierHelperTranscript -Path $mine | Should -Be $false
        Test-NotifierHelperTranscript -Path (Join-Path $root 'нет.jsonl') | Should -Be $null
        # Сеанс уже в списке (первое событие проскочило): следующее событие его убирает, дальнейшие — отбрасываются
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 'h'; state = 'waiting'; transcript = $help },
            [pscustomobject]@{ session_id = 'm'; state = 'working'; transcript = $mine }) -DataRoot $root
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        foreach ($s in 'h', 'm') {
            $q.Enqueue([pscustomobject]@{ v = 1; type = 'working'; title = 'p'; preview = ''; session_id = $s; project = 'p'; origin = 'desktop'; transcript = (Join-Path $root "$s.jsonl"); timestamp = (Get-Date).ToUniversalTime().ToString('o') })
        }
        [void](Invoke-NotifierEventBatch -Queue $q -DataRoot $root -NoOutput)
        @(Get-NotifierSessions -DataRoot $root | ForEach-Object { $_.session_id }) -join ',' | Should -Be 'm'
        Test-NotifierHelperEvent -Event ([pscustomobject]@{ session_id = 'h' }) -DataRoot $root | Should -Be $true   # запомнен
    }

    It 'сеанс Mac «работает», а Mac молчит час — «нет связи»; недавно был на связи или ждёт ответа — как есть' {
        $now = [datetime]::Parse('2026-11-18T12:00:00Z').ToUniversalTime()
        $devs = New-Object System.Collections.ArrayList
        [void]$devs.Add([pscustomobject]@{ id = 'dm'; name = 'MacBook'; last_seen = '2026-11-18T10:30:00.000Z' })
        $saved = $script:Net
        try {
            $script:Net = @{ Network = @{ devices = $devs } }
            $s = [pscustomobject]@{ session_id = 'a'; device = 'dm'; state = 'working'; updated = '2026-11-18T10:20:00.000Z' }
            (Get-NotifierDeviceSilentSince -Session $s -Now $now).ToString('HH:mm') | Should -Be '10:30'
            $s.state = 'waiting'
            Get-NotifierDeviceSilentSince -Session $s -Now $now | Should -Be $null
            $s.state = 'working'; $devs[0].last_seen = '2026-11-18T11:30:00.000Z'
            Get-NotifierDeviceSilentSince -Session $s -Now $now | Should -Be $null
            Get-NotifierDeviceSilentSince -Session ([pscustomobject]@{ session_id = 'p'; device = ''; state = 'working'; updated = '2026-11-18T01:00:00.000Z' }) -Now $now | Should -Be $null
        }
        finally { $script:Net = $saved }
    }

    It 'hook.sh на Mac: сводка ECC не отправляется, обычный сеанс — отправляется (дерево процессов не проверяется)' {
        $hook = Join-Path $repoRoot 'src\mac\hook.sh'
        (Get-Content -Raw $hook) | Should -Match 'ECC_LLM_SUMMARY_SUBPROCESS'
        (Get-Content -Raw $hook) | Should -Not -Match 'ps -o comm='
    }

    It 'Stop: статистика журнала добавляется к событию; prompt — только если включено showPrompt' {
        $root = Join-Path $TestDrive 'det'
        New-Item -ItemType Directory $root -Force | Out-Null
        $tr = Join-Path $root 't.jsonl'
        [IO.File]::WriteAllText($tr, '{"type":"user","timestamp":"2026-11-17T07:00:00.000Z","message":{"content":"x"}}' + "`n", (New-Object Text.UTF8Encoding $false))
        $ev = [pscustomobject]@{ type = 'done' }
        $json = ConvertTo-Json @{ session_id = 's'; transcript_path = $tr; prompt = 'Мой запрос' } -Compress
        Add-NotifierEventDetails -Event $ev -Kind stop -InputJson $json -Config (Get-NotifierConfig -DataRoot $root) -DataRoot $root
        $ev.stats.prompts | Should -Be 1
        $ev.stats.started | Should -Be '2026-11-17T07:00:00.000Z'
        $ev2 = [pscustomobject]@{ type = 'working' }
        Add-NotifierEventDetails -Event $ev2 -Kind prompt -InputJson $json -Config (Get-NotifierConfig -DataRoot $root) -DataRoot $root
        $null -eq $ev2.PSObject.Properties['prompt'] | Should -Be $true
        $cfg = Get-NotifierConfig -DataRoot $root; $cfg.showPrompt = $true
        Add-NotifierEventDetails -Event $ev2 -Kind prompt -InputJson $json -Config $cfg -DataRoot $root
        $ev2.prompt | Should -Be 'Мой запрос'
        # Сетевой путь к журналу (\\хост\… или //хост/… с Mac) не принимается: трей не должен к нему обращаться
        foreach ($bad in '\\attacker\share\t.jsonl', '//attacker/share/t.jsonl', 'C:\\attacker\t.jsonl', (Join-Path $root 't.txt')) {
            $evBad = [pscustomobject]@{ type = 'done' }
            Add-NotifierEventDetails -Event $evBad -Kind stop -InputJson (ConvertTo-Json @{ session_id = 's'; transcript_path = $bad } -Compress) -Config $cfg -DataRoot $root
            $null -eq $evBad.PSObject.Properties['transcript'] | Should -Be $true
            $null -eq $evBad.PSObject.Properties['stats'] | Should -Be $true
        }
        Add-NotifierEventDetails -Event $ev2 -Kind stop -InputJson '{bad' -Config $cfg -DataRoot $root
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match 'подробности сеанса не собраны'
    }

    It 'сеанс накапливает начало, статистику и запрос' {
        $l = Update-NotifierSessionList -Sessions @() -Event ([pscustomobject]@{ type = 'working'; session_id = 'a'; ts = '2026-11-17T07:00:00Z'; prompt = 'Сделай' })
        $l[0].prompt | Should -Be 'Сделай'
        $l[0].started | Should -Be '2026-11-17T07:00:00Z'
        $l = Update-NotifierSessionList -Sessions $l -Event ([pscustomobject]@{ type = 'done'; session_id = 'a'; ts = '2026-11-17T07:10:00Z'; preview = 'ok'; stats = [pscustomobject]@{ started = '2026-11-17T06:50:00Z'; context = 5; output = 6; tools = 7; prompts = 1 } })
        $l[0].started | Should -Be '2026-11-17T06:50:00Z'
        $l[0].stats.tools | Should -Be 7
        $l[0].prompt | Should -Be 'Сделай'
        $l = Update-NotifierSessionList -Sessions $l -Event ([pscustomobject]@{ type = 'request'; session_id = 'a'; ts = '2026-11-17T07:11:00Z' })
        $l[0].state | Should -Be 'permission'
    }

    It 'быстрый ответ: хук ждёт файл ответа и отдаёт текст' {
        $root = Join-Path $TestDrive 'rw'
        New-Item -ItemType Directory $root -Force | Out-Null
        Set-NotifierConfigValue -Name quickReplies -Value ([pscustomobject]@{ enabled = $true; minutes = 1 }) -DataRoot $root
        # Ответ приходит «из приложения» через полсекунды — в отдельном процессе.
        $mod = Join-Path $repoRoot 'src\lib\Requests.psm1'
        $p = Start-Process powershell -ArgumentList @('-NoProfile', '-Command', "Import-Module '$mod'; Start-Sleep -Milliseconds 800; [void](Write-NotifierReply -SessionId 'rs' -Text 'Да, продолжай' -DataRoot '$root')") -PassThru -WindowStyle Hidden
        $text = Invoke-NotifierReplyHook -InputJson '{"session_id":"rs"}' -DataRoot $root
        $p.WaitForExit(10000) | Out-Null
        $text | Should -Match 'Да, продолжай$'
    }
}

Describe 's_010_02 · мини-окно и щелчки по трею' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('p-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:SessionsForm = $null
        $script:PopoverClosedAt = [datetime]::MinValue
    }

    It 'открывается со списком, повторный вызов закрывает, сразу после закрытия не открывается снова' {
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 's'; project = 'proj'; origin = 'desktop'; device = ''; state = 'working'; since = $now; updated = $now; preview = ''; window = $null })
        Show-NotifierPopover
        try {
            $script:Popover | Should -Not -Be $null
            $script:Popover.Tag.Cards.Count | Should -Be 1
            $script:Popover.Tag.Sub.Text | Should -Be '1 активный'
            Show-NotifierPopover   # второй щелчок — закрыть
            $script:Popover | Should -Be $null
            Show-NotifierPopover   # сразу после закрытия — не открывать заново
            $script:Popover | Should -Be $null
        }
        finally { Close-NotifierPopover }
    }

    It 'щелчки по иконке: таймер одиночного щелчка и двойной щелчок регистрируются' {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        try {
            Register-NotifierTrayClicks -Icon $icon
            $script:TrayClickTimer | Should -Not -Be $null
            $script:TrayClickTimer.Interval | Should -Not -BeLessThan 150
        }
        finally { $icon.Dispose(); $script:TrayClickTimer.Dispose() }
    }

    It 'положение у панели задач сверху и сбоку — в пределах рабочей области' {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $r = Get-NotifierPopoverBounds -Size (New-Object System.Drawing.Size(300, 300)) -Cursor (New-Object System.Drawing.Point(($wa.Left + 5), ($wa.Top + 5)))
        $r.Left | Should -Not -BeLessThan $wa.Left
        $r.Top | Should -Not -BeLessThan $wa.Top
    }

    It 'настройки: группа строк с тумблером и подписью' {
        $t = Get-NotifierTheme
        $sw = New-NotifierSwitchControl -Theme $t -Checked $true -OnChange { }
        $g = New-NotifierSettingsGroup -Theme $t -Rows @(@{ Title = 'А'; Subtitle = 'б'; Control = $sw }, @{ Title = 'В'; Subtitle = 'г'; Control = $null }) -Width 400
        try {
            $g.Controls.Count | Should -Be 2
            $g.Height | Should -Be ($t.S(60) * 2)
            $sw.Checked | Should -Be $true
            @(Get-NotifierEventLabel 'done')[0] | Should -Be 'Готово'
            @(Get-NotifierEventLabel 'xyz')[0] | Should -Be 'xyz'
        }
        finally { $g.Dispose() }
    }
}

Describe 's_010_02 · кнопки карточки: остальные ветки' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('b-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory "$script:TrayDataRoot\requests" -Force | Out-Null
        $script:SessionsForm = $null
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'p'; project = 'proj'; origin = 'desktop'; device = ''; state = 'waiting'; since = $now; updated = $now; preview = ''; window = $null })
    }

    It 'план: «Утвердить» / «Отклонить»; несколько вопросов — «Открыть Claude»' {
        $plan = New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'ExitPlanMode'; tool_input = [pscustomobject]@{ plan = 'Шаги' } }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        ($card.Actions -join ';') | Should -Be 'allow|Утвердить|primary;deny|Отклонить|destructive'
        Invoke-NotifierCardAction -Item $card -ActionId deny | Should -Be 'Запрещено'
        Remove-Item "$script:TrayDataRoot\requests\*" -Force
        $q = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'A?'; options = @() }, [pscustomobject]@{ question = 'B?'; options = @() }) }
        [void](New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'AskUserQuestion'; tool_input = $q }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot)
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        ($card.Actions -join ';') | Should -Be 'focus|Открыть Claude|primary'
        Invoke-NotifierCardAction -Item $card -ActionId focus | Should -Be 'Окно этого сеанса не определено'
    }

    It 'свой ответ и быстрый ответ своим текстом — через диалог' {
        [void](New-NotifierReplyWait -SessionId 'p' -Minutes 5 -DataRoot $script:TrayDataRoot)
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 300
        $timer.add_Tick({
                $this.Stop()
                $f = @([System.Windows.Forms.Application]::OpenForms)[-1]
                $f.Tag.Box.Text = 'Сделай коммит'
                $f.DialogResult = [System.Windows.Forms.DialogResult]::OK
            })
        $timer.Start()
        try { Invoke-NotifierCardAction -Item $card -ActionId 'reply-custom' | Should -Be 'Ответ отправлен' }
        finally { $timer.Dispose() }
        Get-Content (Join-Path $script:TrayDataRoot 'requests\reply-p.txt') -Raw -Encoding UTF8 | Should -Be 'Сделай коммит'
        Remove-Item "$script:TrayDataRoot\requests\*" -Force
        Invoke-NotifierCardAction -Item $card -ActionId 'reply:1' | Should -Be 'Сеанс больше не ждёт ответа'
    }
}

Describe 's_010_02 · кнопки через обработчики окон' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('h-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory "$script:TrayDataRoot\requests" -Force | Out-Null
        $script:SessionsForm = $null
        $script:PopoverClosedAt = [datetime]::MinValue
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $now = [DateTime]::UtcNow.ToString('o')
        Save-NotifierSessions -DataRoot $script:TrayDataRoot -Sessions @([pscustomobject]@{ session_id = 'p'; project = 'proj'; origin = 'desktop'; device = ''; state = 'permission'; since = $now; updated = $now; preview = ''; window = $null })
    }

    It 'окно «Сеансы»: «Разрешить» в карточке решает запрос и показывает подсказку' {
        $req = New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'Bash'; tool_input = [pscustomobject]@{ command = 'ls' } }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            [void](Invoke-NotifierSessionsRefresh)
            $script:SessionsForm.Tag.Cards.InvokeAction(0, 'allow')
            $script:SessionsForm.Tag.Subtitle.Text | Should -Be 'Разрешено'
            Test-Path (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") | Should -Be $true
            $script:NoticeUntil = [datetime]::MinValue   # подсказка держится 4 с
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 1
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 2
            $script:SessionsForm.Tag.Subtitle.Text | Should -Be 'Уведомления, ответы из приложения и запуск'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }

    It 'мини-окно: «Запретить» в карточке решает запрос' {
        $req = New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'Bash'; tool_input = [pscustomobject]@{ command = 'ls' } }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        Show-NotifierPopover
        try {
            $script:Popover.Tag.Cards.InvokeAction(0, 'deny')
            (Get-Content (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") -Raw | ConvertFrom-Json).behavior | Should -Be 'deny'
        }
        finally { Close-NotifierPopover }
    }
}
