$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray
. (Join-Path $repoRoot 'src\hook-bridge.ps1')
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[void](Import-NotifierUi)

Describe 's_010_02 · подробности сеанса в хуке' {
    It 'Stop: статистика журнала добавляется к событию; prompt — только если включено showPrompt' {
        $root = Join-Path $TestDrive 'det'
        New-Item -ItemType Directory $root -Force | Out-Null
        $tr = Join-Path $root 't.jsonl'
        [IO.File]::WriteAllText($tr, '{"type":"user","timestamp":"2026-11-17T07:00:00.000Z","message":{"content":"x"}}' + "`n", (New-Object Text.UTF8Encoding $false))
        $ev = [pscustomobject]@{ type = 'done' }
        $json = ConvertTo-Json @{ session_id = 's'; transcript_path = $tr; prompt = 'Мой запрос' } -Compress
        Add-NotifierEventDetails -Event $ev -Kind stop -InputJson $json -Config (Get-NotifierConfig -DataRoot $root) -DataRoot $root
        $ev.stats.prompts | Should Be 1
        $ev.stats.started | Should Be '2026-11-17T07:00:00.000Z'
        $ev2 = [pscustomobject]@{ type = 'working' }
        Add-NotifierEventDetails -Event $ev2 -Kind prompt -InputJson $json -Config (Get-NotifierConfig -DataRoot $root) -DataRoot $root
        $null -eq $ev2.PSObject.Properties['prompt'] | Should Be $true
        $cfg = Get-NotifierConfig -DataRoot $root; $cfg.showPrompt = $true
        Add-NotifierEventDetails -Event $ev2 -Kind prompt -InputJson $json -Config $cfg -DataRoot $root
        $ev2.prompt | Should Be 'Мой запрос'
        Add-NotifierEventDetails -Event $ev2 -Kind stop -InputJson '{bad' -Config $cfg -DataRoot $root
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match 'подробности сеанса не собраны'
    }

    It 'сеанс накапливает начало, статистику и запрос' {
        $l = Update-NotifierSessionList -Sessions @() -Event ([pscustomobject]@{ type = 'working'; session_id = 'a'; ts = '2026-11-17T07:00:00Z'; prompt = 'Сделай' })
        $l[0].prompt | Should Be 'Сделай'
        $l[0].started | Should Be '2026-11-17T07:00:00Z'
        $l = Update-NotifierSessionList -Sessions $l -Event ([pscustomobject]@{ type = 'done'; session_id = 'a'; ts = '2026-11-17T07:10:00Z'; preview = 'ok'; stats = [pscustomobject]@{ started = '2026-11-17T06:50:00Z'; context = 5; output = 6; tools = 7; prompts = 1 } })
        $l[0].started | Should Be '2026-11-17T06:50:00Z'
        $l[0].stats.tools | Should Be 7
        $l[0].prompt | Should Be 'Сделай'
        $l = Update-NotifierSessionList -Sessions $l -Event ([pscustomobject]@{ type = 'request'; session_id = 'a'; ts = '2026-11-17T07:11:00Z' })
        $l[0].state | Should Be 'permission'
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
        $text | Should Match 'Да, продолжай$'
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
            $script:Popover | Should Not Be $null
            $script:Popover.Tag.Cards.Count | Should Be 1
            $script:Popover.Tag.Sub.Text | Should Be '1 активный'
            Show-NotifierPopover   # второй щелчок — закрыть
            $script:Popover | Should Be $null
            Show-NotifierPopover   # сразу после закрытия — не открывать заново
            $script:Popover | Should Be $null
        }
        finally { Close-NotifierPopover }
    }

    It 'щелчки по иконке: таймер одиночного щелчка и двойной щелчок регистрируются' {
        $icon = New-Object System.Windows.Forms.NotifyIcon
        try {
            Register-NotifierTrayClicks -Icon $icon
            $script:TrayClickTimer | Should Not Be $null
            $script:TrayClickTimer.Interval | Should Not BeLessThan 150
        }
        finally { $icon.Dispose(); $script:TrayClickTimer.Dispose() }
    }

    It 'положение у панели задач сверху и сбоку — в пределах рабочей области' {
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $r = Get-NotifierPopoverBounds -Size (New-Object System.Drawing.Size(300, 300)) -Cursor (New-Object System.Drawing.Point(($wa.Left + 5), ($wa.Top + 5)))
        $r.Left | Should Not BeLessThan $wa.Left
        $r.Top | Should Not BeLessThan $wa.Top
    }

    It 'настройки: группа строк с тумблером и подписью' {
        $t = Get-NotifierTheme
        $sw = New-NotifierSwitchControl -Theme $t -Checked $true -OnChange { }
        $g = New-NotifierSettingsGroup -Theme $t -Rows @(@{ Title = 'А'; Subtitle = 'б'; Control = $sw }, @{ Title = 'В'; Subtitle = 'г'; Control = $null }) -Width 400
        try {
            $g.Controls.Count | Should Be 2
            $g.Height | Should Be ($t.S(60) * 2)
            $sw.Checked | Should Be $true
            @(Get-NotifierEventLabel 'done')[0] | Should Be 'Готово'
            @(Get-NotifierEventLabel 'xyz')[0] | Should Be 'xyz'
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
        ($card.Actions -join ';') | Should Be 'allow|Утвердить|primary;deny|Отклонить|destructive'
        Invoke-NotifierCardAction -Item $card -ActionId deny | Should Be 'Запрещено'
        Remove-Item "$script:TrayDataRoot\requests\*" -Force
        $q = [pscustomobject]@{ questions = @([pscustomobject]@{ question = 'A?'; options = @() }, [pscustomobject]@{ question = 'B?'; options = @() }) }
        [void](New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'AskUserQuestion'; tool_input = $q }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot)
        [void](Update-NotifierPending)
        $card = ConvertTo-NotifierSessionCard -Session (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot)[0])
        ($card.Actions -join ';') | Should Be 'focus|Открыть Claude|primary'
        Invoke-NotifierCardAction -Item $card -ActionId focus | Should Be 'Окно этого сеанса не определено'
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
        try { Invoke-NotifierCardAction -Item $card -ActionId 'reply-custom' | Should Be 'Ответ отправлен' }
        finally { $timer.Dispose() }
        Get-Content (Join-Path $script:TrayDataRoot 'requests\reply-p.txt') -Raw -Encoding UTF8 | Should Be 'Сделай коммит'
        Remove-Item "$script:TrayDataRoot\requests\*" -Force
        Invoke-NotifierCardAction -Item $card -ActionId 'reply:1' | Should Be 'Сеанс больше не ждёт ответа'
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
            $script:SessionsForm.Tag.Subtitle.Text | Should Be 'Разрешено'
            Test-Path (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") | Should Be $true
            $script:NoticeUntil = [datetime]::MinValue   # подсказка держится 4 с
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 1
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 2
            $script:SessionsForm.Tag.Subtitle.Text | Should Be 'Уведомления, ответы из приложения и запуск'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }

    It 'мини-окно: «Запретить» в карточке решает запрос' {
        $req = New-NotifierPermissionRequest -HookInput ([pscustomobject]@{ session_id = 'p'; tool_name = 'Bash'; tool_input = [pscustomobject]@{ command = 'ls' } }) -WaitSeconds 60 -DataRoot $script:TrayDataRoot
        Show-NotifierPopover
        try {
            $script:Popover.Tag.Cards.InvokeAction(0, 'deny')
            (Get-Content (Join-Path $script:TrayDataRoot "requests\perm-$($req.id).decision.json") -Raw | ConvertFrom-Json).behavior | Should Be 'deny'
        }
        finally { Close-NotifierPopover }
    }
}
