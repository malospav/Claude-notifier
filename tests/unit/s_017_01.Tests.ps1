BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
}

Describe 's_017_01 · обновление с GitHub (ПК) и самообновление хуков Mac' {
    It 'version.json, адрес репозитория, ответ compare API' {
        $app = Join-Path $TestDrive 'app'
        New-Item -ItemType Directory $app -Force | Out-Null
        Get-NotifierInstalledVersion -AppRoot $app | Should -Be $null
        $sha = 'a' * 40
        [IO.File]::WriteAllText((Join-Path $app 'version.json'), "{`"commit`":`"$sha`",`"repo`":`"malospav/Claude-notifier`",`"installed`":`"x`"}")
        $v = Get-NotifierInstalledVersion -AppRoot $app
        $v.Commit | Should -Be $sha; $v.Repo | Should -Be 'malospav/Claude-notifier'
        [IO.File]::WriteAllText((Join-Path $app 'version.json'), '{"commit":"xyz","repo":"a/b"}')
        Get-NotifierInstalledVersion -AppRoot $app | Should -Be $null
        ConvertTo-NotifierRepo 'https://github.com/malospav/Claude-notifier.git' | Should -Be 'malospav/Claude-notifier'
        ConvertTo-NotifierRepo 'git@github.com:o/r.git' | Should -Be 'o/r'
        ConvertTo-NotifierRepo 'https://gitlab.com/o/r' | Should -Be ''
        $new = 'b' * 40
        $r = ConvertFrom-NotifierCompare -Json "{`"status`":`"ahead`",`"ahead_by`":3,`"commits`":[{`"sha`":`"$('c' * 40)`",`"commit`":{`"message`":`"old`"}},{`"sha`":`"$new`",`"commit`":{`"message`":`"feat: новое\n\nтело`"}}]}"
        $r.Available | Should -Be $true; $r.Sha | Should -Be $new; $r.Count | Should -Be 3; $r.Message | Should -Be 'feat: новое'
        (ConvertFrom-NotifierCompare -Json '{"status":"identical","ahead_by":0,"commits":[]}').Available | Should -Be $false
        # Локальные коммиты впереди GitHub (разработка) — не «обновление» назад.
        (ConvertFrom-NotifierCompare -Json '{"status":"behind","ahead_by":0,"behind_by":2,"commits":[]}').Available | Should -Be $false
        (ConvertFrom-NotifierCompare -Json '{"status":"diverged","ahead_by":1,"commits":[{"sha":"x"}]}').Available | Should -Be $false
    }

    It 'скрипт обновления: архив коммита, install.ps1 с -Commit и -Repo, журнал; неверные данные — отказ' {
        $sha = 'd' * 40
        $s = Get-NotifierUpdateScript -Repo 'o/r' -Sha $sha -DataRoot "C:\Users\O'Neil\.cn"
        $s | Should -Match ([regex]::Escape("https://codeload.github.com/o/r/zip/$sha"))
        $s | Should -Match ([regex]::Escape("-Commit '$sha' -Repo 'o/r'"))
        $s | Should -Match ([regex]::Escape("'C:\Users\O''Neil\.cn'"))
        [void][scriptblock]::Create($s)   # скрипт разбирается без ошибок
        { Get-NotifierUpdateScript -Repo 'o/r; calc' -Sha $sha -DataRoot 'x' } | Should -Throw
        { Get-NotifierUpdateScript -Repo 'o/r' -Sha 'zzz' -DataRoot 'x' } | Should -Throw
    }

    It 'трей: проверка по расписанию, обновление — уведомление один раз с кнопкой «Обновить»' {
        $script:TrayDataRoot = Join-Path $TestDrive 'upd'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"update":{"channel":"main"}}')   # канал «ветка main»
        $script:AppVersion = @{ Commit = 'a' * 40; Repo = 'o/r'; Installed = '' }
        $new = 'b' * 40
        $done = [System.Threading.Tasks.Task]::FromResult("{`"status`":`"ahead`",`"ahead_by`":2,`"commits`":[{`"sha`":`"$new`",`"commit`":{`"message`":`"fix: x`"}}]}")
        Mock Start-NotifierUpdateCheck { $done }
        Mock Show-NotifierToast { $true }
        $script:TrayNoOutput = $false
        $script:UpdateTask = $null; $script:UpdateInfo = $null; $script:UpdateNotifiedSha = ''
        $script:UpdateNextCheck = [datetime]::UtcNow.AddMinutes(1)
        Invoke-NotifierUpdateTick
        Assert-MockCalled Start-NotifierUpdateCheck -Times 0 -Exactly -Scope It   # ещё рано
        $script:UpdateNextCheck = [datetime]::MinValue
        Invoke-NotifierUpdateTick   # запрос
        Invoke-NotifierUpdateTick   # ответ
        $script:UpdateInfo.Sha | Should -Be $new
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It -ParameterFilter { $Actions[0].Arguments -eq 'cn|||update' }
        $script:UpdateNextCheck = [datetime]::MinValue
        Invoke-NotifierUpdateTick; Invoke-NotifierUpdateTick
        Assert-MockCalled Show-NotifierToast -Times 1 -Exactly -Scope It   # о том же коммите — один раз
        Format-NotifierUpdateSubtitle | Should -Be 'Версия aaaaaaa · новых изменений: 2'
        @(Get-NotifierNotchSettingsRows | Where-Object { $_.Key -eq 'update' })[0].Value | Should -Be 'Обновить'
        # Выключено в настройках — не спрашивает.
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"update":{"enabled":false}}')
        $script:UpdateNextCheck = [datetime]::MinValue
        Invoke-NotifierUpdateTick
        Assert-MockCalled Start-NotifierUpdateCheck -Times 2 -Exactly -Scope It
        $script:AppVersion = $null; $script:UpdateInfo = $null
    }

    It 'сервер: /api/mac/update — та же версия 204, иначе версия и SHA-256 четырёх файлов' {
        $ctx = @{ DataRoot = (Join-Path $TestDrive 'srv'); Network = [pscustomobject]@{ port = 47600; devices = @() } }
        New-Item -ItemType Directory $ctx.DataRoot -Force | Out-Null
        $ver = Get-NotifierMacHooksVersion
        $ver | Should -Match '^[0-9a-f]{12}$'
        # Маршрут проверяется на сервере целиком в s_007_01; здесь — что hook.sh разбирает такой ответ.
        $hook = [IO.File]::ReadAllText((Join-Path $repoRoot 'src\mac\hook.sh'))
        $hook | Should -Match 'api/mac/update\?have='
        $hook | Should -Match 'sha256 "\$U/\$F"'
        $hook | Should -Match '\[ "\$KIND" = sessionstart \]'
    }
}

BeforeDiscovery {
    $openssl = @('C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
}

Describe 's_017_01 · HTTPS в локальной сети' {
    BeforeAll {
        $openssl = @('C:\Program Files\Git\usr\bin\openssl.exe', 'C:\Program Files\Git\mingw64\bin\openssl.exe') | Where-Object { Test-Path $_ } | Select-Object -First 1
    }


    It 'отпечаток ключа — как у openssl (curl --pinnedpubkey)' -Skip:(-not $openssl) {
        $c = New-SelfSignedCertificate -DnsName 'cn-test' -CertStoreLocation Cert:\CurrentUser\My -KeyAlgorithm RSA -KeyLength 2048 -FriendlyName 'cn-pin-test'
        try {
            $pin = Get-NotifierTlsPin -Certificate $c
            $der = Join-Path $TestDrive 'c.cer'
            [IO.File]::WriteAllBytes($der, $c.RawData)
            $pub = Join-Path $TestDrive 'pub.der'
            & $openssl x509 -inform DER -in $der -pubkey -noout | & $openssl pkey -pubin -outform DER -out $pub
            $sha = [System.Security.Cryptography.SHA256]::Create()
            $pin | Should -Be ([Convert]::ToBase64String($sha.ComputeHash([IO.File]::ReadAllBytes($pub))))
            Get-NotifierTlsCertificate -Store 'Cert:\CurrentUser\My' | Should -Be $null   # чужое имя — не наш сертификат
        }
        finally { Remove-Item -LiteralPath "Cert:\CurrentUser\My\$($c.Thumbprint)" }
    }

    It 'шифрование включено: команда установки и скрипт — https с отпечатком; без него — как раньше' {
        $root = Join-Path $TestDrive 'tls'
        New-Item -ItemType Directory $root -Force | Out-Null
        $net = Get-NotifierNetwork -DataRoot $root
        $dev = Add-NotifierDevice -Network $net -Name 'MacBook'
        $ctx = @{ Network = $net; Pairing = $null; InstallCodes = @{}; Events = New-Object System.Collections.ArrayList; DataRoot = $root
            Address = '192.168.1.50'; PcName = 'TESTPC'; NetworkDirty = $false; Tls = $null }
        Get-NotifierServerBaseUrl $ctx -Secure | Should -Be 'http://192.168.1.50:47600'
        $ctx.Tls = @{ Port = 47601; Pin = 'AbC+/=' }
        Get-NotifierServerBaseUrl $ctx | Should -Be 'http://192.168.1.50:47600'
        Get-NotifierServerBaseUrl $ctx -Secure | Should -Be 'https://192.168.1.50:47601'
        $ctx.InstallCodes['codetls12345'] = @{ DeviceId = $dev.Device.id; Expires = [DateTime]::UtcNow.AddMinutes(5) }
        $req = @{ Method = 'GET'; Path = '/install/codetls12345'; Query = @{}; Headers = @{}; Body = ''; TooLarge = $false; Remote = '192.168.1.7' }
        $script = (Invoke-NotifierHttpRequest -Request $req -Ctx $ctx).Body
        $script | Should -Match "BASE='https://192\.168\.1\.50:47601'"
        $script | Should -Match "URL2='https://testpc\.local:47601'"
        $script | Should -Match ([regex]::Escape("PIN='AbC+/='"))
        $script | Should -Not -Match '__PIN__'
    }

    It 'Test-NotifierTlsSetup: нет сертификата — $null (сервер работает только по http)' {
        Mock Get-NotifierTlsCertificate { $null } -ModuleName Server
        Test-NotifierTlsSetup -Port 47600 | Should -Be $null
        Get-NotifierTlsPort 47600 | Should -Be 47601
    }
}

Describe 's_017_01 · проверка работы (самодиагностика)' {
    It 'хуки в settings.json: все, часть, нет, битый файл' {
        $p = Join-Path $TestDrive 'settings.json'
        $hook = { param($ev) "`"$ev`":[{`"hooks`":[{`"type`":`"command`",`"command`":`"curl.exe`",`"args`":[`"http://127.0.0.1:47611/claude-notifier/hook/x`"]}]}]" }
        $all = @('Stop', 'Notification', 'StopFailure', 'SessionStart', 'UserPromptSubmit', 'SessionEnd', 'PermissionRequest') | ForEach-Object { & $hook $_ }
        [IO.File]::WriteAllText($p, "{`"hooks`":{$($all -join ',')}}")
        (Get-NotifierDiagHooks -SettingsPath $p).Level | Should -Be 'ok'
        [IO.File]::WriteAllText($p, "{`"hooks`":{$(($all | Select-Object -First 5) -join ',')}}")
        $r = Get-NotifierDiagHooks -SettingsPath $p
        $r.Level | Should -Be 'warn'; $r.Detail | Should -Match 'SessionEnd, PermissionRequest'
        [IO.File]::WriteAllText($p, '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo"}]}]}}')
        (Get-NotifierDiagHooks -SettingsPath $p).Level | Should -Be 'error'
        [IO.File]::WriteAllText($p, '{oops')
        (Get-NotifierDiagHooks -SettingsPath $p).Level | Should -Be 'error'
    }

    It 'журнал: ошибки за сутки — сколько и последняя; старые не считаются' {
        $root = Join-Path $TestDrive 'log'
        New-Item -ItemType Directory $root -Force | Out-Null
        (Get-NotifierDiagLogErrors -DataRoot $root).Level | Should -Be 'ok'
        $now = [datetime]'2026-11-18T12:00:00Z'
        [IO.File]::WriteAllLines((Join-Path $root 'log.txt'), @(
            '2026-11-16T10:00:00.000Z [ERROR] tray: старая',
            '2026-11-18T09:00:00.000Z [INFO] tray: ok',
            '2026-11-18T10:00:00.000Z [ERROR] tray: первая',
            '2026-11-18T11:00:00.000Z [ERROR] network: последняя'))
        $r = Get-NotifierDiagLogErrors -DataRoot $root -Now $now.ToUniversalTime()
        $r.Level | Should -Be 'warn'
        $r.Detail | Should -Be 'Ошибок за сутки: 2. Последняя: network: последняя'
    }

    It 'итог и значки; устройство с устаревшими хуками и молчащее — замечания; строка в шторке и пункт меню' {
        $items = @((New-NotifierDiagItem ok 'A' 'x'), (New-NotifierDiagItem warn 'B' 'y'))
        $t = Format-NotifierDiagnostics -Items $items
        ($t -split "`n")[0] | Should -Be 'Работает, но обратите внимание: 1.'
        $t | Should -Match '✓  A — x'
        $t | Should -Match '!  B — y'
        (Format-NotifierDiagnostics -Items @((New-NotifierDiagItem error 'C'))) | Should -Match '^Есть неполадки: 1\.'
        $script:TrayDataRoot = Join-Path $TestDrive 'diag'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $now = [DateTime]::UtcNow
        $fresh = $now.AddMinutes(-3).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'")
        $saved = $script:Net
        try {
            $script:Net = @{ Server = $null; Error = 'порт занят'; Network = [pscustomobject]@{ enabled = $true; port = 47600; devices = @(
                        [pscustomobject]@{ id = 'd1'; name = 'MacBook'; kind = 'mac'; hooks = $true; last_seen = $fresh; hooks_ver = (Get-NotifierMacHooksVersion) },
                        [pscustomobject]@{ id = 'd2'; name = 'Ubuntu'; kind = 'mac'; os = 'linux'; hooks = $true; last_seen = $fresh; hooks_ver = 'old' },
                        [pscustomobject]@{ id = 'd3'; name = 'Air'; kind = 'mac'; hooks = $true; last_seen = '2026-01-01T00:00:00.000Z'; hooks_ver = (Get-NotifierMacHooksVersion) }) } }
            $all = @(Get-NotifierDiagnostics -SettingsPath (Join-Path $TestDrive 'none.json') -Now $now)
            @($all | Where-Object Title -eq 'Доступ из сети')[0].Level | Should -Be 'error'
            @($all | Where-Object Title -eq 'Mac «MacBook»')[0].Level | Should -Be 'ok'
            @($all | Where-Object Title -eq 'Linux «Ubuntu»')[0].Detail | Should -Match 'устарели'
            @($all | Where-Object Title -eq 'Mac «Air»')[0].Detail | Should -Match 'Давно не на связи'
            @($all | Where-Object Title -eq 'Хуки Claude Code')[0].Level | Should -Be 'error'
        }
        finally { $script:Net = $saved }
        @(Get-NotifierNotchSettingsRows | Where-Object { $_.Key -eq 'diag' }).Count | Should -Be 1
    }
}

Describe 's_017_01 · уведомления на телефон вне сети (ntfy, Telegram)' {
    It 'адрес: тема ntfy, свой сервер, бот Telegram; остальное — не подходит' {
        $t = Get-NotifierPushTarget 'https://ntfy.sh/cn-Abc_123'
        $t.Kind | Should -Be 'ntfy'; $t.Endpoint | Should -Be 'https://ntfy.sh'; $t.Topic | Should -Be 'cn-Abc_123'
        (Get-NotifierPushTarget 'http://192.168.1.5:8080/topic/').Endpoint | Should -Be 'http://192.168.1.5:8080'
        $tg = Get-NotifierPushTarget 'https://api.telegram.org/bot123456:AAH-abcdefghijklmnopqrstuv/sendMessage?chat_id=-1001'
        $tg.Kind | Should -Be 'telegram'; $tg.Chat | Should -Be '-1001'
        $tg.Endpoint | Should -Be 'https://api.telegram.org/bot123456:AAH-abcdefghijklmnopqrstuv/sendMessage'
        foreach ($bad in @('', 'ntfy.sh/x', 'https://ntfy.sh/', 'https://ntfy.sh/a/b', 'https://x/a b', 'ftp://ntfy.sh/x')) { Get-NotifierPushTarget $bad | Should -Be $null }
        Format-NotifierPushTarget '' | Should -Be 'Не настроено'
        Format-NotifierPushTarget 'https://ntfy.sh/abc' | Should -Be 'ntfy · ntfy.sh/abc'
        # Токен бота в подписи не показывается.
        Format-NotifierPushTarget 'https://api.telegram.org/bot123456:AAH-abcdefghijklmnopqrstuv/sendMessage?chat_id=42' | Should -Be 'Telegram · чат 42'
    }

    It 'когда отправлять: включено, адрес верный, важный тип, вас нет за ПК дольше away' {
        $cfg = @{ push = @{ enabled = $true; url = 'https://ntfy.sh/abc'; away = 5; preview = $false } }
        $ev = [pscustomobject]@{ type = 'permission'; title = 'Нужно разрешение · shop'; preview = 'Bash: rm -rf' }
        Test-NotifierPushDue -Event $ev -Config $cfg -IdleSeconds 400 | Should -Be $true
        Test-NotifierPushDue -Event $ev -Config $cfg -IdleSeconds 100 | Should -Be $false
        $cfg.push.away = 0
        Test-NotifierPushDue -Event $ev -Config $cfg -IdleSeconds 0 | Should -Be $true
        Test-NotifierPushDue -Event ([pscustomobject]@{ type = 'working' }) -Config $cfg | Should -Be $false
        $cfg.push.url = 'nope'
        Test-NotifierPushDue -Event $ev -Config $cfg | Should -Be $false
        $cfg.push.url = 'https://ntfy.sh/abc'; $cfg.push.enabled = $false
        Test-NotifierPushDue -Event $ev -Config $cfg | Should -Be $false
    }

    It 'текст: без preview — только заголовок и общий текст; с preview — вопрос; JSON для ntfy и Telegram' {
        $ev = [pscustomobject]@{ type = 'permission'; title = 'Нужно разрешение · shop'; preview = 'Bash: rm -rf build' }
        $m = New-NotifierPushMessage -Event $ev
        $m.Title | Should -Be 'Нужно разрешение · shop'
        $m.Text | Should -Be 'Нужно ваше решение'
        $m.Priority | Should -Be 4
        (New-NotifierPushMessage -Event $ev -Preview).Text | Should -Be 'Bash: rm -rf build'
        $r = New-NotifierPushRequest -Target (Get-NotifierPushTarget 'https://ntfy.sh/abc') -Message $m
        $r.Uri | Should -Be 'https://ntfy.sh/'
        $j = ConvertFrom-Json $r.Json
        $j.topic | Should -Be 'abc'; $j.title | Should -Be 'Нужно разрешение · shop'; $j.priority | Should -Be 4
        $r = New-NotifierPushRequest -Target (Get-NotifierPushTarget 'https://api.telegram.org/bot123456:AAH-abcdefghijklmnopqrstuv/sendMessage?chat_id=42') -Message $m
        $r.Uri | Should -Be 'https://api.telegram.org/bot123456:AAH-abcdefghijklmnopqrstuv/sendMessage'
        $j = ConvertFrom-Json $r.Json
        $j.chat_id | Should -Be '42'
        $j.text | Should -Be "Нужно разрешение · shop`nНужно ваше решение"
        (Send-NotifierPush -Url 'плохой' -Message $m -Wait).Ok | Should -Be $false
    }

    It 'отправка на локальный сервер: тело дошло в UTF-8; сервер недоступен — ошибка, а не исключение' {
        $port = 47900 + (Get-Random -Maximum 90)
        $l = New-Object System.Net.HttpListener
        $l.Prefixes.Add("http://127.0.0.1:$port/")
        $l.Start()
        try {
            $async = $l.BeginGetContext($null, $null)
            $task = Send-NotifierPush -Url "http://127.0.0.1:$port/topic1" -Message @{ Title = 'Готово · shop'; Text = 'Ждёт ответа'; Priority = 3 }
            $async.AsyncWaitHandle.WaitOne(10000) | Should -Be $true
            $ctx = $l.EndGetContext($async)
            $body = (New-Object IO.StreamReader($ctx.Request.InputStream, [Text.Encoding]::UTF8)).ReadToEnd()
            $ctx.Response.StatusCode = 200; $ctx.Response.Close()
            $ctx.Request.HttpMethod | Should -Be 'POST'
            (ConvertFrom-Json $body).title | Should -Be 'Готово · shop'
            $task.Wait(5000) | Should -Be $true
            $task.Result.IsSuccessStatusCode | Should -Be $true
        }
        finally { $l.Stop(); $l.Close() }
        $r = Send-NotifierPush -Url "http://127.0.0.1:$port/topic1" -Message @{ Title = 'x'; Text = 'y'; Priority = 3 } -Wait
        $r.Ok | Should -Be $false
        $r.Error | Should -Not -BeNullOrEmpty
    }

    It 'config.json: раздел push — адрес, away 0–240, preview; по умолчанию выключено' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory $root -Force | Out-Null
        $c = Get-NotifierConfig -DataRoot $root
        $c.push.enabled | Should -Be $false
        $c.push.away | Should -Be 5
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"push":{"enabled":true,"url":"https://ntfy.sh/abc","away":0,"preview":true}}')
        $c = Get-NotifierConfig -DataRoot $root
        $c.push.enabled | Should -Be $true; $c.push.url | Should -Be 'https://ntfy.sh/abc'; $c.push.away | Should -Be 0; $c.push.preview | Should -Be $true
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"push":{"url":"a b","away":999}}')
        $c = Get-NotifierConfig -DataRoot $root
        $c.push.url | Should -Be ''
        $c.push.away | Should -Be 5
    }

    It 'шторка: строки «На телефон вне сети», «Отправлять» и «Текст вопроса»; выбор «Всегда» включает' {
        $script:TrayDataRoot = Join-Path $TestDrive 'notch'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $rows = @(Get-NotifierNotchSettingsRows)
        $keys = @($rows | ForEach-Object { $_.Key })
        $keys -contains 'push' | Should -Be $true
        $keys -contains 'push.preview' | Should -Be $true
        @($rows | Where-Object { $_.Key -eq 'push.away' })[0].Value | Should -Be 'Выключено'
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"push":{"url":"https://ntfy.sh/abc"}}')
        Set-NotifierSelectValue -Key 'push.away' -Value '0'
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.push.enabled | Should -Be $true; $c.push.away | Should -Be 0
        [void](Invoke-NotifierNotchSetting -Key 'push.preview')
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).push.preview | Should -Be $true
        Set-NotifierSelectValue -Key 'push.away' -Value 'off'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).push.enabled | Should -Be $false
    }

    It 'трей: событие, когда вас нет за ПК, уходит на телефон; за ПК — нет' {
        $root = Join-Path $TestDrive 'tray'
        New-Item -ItemType Directory $root -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $root 'config.json'), '{"push":{"enabled":true,"url":"https://ntfy.sh/abc","away":5}}')
        Mock Send-NotifierPush { $null }
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { }
        Mock Get-NotifierIdleSeconds { 900 }
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $q.Enqueue([pscustomobject]@{ v = 1; type = 'permission'; title = 'Нужно разрешение · shop'; preview = 'x'; session_id = 's1'; ts = [DateTime]::UtcNow.ToString('o') })
        [void](Invoke-NotifierEventBatch -Queue $q -DataRoot $root)
        Assert-MockCalled Send-NotifierPush -Times 1 -Exactly -Scope It
        Mock Get-NotifierIdleSeconds { 10 }
        $q.Enqueue([pscustomobject]@{ v = 1; type = 'permission'; title = 'Нужно разрешение · shop'; preview = 'x'; session_id = 's2'; ts = [DateTime]::UtcNow.ToString('o') })
        [void](Invoke-NotifierEventBatch -Queue $q -DataRoot $root)
        Assert-MockCalled Send-NotifierPush -Times 1 -Exactly -Scope It
    }
}
