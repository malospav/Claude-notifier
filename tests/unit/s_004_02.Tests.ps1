$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$statusline = Join-Path $repoRoot 'src\statusline.ps1'
. $statusline
Import-Module (Join-Path $repoRoot 'src\lib\Settings.psm1') -Force
$install = Join-Path $repoRoot 'install.ps1'
$uninstall = Join-Path $repoRoot 'uninstall.ps1'
$classesBase = 'HKCU:\Software\claude-notifier-tests-' + [guid]::NewGuid().ToString('N')

function New-StatusJson([object]$Ctx = 42.7, [object]$Five = 23.5, [object]$Week = 81.2) {
    $o = @{ session_id = 's1'; cwd = 'C:\dev\proj'; model = @{ display_name = 'Opus' } }
    if ($null -ne $Ctx) { $o.context_window = @{ used_percentage = $Ctx } }
    $rl = @{}
    if ($null -ne $Five) { $rl.five_hour = @{ used_percentage = $Five; resets_at = 1795000000 } }
    if ($null -ne $Week) { $rl.seven_day = @{ used_percentage = $Week; resets_at = 1795500000 } }
    if ($rl.Count -gt 0) { $o.rate_limits = $rl }
    return ($o | ConvertTo-Json -Depth 5 -Compress)
}

Describe 's_004_02 · Format-NotifierStatusLine' {
    It '<Case> → "<Expected>"' -TestCases @(
        @{ Case = 'все части'; Json = (New-StatusJson); Expected = 'Opus · ctx 42% · 5ч 23% · нед 81%' },
        @{ Case = 'без лимитов'; Json = (New-StatusJson 10 $null $null); Expected = 'Opus · ctx 10%' },
        @{ Case = 'контекст ещё null'; Json = '{ "model": { "display_name": "Opus" }, "context_window": { "used_percentage": null } }'; Expected = 'Opus' },
        @{ Case = 'только недельный лимит'; Json = (New-StatusJson $null $null 55); Expected = 'Opus · нед 55%' },
        @{ Case = 'битый JSON'; Json = '{ broken'; Expected = '' }
    ) {
        param($Case, $Json, $Expected)
        $status = $null
        try { $status = $Json | ConvertFrom-Json } catch { }
        Format-NotifierStatusLine $status | Should Be $Expected
    }
}

Describe 's_004_02 · Invoke-NotifierStatusLine' {
    It 'без прежней строки → только своя; пересечение порога → событие limit в трей' {
        $root = Join-Path $TestDrive 'own'
        Mock Send-NotifierEvent { $true }
        Invoke-NotifierStatusLine -StdinText (New-StatusJson) -DataRoot $root | Should Be 'Opus · ctx 42% · 5ч 23% · нед 81%'
        Assert-MockCalled Send-NotifierEvent -Scope It -Times 1 -Exactly -ParameterFilter { $Event.type -eq 'limit' -and $Event.preview -like 'Неделя: 81 %*' }
    }

    It 'трей не запущен → WARN, без запуска трея' {
        $root = Join-Path $TestDrive 'notray'
        Mock Send-NotifierEvent { $false }
        Mock Start-Process { }
        [void](Invoke-NotifierStatusLine -StdinText (New-StatusJson -Five 91) -DataRoot $root)
        Assert-MockCalled Start-Process -Scope It -Times 0
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[WARN\] statusline: событие о лимите .* не доставлено'
    }

    It 'прежняя строка статуса печатается первой, ей передаётся тот же stdin' {
        $root = Join-Path $TestDrive 'chain'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "chainStatusLine": { "type": "command", "command": "my-old-statusline" } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Mock Send-NotifierEvent { $true }
        Mock Invoke-ChainedStatusLine { "OLD:" + ($StdinText | ConvertFrom-Json).session_id }
        Invoke-NotifierStatusLine -StdinText (New-StatusJson -Week 10) -DataRoot $root | Should Be "OLD:s1`nOpus · ctx 42% · 5ч 23% · нед 10%"
        Assert-MockCalled Invoke-ChainedStatusLine -Scope It -Times 1 -Exactly -ParameterFilter { $Command -eq 'my-old-statusline' }
    }

    It 'ошибка внутри → печатается хотя бы имя модели' {
        $root = Join-Path $TestDrive 'err'
        Mock Get-NotifierConfig { throw 'boom' }
        Invoke-NotifierStatusLine -StdinText (New-StatusJson) -DataRoot $root | Should Be 'Opus'
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] statusline: boom'
    }

}

Describe 's_004_02 · ошибка в лимитах (отдельный Describe: моки Pester 3.4 живут до конца Describe)' {
    It 'ошибка в лимитах не ломает строку' {
        $root = Join-Path $TestDrive 'limerr'
        Mock Send-NotifierLimitEvents { throw 'limits boom' }
        Invoke-NotifierStatusLine -StdinText (New-StatusJson) -DataRoot $root | Should Be 'Opus · ctx 42% · 5ч 23% · нед 81%'
    }
}

Describe 's_004_02 · реальная прежняя строка (Git Bash или PowerShell)' {
    It 'команда получает stdin и её вывод возвращается' {
        $cmd = 'echo prev-$(head -c 5)'
        $shell = Get-ChainShell
        if ($shell.File -notlike '*bash.exe') { $cmd = '$x = [Console]::In.ReadToEnd(); "prev-" + $x.Substring(0,5)' }
        Invoke-ChainedStatusLine -Command $cmd -StdinText '{"ab":1}' -DataRoot $TestDrive | Should Be 'prev-{"ab"'
    }

    It 'зависшая команда прерывается по таймауту → пусто и WARN' {
        $root = Join-Path $TestDrive 'hang'
        $script:ChainTimeoutMs = 500
        try {
            $cmd = 'sleep 5'
            if ((Get-ChainShell).File -notlike '*bash.exe') { $cmd = 'Start-Sleep 5' }
            Invoke-ChainedStatusLine -Command $cmd -StdinText '{}' -DataRoot $root | Should Be ''
        }
        finally { $script:ChainTimeoutMs = 3000 }
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[WARN\] statusline: прежняя строка статуса не ответила'
    }

    It 'несуществующая оболочка → пусто и WARN' {
        $root = Join-Path $TestDrive 'noshell'
        Mock Get-ChainShell { @{ File = 'C:\nope\none.exe'; Args = @() } }
        Invoke-ChainedStatusLine -Command 'x' -StdinText '{}' -DataRoot $root | Should Be ''
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match 'не запустилась'
    }
}

Describe 's_004_02 · statusline.ps1 как процесс' {
    It 'печатает строку в UTF-8 и выходит с 0; битый stdin → пустая строка, 0' {
        $lad = Join-Path $TestDrive 'lad'
        New-Item -ItemType Directory -Path $lad | Out-Null
        foreach ($case in @(@{ In = (New-StatusJson -Week 10); Out = 'Opus · ctx 42% · 5ч 23% · нед 10%' }, @{ In = '{ broken'; Out = '' })) {
            $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -File `"$statusline`""
            $psi.UseShellExecute = $false
            $psi.RedirectStandardInput = $true
            $psi.RedirectStandardOutput = $true
            $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
            $psi.EnvironmentVariables['LOCALAPPDATA'] = $lad
        $psi.EnvironmentVariables['CLAUDE_NOTIFIER_HOME'] = (Join-Path $lad 'claude-notifier')
            $psi.EnvironmentVariables['USERNAME'] = 'cn-sl-' + [guid]::NewGuid().ToString('N')
            $p = [System.Diagnostics.Process]::Start($psi)
            $b = (New-Object System.Text.UTF8Encoding $false).GetBytes($case.In)
            $p.StandardInput.BaseStream.Write($b, 0, $b.Length)
            $p.StandardInput.Close()
            $out = $p.StandardOutput.ReadToEnd()
            $p.WaitForExit()
            $p.ExitCode | Should Be 0
            $out.TrimEnd("`r", "`n") | Should Be $case.Out
        }
    }
}

Describe 's_004_02 · statusLine в установщике' {
    function New-Env {
        $id = [guid]::NewGuid().ToString('N')
        $h = Join-Path $TestDrive "home-$id"
        New-Item -ItemType Directory -Path (Join-Path $h '.claude') -Force | Out-Null
        return @{ Settings = Join-Path $h '.claude\settings.json'; Data = Join-Path $TestDrive "data-$id\claude-notifier"; Classes = Join-Path $classesBase $id }
    }
    function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }

    It 'install без прежнего statusLine → наш; uninstall удаляет ключ' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        $sl = (Read-Json $e.Settings).statusLine
        $sl.type | Should Be 'command'
        $sl.command | Should Be ((Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe').Replace('\', '/') + ' -NoProfile -NonInteractive -File "' + (Join-Path $e.Data 'app\statusline.ps1').Replace('\', '/') + '"')
        Test-Path (Join-Path $e.Data 'config.json') | Should Be $false
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        $null -eq (Read-Json $e.Settings).PSObject.Properties['statusLine'] | Should Be $true
    }

    It 'прежний statusLine → в config.json (chainStatusLine); повторная установка его не теряет; uninstall восстанавливает' {
        $e = New-Env
        '{ "statusLine": { "type": "command", "command": "~/.claude/my.sh", "padding": 1 }, "model": "opus" }' | Set-Content $e.Settings -Encoding UTF8
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        $cfg = Read-Json (Join-Path $e.Data 'config.json')
        $cfg.chainStatusLine.command | Should Be '~/.claude/my.sh'
        Test-NotifierStatusLine (Read-Json $e.Settings).statusLine | Should Be $true

        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        (Read-Json (Join-Path $e.Data 'config.json')).chainStatusLine.command | Should Be '~/.claude/my.sh'

        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        $s = Read-Json $e.Settings
        $s.statusLine.command | Should Be '~/.claude/my.sh'
        $s.statusLine.padding | Should Be 1
        $s.model | Should Be 'opus'
        $null -eq (Read-Json (Join-Path $e.Data 'config.json')).PSObject.Properties['chainStatusLine'] | Should Be $true
    }

    It 'config.json пользователя сохраняется при записи chainStatusLine' {
        $e = New-Env
        New-Item -ItemType Directory -Path $e.Data -Force | Out-Null
        '{ "previewLength": 120 }' | Set-Content (Join-Path $e.Data 'config.json') -Encoding UTF8
        '{ "statusLine": { "type": "command", "command": "old" } }' | Set-Content $e.Settings -Encoding UTF8
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
        $cfg = Read-Json (Join-Path $e.Data 'config.json')
        $cfg.previewLength | Should Be 120
        $cfg.chainStatusLine.command | Should Be 'old'
    }

    It 'битый config.json при прежнем statusLine → установка прерывается, settings.json не тронут' {
        $e = New-Env
        New-Item -ItemType Directory -Path $e.Data -Force | Out-Null
        Set-Content (Join-Path $e.Data 'config.json') '{ broken'
        $orig = '{ "statusLine": { "type": "command", "command": "old" } }'
        [IO.File]::WriteAllText($e.Settings, $orig)
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') -ErrorAction SilentlyContinue 2>$null | Out-Null
        $LASTEXITCODE | Should Be 1
        [IO.File]::ReadAllText($e.Settings) | Should Be $orig
    }

    It 'чужой statusLine при uninstall не трогается' {
        $s = '{ "statusLine": { "type": "command", "command": "theirs" } }' | ConvertFrom-Json
        Restore-NotifierStatusLine -Settings $s -Previous $null | Should Be $false
        $s.statusLine.command | Should Be 'theirs'
    }
}

Describe 's_004_02 · config chainStatusLine' {
    It 'неверный chainStatusLine → игнорируется с WARN' {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
        $root = Join-Path $TestDrive 'badchain'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "chainStatusLine": { "command": 5 } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        (Get-NotifierConfig -DataRoot $root).chainStatusLine | Should Be $null
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match "\[WARN\] config\.json: 'chainStatusLine'"
    }

    It 'Set-NotifierConfigValue: нет файла и значение null → файл не создаётся' {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
        $root = Join-Path $TestDrive 'nofile'
        Set-NotifierConfigValue -Name chainStatusLine -Value $null -DataRoot $root
        Test-Path (Join-Path $root 'config.json') | Should Be $false
    }

    It 'Set-NotifierConfigValue: JSON-массив в config.json → исключение' {
        Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
        $root = Join-Path $TestDrive 'arr'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content (Join-Path $root 'config.json') '[1]'
        { Set-NotifierConfigValue -Name x -Value 1 -DataRoot $root } | Should Throw
    }
}

Describe 's_004_02 · уборка' {
    It 'тестовые ключи реестра удалены' {
        if (Test-Path $classesBase) { Remove-Item $classesBase -Recurse -Force }
        Test-Path $classesBase | Should Be $false
    }
}
