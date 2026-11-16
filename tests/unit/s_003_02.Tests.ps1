$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Registration.psm1') -Force
$handler = Join-Path $repoRoot 'src\focus-handler.ps1'
. $handler

$id1 = '11111111-2222-3333-4444-555555555555'
$id2 = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee'

function New-History([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $json = @"
[
  { "v": 1, "id": "$id1", "type": "done", "project": "p1", "title": "Готово · p1", "preview": "x", "window": { "hwnd": 4242, "pid": 7 } },
  { "v": 1, "id": "$id2", "type": "error", "project": "p2", "title": "Ошибка · p2", "preview": "y", "window": null }
]
"@
    [IO.File]::WriteAllText((Join-Path $Root 'history.json'), $json, (New-Object Text.UTF8Encoding $false))
}

function Read-History([string]$Root) {
    $items = @()
    foreach ($x in (ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $Root 'history.json'), [Text.Encoding]::UTF8)))) { $items += $x }
    return , $items
}

Describe 's_003_02 · ConvertFrom-NotifierUri' {
    It 'принимает "<Uri>"' -TestCases @(
        @{ Uri = "claude-notifier:focus?id=$id1" },
        @{ Uri = "CLAUDE-NOTIFIER:focus?id=$id1" },
        @{ Uri = "claude-notifier:focus?id=$id1/" }
    ) {
        param($Uri)
        ConvertFrom-NotifierUri $Uri | Should Be $id1
    }

    It 'отклоняет "<Uri>"' -TestCases @(
        @{ Uri = 'claude-notifier:evil?id=../../x' },
        @{ Uri = 'claude-notifier:focus?id=../../x' },
        @{ Uri = "claude-notifier:focus?id=$id1&x=1" },
        @{ Uri = "https://example.com/?id=$id1" },
        @{ Uri = 'claude-notifier:focus?id=not-a-guid' },
        @{ Uri = '' }
    ) {
        param($Uri)
        ConvertFrom-NotifierUri $Uri | Should Be $null
    }
}

Describe 's_003_02 · Invoke-NotifierFocus' {
    It 'известный id → Set-SessionWindowFocus с hwnd события' {
        $root = Join-Path $TestDrive 'known'
        New-History $root
        Mock Set-SessionWindowFocus { 'focused' }
        Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id1" -DataRoot $root | Should Be 'focused'
        Assert-MockCalled Set-SessionWindowFocus -Scope It -Times 1 -Exactly -ParameterFilter { $Hwnd -eq 4242 }
    }

    It 'closed → событие помечается status=closed, остальные не меняются' {
        $root = Join-Path $TestDrive 'closed'
        New-History $root
        Mock Set-SessionWindowFocus { 'closed' }
        Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id1" -DataRoot $root | Should Be 'closed'
        $h = Read-History $root
        $h.Count | Should Be 2
        $h[0].status | Should Be 'closed'
        $null -eq $h[1].PSObject.Properties['status'] | Should Be $true
        $h[0].title | Should Be 'Готово · p1'
    }

    It 'событие без окна → closed без вызова фокуса' {
        $root = Join-Path $TestDrive 'nowindow'
        New-History $root
        Mock Set-SessionWindowFocus { 'focused' }
        Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id2" -DataRoot $root | Should Be 'closed'
        Assert-MockCalled Set-SessionWindowFocus -Scope It -Times 0
        (Read-History $root)[1].status | Should Be 'closed'
    }

    It '<Case> → <Result>, INFO в лог, фокус не вызывается' -TestCases @(
        @{ Case = 'чужая команда'; Uri = 'claude-notifier:evil?id=../../x'; Result = 'invalid'; History = $true },
        @{ Case = 'неизвестный id'; Uri = 'claude-notifier:focus?id=99999999-9999-9999-9999-999999999999'; Result = 'not-found'; History = $true },
        @{ Case = 'нет history.json'; Uri = "claude-notifier:focus?id=$id1"; Result = 'not-found'; History = $false }
    ) {
        param($Case, $Uri, $Result, $History)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        if ($History) { New-History $root }
        Mock Set-SessionWindowFocus { 'focused' }
        Invoke-NotifierFocus -Uri $Uri -DataRoot $root | Should Be $Result
        Assert-MockCalled Set-SessionWindowFocus -Scope It -Times 0
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[INFO\] focus:'
    }

    It 'битый history.json → not-found, файл переименован в .corrupt (History.psm1, s_005_02)' {
        $root = Join-Path $TestDrive 'broken'
        New-Item -ItemType Directory -Path $root | Out-Null
        Set-Content (Join-Path $root 'history.json') '{ broken'
        Mock Set-SessionWindowFocus { 'focused' }
        Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id1" -DataRoot $root | Should Be 'not-found'
        Assert-MockCalled Set-SessionWindowFocus -Scope It -Times 0
        (Get-Content (Join-Path $root 'history.json.corrupt') -Raw).Trim() | Should Be '{ broken'
    }

    It 'история из одного события остаётся массивом после записи' {
        $root = Join-Path $TestDrive 'single'
        New-Item -ItemType Directory -Path $root | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'history.json'), "[ { `"id`": `"$id1`", `"window`": { `"hwnd`": 1 } } ]")
        Mock Set-SessionWindowFocus { 'closed' }
        [void](Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id1" -DataRoot $root)
        ([IO.File]::ReadAllText((Join-Path $root 'history.json'))).TrimStart()[0] | Should Be '['
    }

    It 'исключение внутри → failed и ERROR, без исключения наружу' {
        $root = Join-Path $TestDrive 'boom'
        New-History $root
        Mock Set-SessionWindowFocus { throw 'boom' }
        Invoke-NotifierFocus -Uri "claude-notifier:focus?id=$id1" -DataRoot $root | Should Be 'failed'
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] focus: .*boom'
    }
}

Describe 's_003_02 · регистрация URL-протокола' {
    $classes = 'HKCU:\Software\claude-notifier-tests-' + [guid]::NewGuid().ToString('N')

    It 'Register создаёт ключ протокола с командой conhost --headless' {
        try {
            Register-NotifierProtocol -AppRoot 'C:\Users\u\AppData\Local\claude-notifier\app' -ClassesRoot $classes -Name 'claude-notifier'
            $key = Join-Path $classes 'claude-notifier'
            (Get-ItemProperty $key).'URL Protocol' | Should Be ''
            (Get-ItemProperty $key).'(default)' | Should Be 'URL:Claude Notifier'
            $cmd = (Get-ItemProperty (Join-Path $key 'shell\open\command')).'(default)'
            $cmd | Should BeLike '"*\System32\conhost.exe" --headless "*\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -WindowStyle Hidden -File "C:\Users\u\AppData\Local\claude-notifier\app\focus-handler.ps1" "%1"'
        }
        finally { Remove-Item $classes -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'повторный Register перезаписывает, Unregister удаляет ключ' {
        try {
            Register-NotifierProtocol -AppRoot 'C:\a' -ClassesRoot $classes -Name 'claude-notifier'
            Register-NotifierProtocol -AppRoot 'C:\b' -ClassesRoot $classes -Name 'claude-notifier'
            (Get-ItemProperty (Join-Path $classes 'claude-notifier\shell\open\command')).'(default)' | Should BeLike '*"C:\b\focus-handler.ps1"*'
            Unregister-NotifierProtocol -ClassesRoot $classes -Name 'claude-notifier' | Should Be $true
            Test-Path (Join-Path $classes 'claude-notifier') | Should Be $false
            Unregister-NotifierProtocol -ClassesRoot $classes -Name 'claude-notifier' | Should Be $false
        }
        finally { Remove-Item $classes -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 's_003_02 · focus-handler.ps1 как процесс' {
    It 'мусорный URI → код выхода 0, пустой stdout' {
        $lad = Join-Path $TestDrive 'lad'
        New-Item -ItemType Directory -Path $lad | Out-Null
        $psi = New-Object System.Diagnostics.ProcessStartInfo (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'), "-NoProfile -NonInteractive -File `"$handler`" `"claude-notifier:evil?id=../../x`""
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.EnvironmentVariables['LOCALAPPDATA'] = $lad
        $psi.EnvironmentVariables['CLAUDE_NOTIFIER_HOME'] = (Join-Path $lad 'claude-notifier')
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        $p.WaitForExit()
        $p.ExitCode | Should Be 0
        $out | Should Be ''
        (Get-Content (Join-Path $lad 'claude-notifier\log.txt') -Raw -Encoding UTF8) | Should Match '\[INFO\] focus:'
    }
}
