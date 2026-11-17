$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Sessions.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Event.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Settings.psm1') -Force
$tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
. $tray
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function New-SEv([string]$Type, [string]$Sid = 's1', [string]$Ts = '2026-11-16T12:00:00.000Z', [string]$Preview = '', [int64]$Hwnd = 0, [int]$ProcId = 0) {
    return [pscustomobject]@{
        v = 1; id = [guid]::NewGuid().ToString(); ts = $Ts; type = $Type; session_id = $Sid
        origin = 'desktop'; project = 'proj'; title = 't'; preview = $Preview
        window = [pscustomobject]@{ hwnd = $Hwnd; pid = $ProcId }
    }
}

function Get-One([object[]]$List, [string]$Sid) { return @($List | Where-Object { $_.session_id -eq $Sid })[0] }

Describe 's_006_01 · Update-NotifierSessionList' {
    It 'start → новый сеанс «waiting»' {
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv start)
        $l.Count | Should Be 1
        $l[0].state | Should Be 'waiting'
        $l[0].project | Should Be 'proj'
        $l[0].origin | Should Be 'desktop'
    }

    It 'цепочка working → permission → done: статус, since и превью' {
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv working -Ts '2026-11-16T12:00:00.000Z')
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv working -Ts '2026-11-16T12:01:00.000Z')
        (Get-One $l 's1').since | Should Be '2026-11-16T12:00:00.000Z'   # статус не сменился → since прежний
        (Get-One $l 's1').updated | Should Be '2026-11-16T12:01:00.000Z'
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv permission -Ts '2026-11-16T12:02:00.000Z' -Preview 'Разрешить Bash?')
        (Get-One $l 's1').state | Should Be 'permission'
        (Get-One $l 's1').since | Should Be '2026-11-16T12:02:00.000Z'
        (Get-One $l 's1').preview | Should Be ''   # превью — только последнего ответа (done)
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv done -Ts '2026-11-16T12:03:00.000Z' -Preview 'Готово, тесты прошли')
        (Get-One $l 's1').state | Should Be 'waiting'
        (Get-One $l 's1').preview | Should Be 'Готово, тесты прошли'
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv working -Ts '2026-11-16T12:04:00.000Z')
        (Get-One $l 's1').preview | Should Be 'Готово, тесты прошли'   # прежний ответ виден, пока Claude работает
        $l.Count | Should Be 1
    }

    It 'error → «error»; end → сеанс удаляется, другие остаются' {
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv start -Sid a)
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv start -Sid b)
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv error -Sid a)
        (Get-One $l 'a').state | Should Be 'error'
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv end -Sid a)
        @($l).Count | Should Be 1
        $l[0].session_id | Should Be 'b'
    }

    It 'окно запоминается и не затирается событием без окна' {
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv start -Hwnd 4242 -ProcId 77)
        $l = Update-NotifierSessionList -Sessions $l -Event (New-SEv done -Hwnd 0)
        $l[0].window.hwnd | Should Be 4242
        $l[0].window.pid | Should Be 77
    }

    It '<Case> → список не меняется' -TestCases @(
        @{ Case = 'нет session_id'; Ev = [pscustomobject]@{ type = 'done'; ts = '2026-11-16T12:00:00Z' } },
        @{ Case = 'пустой session_id'; Ev = [pscustomobject]@{ type = 'done'; session_id = '' } },
        @{ Case = 'limit'; Ev = [pscustomobject]@{ type = 'limit'; session_id = 's9' } }
    ) {
        param($Case, $Ev)
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv start -Sid keep)
        $r = Update-NotifierSessionList -Sessions $l -Event $Ev
        @($r).Count | Should Be 1
        $r[0].session_id | Should Be 'keep'
    }
}

Describe 's_006_01 · sessions.json' {
    It 'запись и чтение; пустой список; повреждённый файл удаляется с WARN' {
        $root = Join-Path $TestDrive 'store'
        @(Get-NotifierSessions -DataRoot $root).Count | Should Be 0
        $l = Update-NotifierSessionList -Sessions @() -Event (New-SEv start -Sid x)
        Save-NotifierSessions -Sessions $l -DataRoot $root
        $r = @(Get-NotifierSessions -DataRoot $root)
        $r.Count | Should Be 1
        $r[0].session_id | Should Be 'x'
        Save-NotifierSessions -Sessions @() -DataRoot $root
        @(Get-NotifierSessions -DataRoot $root).Count | Should Be 0
        [IO.File]::WriteAllText((Join-Path $root 'sessions.json'), '{oops', [Text.Encoding]::UTF8)
        @(Get-NotifierSessions -DataRoot $root).Count | Should Be 0
        Test-Path (Join-Path $root 'sessions.json') | Should Be $false
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[WARN\] sessions:'
    }
}

Describe 's_006_01 · живые сеансы' {
    $now = [datetime]::Parse('2026-11-16T12:00:00Z').ToUniversalTime()
    It 'старше 24 ч → убирается; без окна → остаётся' {
        $fresh = [pscustomobject]@{ session_id = 'f'; updated = '2026-11-16T11:00:00Z'; window = $null }
        $old = [pscustomobject]@{ session_id = 'o'; updated = '2026-11-15T11:00:00Z'; window = $null }
        $r = Select-NotifierLiveSessions -Sessions @($fresh, $old) -Now $now
        @($r).Count | Should Be 1
        $r[0].session_id | Should Be 'f'
    }

    It 'процесс claude завершён → сеанс закрыт' {
        $s = [pscustomobject]@{ session_id = 'p'; updated = '2026-11-16T11:59:00Z'; window = [pscustomobject]@{ hwnd = 0; pid = 999999 } }
        Test-NotifierSessionAlive -Session $s | Should Be $false
    }

    It 'pid занят процессом не claude → сеанс закрыт' {
        $s = [pscustomobject]@{ session_id = 'p'; window = [pscustomobject]@{ hwnd = 0; pid = $PID } }
        Test-NotifierSessionAlive -Session $s | Should Be $false
    }

    It 'окно закрыто → сеанс закрыт; окно есть → жив' {
        Mock -ModuleName Sessions Test-SessionWindow { $false }
        Test-NotifierSessionAlive -Session ([pscustomobject]@{ window = [pscustomobject]@{ hwnd = 123; pid = 0 } }) | Should Be $false
    }

    It 'окно есть → жив' {
        Mock -ModuleName Sessions Test-SessionWindow { $true }
        Test-NotifierSessionAlive -Session ([pscustomobject]@{ window = [pscustomobject]@{ hwnd = 123; pid = 0 } }) | Should Be $true
    }
}

Describe 's_006_01 · порядок и форматирование' {
    It 'сначала разрешение и ошибка, потом ждут ответа, потом работают; внутри — новые выше' {
        $list = @(
            [pscustomobject]@{ session_id = 'w'; state = 'working'; updated = '2026-11-16T12:05:00Z' },
            [pscustomobject]@{ session_id = 'd1'; state = 'waiting'; updated = '2026-11-16T12:01:00Z' },
            [pscustomobject]@{ session_id = 'd2'; state = 'waiting'; updated = '2026-11-16T12:02:00Z' },
            [pscustomobject]@{ session_id = 'e'; state = 'error'; updated = '2026-11-16T12:00:00Z' },
            [pscustomobject]@{ session_id = 'p'; state = 'permission'; updated = '2026-11-16T11:00:00Z' }
        )
        ((Get-NotifierSortedSessions -Sessions $list) | ForEach-Object { $_.session_id }) -join ',' | Should Be 'p,e,d2,d1,w'
    }

    It 'Format-NotifierElapsed: <Ts> → <Text>' -TestCases @(
        @{ Ts = '2026-11-16T11:59:30Z'; Text = 'только что' },
        @{ Ts = '2026-11-16T11:55:00Z'; Text = '5 мин' },
        @{ Ts = '2026-11-16T09:55:00Z'; Text = '2 ч 05 мин' },
        @{ Ts = '2026-11-13T12:00:00Z'; Text = '3 дн' },
        @{ Ts = 'мусор'; Text = '' }
    ) {
        param($Ts, $Text)
        Format-NotifierElapsed -Ts $Ts -Now ([datetime]::Parse('2026-11-16T12:00:00Z').ToUniversalTime()) | Should Be $Text
    }

    It 'названия статусов по-русски' {
        Get-NotifierSessionStateText working | Should Be 'Работает'
        Get-NotifierSessionStateText waiting | Should Be 'Ждёт ответа'
        Get-NotifierSessionStateText permission | Should Be 'Нужно разрешение'
        Get-NotifierSessionStateText error | Should Be 'Ошибка'
        Get-NotifierSessionStateText other | Should Be 'other'
    }
}

Describe 's_006_01 · новые хуки' {
    It '<Kind> → тип <Type>, превью пустое (текст запроса не передаётся)' -TestCases @(
        @{ Kind = 'sessionstart'; Type = 'start' },
        @{ Kind = 'prompt'; Type = 'working' },
        @{ Kind = 'sessionend'; Type = 'end' }
    ) {
        param($Kind, $Type)
        $json = '{"session_id":"abc","cwd":"C:\\dev\\proj","prompt":"секретный запрос","reason":"exit"}'
        $e = ConvertTo-NotifierEvent -HookKind $Kind -Json $json -EntryPoint 'claude-desktop' -HostSessionId '' -Config (Get-NotifierDefaultConfig) -DataRoot $TestDrive
        $e.type | Should Be $Type
        $e.session_id | Should Be 'abc'
        $e.preview | Should Be ''
        $e.title | Should Be "Сеанс $([char]0x00B7) proj"
    }

    It 'установщик ставит 8 хуков: уведомления, сеансы, запрос разрешения (синхронный), быстрый ответ (asyncRewake)' {
        $s = [pscustomobject]@{}
        Add-NotifierHooks -Settings $s -AppRoot 'C:\x\claude-notifier\app'
        @($s.hooks.PSObject.Properties).Count | Should Be 7
        (@(@($s.hooks.SessionStart)[0].hooks)[0].args)[-1] | Should Be 'sessionstart'
        (@(@($s.hooks.UserPromptSubmit)[0].hooks)[0].args)[-1] | Should Be 'prompt'
        (@(@($s.hooks.SessionEnd)[0].hooks)[0].args)[-1] | Should Be 'sessionend'
        @(@($s.hooks.UserPromptSubmit)[0].hooks)[0].async | Should Be $true
        $perm = @(@($s.hooks.PermissionRequest)[0].hooks)[0]
        $perm.args[-1] | Should Be 'permreq'
        $null -eq $perm.PSObject.Properties['async'] | Should Be $true   # синхронный: Claude ждёт решения
        $perm.timeout | Should Be 3700
        $rewake = @(@($s.hooks.Stop)[1].hooks)[0]
        $rewake.args[-1] | Should Be 'replywait'
        $rewake.asyncRewake | Should Be $true
        Remove-NotifierHooks -Settings $s | Should Be 8
    }
}

Describe 's_006_01 · трей: события → sessions.json' {
    It 'служебные события не показываются и не пишутся в историю, но меняют статус сеанса' {
        $root = Join-Path $TestDrive 'tray'
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        foreach ($e in @((New-SEv start -Sid a), (New-SEv working -Sid a), (New-SEv start -Sid b), (New-SEv end -Sid b))) { $q.Enqueue($e) }
        Invoke-NotifierEventBatch -Queue $q -DataRoot $root | Out-Null
        Assert-MockCalled Show-NotifierToast -Times 0 -Scope It
        Test-Path (Join-Path $root 'history.json') | Should Be $false
        $s = @(Get-NotifierSessions -DataRoot $root)
        $s.Count | Should Be 1
        $s[0].state | Should Be 'working'
    }

    It 'done показывается, пишется в историю и переводит сеанс в «waiting» даже при выключенном типе' {
        $root = Join-Path $TestDrive 'tray2'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"events":{"permission":{"enabled":false}}}', [Text.Encoding]::UTF8)
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue((New-SEv done -Sid a -Preview 'ответ'))
        $q.Enqueue((New-SEv permission -Sid b))
        Invoke-NotifierEventBatch -Queue $q -DataRoot $root | Should Be 1
        Assert-MockCalled Show-NotifierToast -Times 1 -Scope It
        $s = @(Get-NotifierSessions -DataRoot $root)
        (Get-One $s 'a').preview | Should Be 'ответ'
        (Get-One $s 'b').state | Should Be 'permission'
    }

    It 'новые типы проходят проверку формы' {
        Test-NotifierEventShape ([pscustomobject]@{ type = 'working'; title = 't' }) | Should Be $true
        Test-NotifierEventShape ([pscustomobject]@{ type = 'end'; title = 't' }) | Should Be $true
    }
}
