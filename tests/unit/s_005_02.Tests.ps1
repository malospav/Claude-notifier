# Pester 5: таблицы -TestCases строятся при обнаружении тестов — помощники нужны и там.
BeforeDiscovery {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\History.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray

    function New-Ev([int]$N = 0, [string]$Type = 'done', [string]$Project = 'proj', [string]$Ts = '2026-11-16T12:34:56.000Z') {
        return [pscustomobject]@{ v = 1; id = ('00000000-0000-0000-0000-{0:D12}' -f $N); ts = $Ts; type = $Type; project = $Project; title = "t$N"; preview = "p$N"; window = @{ hwnd = 0; pid = 0 } }
    }
}

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\History.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray

    function New-Ev([int]$N = 0, [string]$Type = 'done', [string]$Project = 'proj', [string]$Ts = '2026-11-16T12:34:56.000Z') {
        return [pscustomobject]@{ v = 1; id = ('00000000-0000-0000-0000-{0:D12}' -f $N); ts = $Ts; type = $Type; project = $Project; title = "t$N"; preview = "p$N"; window = @{ hwnd = 0; pid = 0 } }
    }
}

Describe 's_005_02 · History.psm1' {
    It 'нет файла → пустая история' {
        @(Get-NotifierHistory -DataRoot (Join-Path $TestDrive 'none')).Count | Should -Be 0
    }

    It 'Add добавляет в конец; история переживает «перезапуск» (повторный импорт модуля)' {
        $root = Join-Path $TestDrive 'add'
        Add-NotifierHistory -Event (New-Ev 1) -DataRoot $root | Should -Be 1
        Add-NotifierHistory -Event (New-Ev 2) -DataRoot $root | Should -Be 2
        Import-Module (Join-Path $repoRoot 'src\lib\History.psm1') -Force
        $h = @(Get-NotifierHistory -DataRoot $root)
        $h.Count | Should -Be 2
        $h[0].title | Should -Be 't1'
        $h[1].title | Should -Be 't2'
    }

    It '301 событие → в файле 300 (неделя для статистики), самое старое вытеснено' {
        $root = Join-Path $TestDrive 'cap'
        $seed = @(1..300 | ForEach-Object { New-Ev $_ })
        Save-NotifierHistory -Items $seed -DataRoot $root
        Add-NotifierHistory -Event (New-Ev 301) -DataRoot $root | Should -Be 300
        $h = @(Get-NotifierHistory -DataRoot $root)
        $h.Count | Should -Be 300
        $h[0].title | Should -Be 't2'
        $h[-1].title | Should -Be 't301'
    }

    It 'запись атомарная: временных файлов не остаётся' {
        $root = Join-Path $TestDrive 'atomic'
        Add-NotifierHistory -Event (New-Ev 1) -DataRoot $root | Out-Null
        @(Get-ChildItem $root -Filter 'history.json.tmp-*').Count | Should -Be 0
    }

    It 'одно событие сохраняется как JSON-массив' {
        $root = Join-Path $TestDrive 'single'
        Add-NotifierHistory -Event (New-Ev 1) -DataRoot $root | Out-Null
        ([IO.File]::ReadAllText((Join-Path $root 'history.json'))).TrimStart()[0] | Should -Be '['
    }

    It 'повреждённый файл (<Case>) → пустая история, WARN, файл переименован в .corrupt' -TestCases @(
        @{ Case = 'битый JSON'; Content = '{ broken' },
        @{ Case = 'объект вместо массива'; Content = '{ "a": 1 }' }
    ) {
        param($Case, $Content)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content (Join-Path $root 'history.json') $Content
        @(Get-NotifierHistory -DataRoot $root).Count | Should -Be 0
        Test-Path (Join-Path $root 'history.json') | Should -Be $false
        (Get-Content (Join-Path $root 'history.json.corrupt') -Raw).Trim() | Should -Be $Content
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] history: history\.json повреждён'
        Add-NotifierHistory -Event (New-Ev 1) -DataRoot $root | Should -Be 1
    }

    It 'Set-NotifierHistoryStatus и Find-NotifierHistoryEvent' {
        $root = Join-Path $TestDrive 'status'
        Save-NotifierHistory -Items @((New-Ev 1), (New-Ev 2)) -DataRoot $root
        Set-NotifierHistoryStatus -Id (New-Ev 2).id -Status closed -DataRoot $root | Should -Be $true
        Set-NotifierHistoryStatus -Id 'nope' -Status closed -DataRoot $root | Should -Be $false
        (Find-NotifierHistoryEvent -Id (New-Ev 2).id -DataRoot $root).status | Should -Be 'closed'
        $null -eq (Find-NotifierHistoryEvent -Id (New-Ev 1).id -DataRoot $root).PSObject.Properties['status'] | Should -Be $true
        Find-NotifierHistoryEvent -Id 'nope' -DataRoot $root | Should -Be $null
    }

    It 'пустая история сохраняется как []' {
        $root = Join-Path $TestDrive 'empty'
        Save-NotifierHistory -Items @() -DataRoot $root
        ([IO.File]::ReadAllText((Join-Path $root 'history.json'))) | Should -Be '[]'
    }
}

Describe 's_005_02 · формат пункта меню' {
    BeforeDiscovery {
        $hhmm = ([DateTimeOffset]'2026-11-16T12:34:56Z').ToLocalTime().ToString('HH:mm')
    }
    BeforeAll {
        $hhmm = ([DateTimeOffset]'2026-11-16T12:34:56Z').ToLocalTime().ToString('HH:mm')
    }

    It '<Case> → "<Expected>"' -TestCases @(
        @{ Case = 'обычное'; Ev = (New-Ev 1 'permission' 'app'); Expected = "$hhmm · Нужно разрешение · app" },
        @{ Case = 'без проекта'; Ev = (New-Ev 1 'error' ''); Expected = "$hhmm · Ошибка" },
        @{ Case = 'без ts'; Ev = [pscustomobject]@{ type = 'limit'; project = 'x' }; Expected = '--:-- · Лимит · x' }
    ) {
        param($Case, $Ev, $Expected)
        Format-NotifierHistoryItem -Event $Ev | Should -Be $Expected
    }

    It 'закрытая сессия помечается «(закрыта)»' {
        $e = New-Ev 1; $e | Add-Member -NotePropertyName status -NotePropertyValue 'closed'
        Format-NotifierHistoryItem -Event $e | Should -Be "$hhmm · Готово · proj (закрыта)"
    }
}

Describe 's_005_02 · меню «История» в трее' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
    }


    It 'показывает 20 последних, новые сверху; Tag = id' {
        $root = Join-Path $TestDrive 'menu'
        Save-NotifierHistory -Items @(1..25 | ForEach-Object { New-Ev $_ }) -DataRoot $root
        $item = New-Object System.Windows.Forms.ToolStripMenuItem 'История'
        Update-NotifierHistoryMenu -MenuItem $item -DataRoot $root
        $item.DropDownItems.Count | Should -Be 20
        $item.DropDownItems[0].Tag | Should -Be (New-Ev 25).id
        $item.DropDownItems[19].Tag | Should -Be (New-Ev 6).id
        $item.DropDownItems[0].Text | Should -Match ' · Готово · proj$'
    }

    It 'пустая история → один неактивный пункт «(пусто)»' {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem 'История'
        Update-NotifierHistoryMenu -MenuItem $item -DataRoot (Join-Path $TestDrive 'nohistory')
        $item.DropDownItems.Count | Should -Be 1
        $item.DropDownItems[0].Text | Should -Be '(пусто)'
        $item.DropDownItems[0].Enabled | Should -Be $false
    }

    It 'клик по пункту → запуск обработчика с id этого события' {
        $root = Join-Path $TestDrive 'click'
        Save-NotifierHistory -Items @((New-Ev 7)) -DataRoot $root
        Mock Start-NotifierFocusHandler { }
        $item = New-Object System.Windows.Forms.ToolStripMenuItem 'История'
        Update-NotifierHistoryMenu -MenuItem $item -DataRoot $root
        $item.DropDownItems[0].PerformClick()
        Assert-MockCalled Start-NotifierFocusHandler -Scope It -Times 1 -Exactly -ParameterFilter { $Id -eq (New-Ev 7).id }
    }

    It 'меню трея: «Сеансы», «История» и «Выход»; история перечитывается при открытии' {
        $root = Join-Path $TestDrive 'traymenu'
        $icon = New-NotifierTrayIcon -OnExit { } -DataRoot $root
        try {
            ($icon.ContextMenuStrip.Items | ForEach-Object { $_.Text }) -join ',' | Should -Be 'Сеансы,Устройства,Настройки,Статистика,История,Обновить Claude Notifier…,Проверить работу,,Выход'
            Add-NotifierHistory -Event (New-Ev 3) -DataRoot $root | Out-Null
            $hist = $icon.ContextMenuStrip.Items[4]
            $hist.ShowDropDown(); $hist.HideDropDown()
            $hist.DropDownItems[0].Tag | Should -Be (New-Ev 3).id
        }
        finally { $icon.Visible = $false; $icon.Dispose() }
    }

}

Describe 's_005_02 · запуск обработчика' {
    It 'Start-NotifierFocusHandler: conhost --headless powershell -File focus-handler.ps1 "<URI>"' {
        Mock Start-Process { }
        Mock Invoke-AllowForeground { $true }
        Start-NotifierFocusHandler -Id '11111111-2222-3333-4444-555555555555'
        Assert-MockCalled Invoke-AllowForeground -Scope It -Times 1
        Assert-MockCalled Start-Process -Scope It -Times 1 -Exactly -ParameterFilter {
            $FilePath -like '*\System32\conhost.exe' -and $ArgumentList[0] -eq '--headless' -and
            ($ArgumentList -join ' ') -like '*-File "*\focus-handler.ps1" "claude-notifier:focus?id=11111111-2222-3333-4444-555555555555"'
        }
    }

    It 'реальный AllowSetForegroundWindow вызывается без ошибок' {
        { Invoke-AllowForeground } | Should -Not -Throw
    }
}

Describe 's_005_02 · трей записывает историю' {
    It 'показанное событие попадает в history.json, выключенное — нет' {
        $root = Join-Path $TestDrive 'record'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "events": { "error": { "enabled": false } } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue((New-Ev 1 'done')); $q.Enqueue((New-Ev 2 'error'))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $root -NoOutput | Should -Be 1
        $h = @(Get-NotifierHistory -DataRoot $root)   # PS 5.1: у одиночного PSCustomObject нет .Count
        $h.Count | Should -Be 1
        $h[0].type | Should -Be 'done'
    }

    It 'ошибка записи истории не мешает показу' {
        $root = Join-Path $TestDrive 'recordfail'
        Mock Add-NotifierHistory { throw 'disk full' }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue((New-Ev 1))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $root -NoOutput | Should -Be 1
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[ERROR\] tray: история не записана: disk full'
    }
}
