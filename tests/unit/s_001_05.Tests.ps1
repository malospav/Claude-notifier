$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Settings.psm1') -Force
$install = Join-Path $repoRoot 'install.ps1'
$uninstall = Join-Path $repoRoot 'uninstall.ps1'
# Ключи реестра тестов — отдельная ветка HKCU, не настоящий HKCU:\Software\Classes. Удаляется в конце файла.
$classesBase = 'HKCU:\Software\claude-notifier-tests-' + [guid]::NewGuid().ToString('N')

function New-Env {
    # Изолированная среда: свой settings.json и свой каталог данных в TestDrive.
    $id = [guid]::NewGuid().ToString('N')
    $home_ = Join-Path $TestDrive "home-$id"
    New-Item -ItemType Directory -Path (Join-Path $home_ '.claude') -Force | Out-Null
    return @{
        Settings = Join-Path $home_ '.claude\settings.json'
        Classes  = Join-Path $classesBase $id
        Data     = Join-Path $TestDrive "data-$id\claude-notifier"   # как в реальности: ...\claude-notifier\app
    }
}

function Read-Json([string]$Path) { [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json }

function Get-OurHooks($Settings) {
    # Все hook-объекты claude-notifier по событиям: @{ Stop = n; ... }
    $r = @{}
    if ($null -eq $Settings.PSObject.Properties['hooks']) { return $r }
    foreach ($ev in $Settings.hooks.PSObject.Properties) {
        foreach ($group in @($ev.Value)) {
            foreach ($h in @($group.hooks)) {
                if ((@($h.args) -join ' ') -like '*claude-notifier\app\hook-bridge.ps1*') { $r[$ev.Name] = 1 + [int]$r[$ev.Name] }
            }
        }
    }
    return $r
}

$foreign = @'
{
  "model": "opus",
  "permissions": { "allow": ["Bash(git status)"] },
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "C:\\my\\stop.cmd" } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "C:\\my\\guard.cmd" } ] } ]
  }
}
'@

Describe 's_001_05 · install.ps1' {
    It 'нет settings.json → файл создаётся с 3 хуками, src скопирован в app\' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        $s = Read-Json $e.Settings
        $ours = Get-OurHooks $s
        $ours['Stop'] | Should Be 1
        $ours['Notification'] | Should Be 1
        $ours['StopFailure'] | Should Be 1
        @(Get-ChildItem (Split-Path $e.Settings) -Filter 'settings.json.bak-*').Count | Should Be 0
        Test-Path (Join-Path $e.Data 'app\hook-bridge.ps1') | Should Be $true
        Test-Path (Join-Path $e.Data 'app\lib\Settings.psm1') | Should Be $true
    }

    It 'хук записан по контракту архитектуры §4' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $s = Read-Json $e.Settings
        $n = @($s.hooks.Notification)[0]
        $n.matcher | Should Be 'permission_prompt|elicitation_dialog|agent_needs_input'
        $h = @($n.hooks)[0]
        $h.type | Should Be 'command'
        $h.command | Should BeLike '*\WindowsPowerShell\v1.0\powershell.exe'
        $h.async | Should Be $true
        ($h.args -join ' ') | Should Be ("-NoProfile -NonInteractive -File " + (Join-Path $e.Data 'app\hook-bridge.ps1') + " notification")
        (@(@($s.hooks.Stop)[0].hooks)[0].args)[-1] | Should Be 'stop'
        (@(@($s.hooks.StopFailure)[0].hooks)[0].args)[-1] | Should Be 'stopfailure'
        $null -eq @($s.hooks.Stop)[0].PSObject.Properties['matcher'] | Should Be $true
    }

    It 'чужие хуки и ключи сохраняются; делается резервная копия' {
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $foreign, (New-Object Text.UTF8Encoding $false))
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $s = Read-Json $e.Settings
        $s.model | Should Be 'opus'
        $s.permissions.allow[0] | Should Be 'Bash(git status)'
        @($s.hooks.Stop).Count | Should Be 2
        (@($s.hooks.Stop)[0].hooks)[0].command | Should Be 'C:\my\stop.cmd'
        @($s.hooks.PreToolUse)[0].matcher | Should Be 'Bash'
        $bak = @(Get-ChildItem (Split-Path $e.Settings) -Filter 'settings.json.bak-*')
        $bak.Count | Should Be 1
        $bak[0].Name | Should Match '^settings\.json\.bak-\d{14}$'
        [IO.File]::ReadAllText($bak[0].FullName) | Should Be $foreign
    }

    It 'повторная установка не создаёт дублей' {
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $foreign, (New-Object Text.UTF8Encoding $false))
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $s = Read-Json $e.Settings
        $ours = Get-OurHooks $s
        ($ours.Values | Measure-Object -Sum).Sum | Should Be 3
        @($s.hooks.Stop).Count | Should Be 2
    }

    It 'install → uninstall возвращает чужие настройки семантически без изменений' {
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $foreign, (New-Object Text.UTF8Encoding $false))
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $after = Read-Json $e.Settings | ConvertTo-Json -Depth 20 -Compress
        $before = $foreign | ConvertFrom-Json | ConvertTo-Json -Depth 20 -Compress
        $after | Should Be $before
    }

    It '<Case> → ошибка, файл не тронут, app не создан' -TestCases @(
        @{ Case = 'битый JSON'; Content = '{ "hooks": ' },
        @{ Case = 'JSON-массив'; Content = '[1, 2]' },
        @{ Case = 'hooks не объект'; Content = '{ "hooks": [] }' },
        @{ Case = 'событие не массив'; Content = '{ "hooks": { "Stop": {} } }' }
    ) {
        param($Case, $Content)
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $Content, (New-Object Text.UTF8Encoding $false))
        $err = $null
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -ErrorVariable err -ErrorAction SilentlyContinue 2>$null | Out-Null
        $LASTEXITCODE | Should Be 1
        ($err | Out-String) | Should Match 'settings\.json'
        [IO.File]::ReadAllText($e.Settings) | Should Be $Content
        Test-Path (Join-Path $e.Data 'app') | Should Be $false
        @(Get-ChildItem (Split-Path $e.Settings) -Filter 'settings.json.bak-*').Count | Should Be 0
    }

    It 'перезаписывает app\ и удаляет устаревшие файлы' {
        $e = New-Env
        New-Item -ItemType Directory -Path (Join-Path $e.Data 'app') -Force | Out-Null
        Set-Content (Join-Path $e.Data 'app\stale.ps1') 'old'
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        Test-Path (Join-Path $e.Data 'app\stale.ps1') | Should Be $false
        Test-Path (Join-Path $e.Data 'app\hook-bridge.ps1') | Should Be $true
    }
}

Describe 's_001_05 · запуск через powershell -File (как в README)' {
    It 'install.ps1 и uninstall.ps1 работают при запуске через -File (регрессия: $PSScriptRoot в параметрах)' {
        $e = New-Env
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        Test-Path (Join-Path $e.Data 'app\hook-bridge.ps1') | Should Be $true
        & $ps -NoProfile -ExecutionPolicy Bypass -File $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        Test-Path (Join-Path $e.Data 'app') | Should Be $false
    }
}

Describe 's_001_05 · uninstall.ps1' {
    It 'удаляет только свои записи и app\; config.json и history.json остаются' {
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $foreign, (New-Object Text.UTF8Encoding $false))
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        Set-Content (Join-Path $e.Data 'config.json') '{}'
        Set-Content (Join-Path $e.Data 'history.json') '[]'
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        $s = Read-Json $e.Settings
        (Get-OurHooks $s).Count | Should Be 0
        @($s.hooks.Stop).Count | Should Be 1
        $null -eq $s.hooks.PSObject.Properties['Notification'] | Should Be $true
        Test-Path (Join-Path $e.Data 'app') | Should Be $false
        Test-Path (Join-Path $e.Data 'config.json') | Should Be $true
        Test-Path (Join-Path $e.Data 'history.json') | Should Be $true
    }

    It '-Purge удаляет весь каталог данных' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        Set-Content (Join-Path $e.Data 'config.json') '{}'
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -Purge | Out-Null
        Test-Path $e.Data | Should Be $false
    }

    It 'только наши хуки → секция hooks удаляется целиком' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $s = Read-Json $e.Settings
        $null -eq $s.PSObject.Properties['hooks'] | Should Be $true
    }

    It 'нечего удалять → settings.json не перезаписывается и без резервной копии' {
        $e = New-Env
        [IO.File]::WriteAllText($e.Settings, $foreign, (New-Object Text.UTF8Encoding $false))
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        [IO.File]::ReadAllText($e.Settings) | Should Be $foreign
        @(Get-ChildItem (Split-Path $e.Settings) -Filter 'settings.json.bak-*').Count | Should Be 0
    }

    It 'нет settings.json → без ошибки' {
        $e = New-Env
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $LASTEXITCODE | Should Be 0
        Test-Path $e.Settings | Should Be $false
    }

    It 'битый settings.json → ошибка, ничего не удалено' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        [IO.File]::WriteAllText($e.Settings, '{ broken', (New-Object Text.UTF8Encoding $false))
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes -ErrorAction SilentlyContinue 2>$null | Out-Null
        $LASTEXITCODE | Should Be 1
        Test-Path (Join-Path $e.Data 'app') | Should Be $true
    }
}

Describe 's_001_05 · URL-протокол в установщике (s_003_02)' {
    It 'install регистрирует протокол, uninstall удаляет' {
        $e = New-Env
        & $install -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        $cmd = (Get-ItemProperty (Join-Path $e.Classes 'claude-notifier\shell\open\command')).'(default)'
        $cmd | Should BeLike ('*"' + (Join-Path $e.Data 'app\focus-handler.ps1') + '" "%1"')
        & $uninstall -SettingsPath $e.Settings -DataRoot $e.Data -ClassesRoot $e.Classes | Out-Null
        Test-Path (Join-Path $e.Classes 'claude-notifier') | Should Be $false
    }
}

Describe 's_001_05 · Settings.psm1' {
    It 'ConvertTo-PrettyJson: отступ 2 пробела, строки со скобками и кавычками не ломаются' {
        $obj = '{"a":{"b":[1,2],"c":"x{y}[z],\"q\"","e":[],"f":{}}}' | ConvertFrom-Json
        $pretty = ConvertTo-PrettyJson $obj
        $pretty | Should Be ("{`n  `"a`": {`n    `"b`": [`n      1,`n      2`n    ],`n    `"c`": `"x{y}[z],\`"q\`"`",`n    `"e`": [],`n    `"f`": {}`n  }`n}").Replace("`n", [Environment]::NewLine)
        ($pretty | ConvertFrom-Json).a.c | Should Be 'x{y}[z],"q"'
    }

    It 'Test-NotifierHook распознаёт только свои записи' {
        $ours = [pscustomobject]@{ type = 'command'; command = 'powershell.exe'; args = @('-File', 'C:\Users\u\AppData\Local\claude-notifier\app\hook-bridge.ps1', 'stop') }
        $theirs = [pscustomobject]@{ type = 'command'; command = 'C:\claude-notifier\app\x.cmd' }
        Test-NotifierHook $ours | Should Be $true
        Test-NotifierHook $theirs | Should Be $false
        Test-NotifierHook 'string' | Should Be $false
    }
}

Describe 's_001_05 · уборка' {
    It 'тестовые ключи реестра удалены' {
        if (Test-Path $classesBase) { Remove-Item $classesBase -Recurse -Force }
        Test-Path $classesBase | Should Be $false
    }
}
