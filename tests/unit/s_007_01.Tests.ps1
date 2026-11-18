# Pester 5: условия -Skip вычисляются при обнаружении тестов — sh и node ищутся и здесь.
BeforeDiscovery {
    $sh = Get-Command sh -ErrorAction SilentlyContinue
    if (-not $sh) { $git = Get-Command git -ErrorAction SilentlyContinue; if ($git) { $cand = Join-Path (Split-Path (Split-Path $git.Source)) 'usr\bin\sh.exe'; if (Test-Path $cand) { $sh = Get-Item $cand } } }
    $shPath = if ($sh) { if ($sh.Source) { $sh.Source } else { $sh.FullName } } else { $null }
    $node = Get-Command node -ErrorAction SilentlyContinue
}

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Devices.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Server.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Sessions.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Net.Http

    $sh = Get-Command sh -ErrorAction SilentlyContinue
    if (-not $sh) { $git = Get-Command git -ErrorAction SilentlyContinue; if ($git) { $cand = Join-Path (Split-Path (Split-Path $git.Source)) 'usr\bin\sh.exe'; if (Test-Path $cand) { $sh = Get-Item $cand } } }
    $shPath = if ($sh) { if ($sh.Source) { $sh.Source } else { $sh.FullName } } else { $null }
    # sh.exe из Git for Windows ищет tr/cat только через PATH: без его папки в PATH hook.sh падает
    if ($shPath) { $shDir = Split-Path $shPath; if (($env:PATH -split ';') -notcontains $shDir) { $env:PATH = "$shDir;$env:PATH" } }
    $node = Get-Command node -ErrorAction SilentlyContinue

    function New-Ctx([string]$Root) {
        New-Item -ItemType Directory -Path $Root -Force | Out-Null
        return @{
            Network = (Get-NotifierNetwork -DataRoot $Root); Pairing = (New-NotifierPairing); InstallCodes = @{}
            Events = (New-Object System.Collections.ArrayList); NetworkDirty = $false; Paired = $null
            DataRoot = $Root; Address = '192.168.1.50'; PcName = 'TESTPC'
        }
    }

    function New-Req([string]$Method, [string]$Path, [string]$Body = '', [hashtable]$Headers = @{}, [hashtable]$Query = @{}) {
        # API принимает POST только с JSON (как шлют страница и hook.sh); /login — форма.
        $Headers = $Headers.Clone()
        if ($Method -eq 'POST' -and $Path -ne '/login' -and -not $Headers.ContainsKey('content-type')) { $Headers['content-type'] = 'application/json; charset=utf-8' }
        return @{ Method = $Method; Path = $Path; Body = $Body; Headers = $Headers; Query = $Query; TooLarge = $false; Remote = '192.168.1.60' }
    }

    function Get-CookieToken($Resp) {
        $c = @($Resp.Headers | Where-Object { $_[0] -eq 'Set-Cookie' })[0][1]
        return ($c -split ';')[0].Split('=', 2)[1]
    }

    function Connect-Device([hashtable]$Ctx, [string]$Agent = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)') {
        $Ctx.Pairing = New-NotifierPairing
        $r = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' "pin=$($Ctx.Pairing.Pin)" @{ 'user-agent' = $Agent }) -Ctx $Ctx
        return (Get-CookieToken $r)
    }

    function Get-FreePort {
        # Свободный порт: система выдаёт его для TcpListener на порту 0.
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
        return $port
    }
}

Describe 's_007_01 · Devices.psm1' {
    It 'network.json: по умолчанию выключено, порт 47600; запись и чтение; повреждённый → по умолчанию' {
        $root = Join-Path $TestDrive 'net'
        $n = Get-NotifierNetwork -DataRoot $root
        $n.enabled | Should -Be $false
        $n.port | Should -Be 47600
        $added = Add-NotifierDevice -Network $n -Name 'iPhone'
        $n.enabled = $true
        Save-NotifierNetwork -Network $n -DataRoot $root
        $raw = Get-Content (Join-Path $root 'network.json') -Raw
        $raw | Should -Not -Match ([regex]::Escape($added.Token))   # хранится только хэш
        $m = Get-NotifierNetwork -DataRoot $root
        $m.enabled | Should -Be $true
        $m.devices.Count | Should -Be 1
        (Find-NotifierDeviceByToken -Network $m -Token $added.Token).name | Should -Be 'iPhone'
        Find-NotifierDeviceByToken -Network $m -Token 'wrong' | Should -Be $null
        Find-NotifierDeviceByToken -Network $m -Token '' | Should -Be $null
        [IO.File]::WriteAllText((Join-Path $root 'network.json'), '{bad', [Text.Encoding]::UTF8)
        (Get-NotifierNetwork -DataRoot $root).devices.Count | Should -Be 0
    }

    It 'второй токен устройства работает; отключение отзывает все токены' {
        $n = Get-NotifierNetwork -DataRoot (Join-Path $TestDrive 'none')
        $a = Add-NotifierDevice -Network $n -Name 'Mac'
        $t2 = Add-NotifierDeviceToken -Device $a.Device
        (Find-NotifierDeviceByToken -Network $n -Token $t2).id | Should -Be $a.Device.id
        Remove-NotifierDevice -Network $n -Id $a.Device.id | Should -Be $true
        Remove-NotifierDevice -Network $n -Id $a.Device.id | Should -Be $false
        Find-NotifierDeviceByToken -Network $n -Token $a.Token | Should -Be $null
        Find-NotifierDeviceByToken -Network $n -Token $t2 | Should -Be $null
    }

    It 'токены случайные, 43 символа base64url' {
        $a = New-NotifierToken; $b = New-NotifierToken
        $a | Should -Match '^[A-Za-z0-9_-]{43}$'
        $a | Should -Not -Be $b
    }

    It 'PIN: верный один раз; неверный считает попытки; 5 ошибок → locked; истёк → expired' {
        $now = [datetime]'2026-11-16T12:00:00'
        $p = New-NotifierPairing -Now $now
        $p.Pin | Should -Match '^\d{6}$'
        Test-NotifierPairingPin -Pairing $p -Pin '000000x' -Now $now | Should -Be 'bad'
        Test-NotifierPairingPin -Pairing $p -Pin ($p.Pin.Substring(0, 3) + ' ' + $p.Pin.Substring(3)) -Now $now | Should -Be 'ok'
        Test-NotifierPairingPin -Pairing $p -Pin $p.Pin -Now $now | Should -Be 'none'
        $q = New-NotifierPairing -Now $now
        1..4 | ForEach-Object { Test-NotifierPairingPin -Pairing $q -Pin 'x' -Now $now } | Select-Object -Last 1 | Should -Be 'bad'
        Test-NotifierPairingPin -Pairing $q -Pin 'x' -Now $now | Should -Be 'locked'
        Test-NotifierPairingPin -Pairing $q -Pin $q.Pin -Now $now | Should -Be 'locked'
        $e = New-NotifierPairing -Now $now
        Test-NotifierPairingPin -Pairing $e -Pin $e.Pin -Now $now.AddMinutes(11) | Should -Be 'expired'
        # Попытки — по адресу: чужой хост, исчерпав свои, не блокирует ввод PIN с телефона
        $r = New-NotifierPairing -Now $now
        1..5 | ForEach-Object { [void](Test-NotifierPairingPin -Pairing $r -Pin 'x' -Now $now -Remote '10.0.0.66') }
        Test-NotifierPairingPin -Pairing $r -Pin $r.Pin -Now $now -Remote '10.0.0.66' | Should -Be 'locked'
        Get-NotifierPairingAttemptsLeft -Pairing $r -Remote '10.0.0.7' | Should -Be 5
        Test-NotifierPairingPin -Pairing $r -Pin $r.Pin -Now $now -Remote '10.0.0.7' | Should -Be 'ok'
        # Общий предел на все адреса — 20 неверных попыток
        $t = New-NotifierPairing -Now $now
        1..20 | ForEach-Object { [void](Test-NotifierPairingPin -Pairing $t -Pin 'x' -Now $now -Remote "10.0.1.$_") }
        Test-NotifierPairingPin -Pairing $t -Pin $t.Pin -Now $now -Remote '10.0.0.7' | Should -Be 'locked'
        Test-NotifierPairingPin -Pairing $null -Pin '1' | Should -Be 'none'
    }

    It 'имя по User-Agent: <Expected>' -TestCases @(
        @{ Ua = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)'; Expected = 'iPhone' },
        @{ Ua = 'Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)'; Expected = 'iPad' },
        @{ Ua = 'Mozilla/5.0 (Linux; Android 15; Pixel 9)'; Expected = 'Android' },
        @{ Ua = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari'; Expected = 'Mac' },
        @{ Ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)'; Expected = 'Windows' },
        @{ Ua = ''; Expected = 'Браузер' }
    ) {
        param($Ua, $Expected)
        Get-NotifierDeviceNameFromAgent $Ua | Should -Be $Expected
    }

    It 'Format-NotifierLastSeen' {
        $now = [datetime]::Parse('2026-11-16T12:00:00Z').ToUniversalTime()
        Format-NotifierLastSeen -Ts '2026-11-16T11:59:30Z' -Now $now | Should -Be 'в сети'
        Format-NotifierLastSeen -Ts '2026-11-16T11:45:00Z' -Now $now | Should -Be '15 мин назад'
        Format-NotifierLastSeen -Ts '2026-11-16T09:00:00Z' -Now $now | Should -Be '3 ч назад'
        Format-NotifierLastSeen -Ts '2026-11-10T09:00:00Z' -Now $now | Should -Match '^\d\d\.\d\d$'
        Format-NotifierLastSeen -Ts '' -Now $now | Should -Be '—'
    }

    It 'адрес в локальной сети: частный IPv4 или $null' {
        $a = Get-NotifierLanAddress
        if ($null -ne $a) { $a | Should -Match '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' }
    }
}

Describe 's_007_01 · маршруты HTTP' {
    It 'без cookie: / → страница входа с именем ПК; API → 401' {
        $ctx = New-Ctx (Join-Path $TestDrive 'r1')
        $r = Invoke-NotifierHttpRequest -Request (New-Req GET '/') -Ctx $ctx
        $r.Status | Should -Be 200
        $r.ContentType | Should -Match 'text/html'
        $r.Body | Should -Match 'TESTPC'
        $r.Body | Should -Match 'name="pin"'
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/sessions') -Ctx $ctx).Status | Should -Be 401
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{}' @{ authorization = 'Bearer nope' }) -Ctx $ctx).Status | Should -Be 401
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{}' @{ authorization = 'Bearer nope' }) -Ctx $ctx).Status | Should -Be 401
        # Хук с недействующим токеном — след в журнале, один раз (не на каждый запрос)
        $log = Join-Path $TestDrive 'r1\log.txt'
        @(Get-Content -LiteralPath $log -Encoding UTF8 | Where-Object { $_ -match 'токен не действует' }).Count | Should -Be 1
    }

    It 'вход с формы страницы: свой Origin — вход; Origin null — понятная страница, а не JSON' {
        $ctx = New-Ctx (Join-Path $TestDrive 'origin')
        $ctx.Pairing = New-NotifierPairing
        $bad = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' "pin=$($ctx.Pairing.Pin)" @{ origin = 'null'; host = '192.168.1.50:47600' }) -Ctx $ctx
        $bad.Status | Should -Be 403
        $bad.ContentType | Should -Match 'text/html'
        $bad.Body | Should -Match 'Обновите страницу'
        $ok = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' "pin=$($ctx.Pairing.Pin)" @{ origin = 'http://192.168.1.50:47600'; host = '192.168.1.50:47600'; 'user-agent' = 'Mozilla/5.0 (Macintosh)' }) -Ctx $ctx
        $ok.Status | Should -Be 303
        (Get-CookieToken $ok) | Should -Match '^[A-Za-z0-9_-]{43}$'
    }

    It 'вход: неверный PIN → 401 с числом попыток; верный → cookie, устройство по User-Agent, Paired' {
        $ctx = New-Ctx (Join-Path $TestDrive 'r2')
        $bad = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' 'pin=999999x') -Ctx $ctx
        $bad.Status | Should -Be 401
        $bad.Body | Should -Match 'Осталось попыток: 4'
        $ok = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' "pin=$($ctx.Pairing.Pin)" @{ 'user-agent' = 'Mozilla/5.0 (iPhone)' }) -Ctx $ctx
        $ok.Status | Should -Be 303
        @($ok.Headers | Where-Object { $_[0] -eq 'Location' })[0][1] | Should -Be '/'
        $cookie = @($ok.Headers | Where-Object { $_[0] -eq 'Set-Cookie' })[0][1]
        $cookie | Should -Match '^cn_token=[A-Za-z0-9_-]{43}; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax$'
        $ctx.Network.devices.Count | Should -Be 1
        $ctx.Network.devices[0].name | Should -Be 'iPhone'
        $ctx.Paired.name | Should -Be 'iPhone'
        $ctx.NetworkDirty | Should -Be $true
        $again = Invoke-NotifierHttpRequest -Request (New-Req POST '/login' "pin=$($ctx.Pairing.Pin)") -Ctx $ctx
        $again.Body | Should -Match 'Код недействителен'
    }

    It 'с cookie: страница сеансов, /api/me, /api/sessions с сеансом этого ПК' {
        $root = Join-Path $TestDrive 'r3'
        $ctx = New-Ctx $root
        $token = Connect-Device $ctx
        $hdr = @{ cookie = "other=1; cn_token=$token" }
        $page = Invoke-NotifierHttpRequest -Request (New-Req GET '/' '' $hdr) -Ctx $ctx
        $page.Body | Should -Match 'Сеансы Claude'
        $me = (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/me' '' $hdr) -Ctx $ctx).Body | ConvertFrom-Json
        $me.name | Should -Be 'iPhone'
        $me.hooks | Should -Be $false
        Save-NotifierSessions -Sessions @([pscustomobject]@{ session_id = 's'; project = 'proj'; origin = 'desktop'; device = ''; state = 'permission'; since = [DateTime]::UtcNow.ToString('o'); updated = [DateTime]::UtcNow.ToString('o'); preview = 'p'; window = $null }) -DataRoot $root
        $data = (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/sessions' '' $hdr) -Ctx $ctx).Body | ConvertFrom-Json
        $data.pc | Should -Be 'TESTPC'
        @($data.sessions).Count | Should -Be 1
        $data.sessions[0].device_name | Should -Be 'Этот ПК'
        $data.sessions[0].state_text | Should -Be 'Нужно разрешение'
        $data.sessions[0].elapsed | Should -Be 'только что'
        @($data.devices).Count | Should -Be 1
    }

    It 'Mac: ссылка установки → скрипт с токеном (один раз) → hello → события с токеном хуков' {
        $root = Join-Path $TestDrive 'r4'
        $ctx = New-Ctx $root
        $cookie = Connect-Device $ctx 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)'
        $link = (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie" }) -Ctx $ctx).Body | ConvertFrom-Json
        $link.command | Should -Match '^curl -fsSL http://192\.168\.1\.50:47600/install/[A-Za-z0-9_-]{43} \| sh$'
        $path = ($link.command -split ' ')[2] -replace '^http://[^/]+', ''
        $script = (Invoke-NotifierHttpRequest -Request (New-Req GET $path) -Ctx $ctx).Body
        $script | Should -Match "BASE='http://192\.168\.1\.50:47600'"
        $script | Should -Match "URL2='http://testpc\.local:47600'"
        $script | Should -Match "CN_URL2='\`$URL2'"
        $script.Contains("`r") | Should -Be $false
        $hookToken = [regex]::Match($script, "Authorization: Bearer ([A-Za-z0-9_-]+)'").Groups[1].Value
        $hookToken | Should -Match '^[A-Za-z0-9_-]{43}$'
        # В скрипте — SHA-256 файлов ровно в том виде, в каком их отдаёт сервер
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hookBody = (Invoke-NotifierHttpRequest -Request (New-Req GET '/mac/hook.sh') -Ctx $ctx).Body
        $expected = -join ($sha.ComputeHash((New-Object Text.UTF8Encoding $false).GetBytes($hookBody)) | ForEach-Object { $_.ToString('x2') })
        $script | Should -Match "fetch hook\.sh '$expected'"
        $script | Should -Not -Match '__SHA_'
        (Invoke-NotifierHttpRequest -Request (New-Req GET $path) -Ctx $ctx).Body | Should -Match 'устарела'
        $bearer = @{ authorization = "Bearer $hookToken" }
        # Токен хуков не открывает остальное API: ни решения по разрешениям, ни ответы, ни список сеансов
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/decision' '{"id":"x","behavior":"allow"}' $bearer) -Ctx $ctx).Status | Should -Be 403
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/reply' '{"session":"x","text":"y"}' $bearer) -Ctx $ctx).Status | Should -Be 403
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/sessions' '' $bearer) -Ctx $ctx).Status | Should -Be 403
        # Cookie браузера: POST не-JSON и чужой Origin отклоняются
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie"; 'content-type' = 'text/plain' }) -Ctx $ctx).Status | Should -Be 415
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie"; origin = 'http://evil.example'; host = '192.168.1.50:47600' }) -Ctx $ctx).Status | Should -Be 403
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie"; origin = 'http://192.168.1.50:47600'; host = '192.168.1.50:47600' }) -Ctx $ctx).Status | Should -Be 200
        # «Origin: null» (так шлёт браузер со сторонней страницы или песочницы) — отказ
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie"; origin = 'null'; host = '192.168.1.50:47600' }) -Ctx $ctx).Status | Should -Be 403
        # Регистр имени хоста не важен (адрес вида testpc.local)
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/install-link' '' @{ cookie = "cn_token=$cookie"; origin = 'http://TestPC.local:47600'; host = 'testpc.local:47600' }) -Ctx $ctx).Status | Should -Be 200
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"MacBook Pro Саши"}' $bearer) -Ctx $ctx).Status | Should -Be 200
        $d = $ctx.Network.devices[0]
        $d.name | Should -Be 'MacBook Pro Саши'
        $d.kind | Should -Be 'mac'
        $d.hooks | Should -Be $true
        $d.os | Should -Be 'mac'   # прежние хуки поле os не шлют — это Mac
        # Linux и WSL: settings.py раздаётся и сверяется так же; система запоминается и видна в подписи устройства.
        $pyBody = (Invoke-NotifierHttpRequest -Request (New-Req GET '/mac/settings.py') -Ctx $ctx).Body
        $pySha = -join ($sha.ComputeHash((New-Object Text.UTF8Encoding $false).GetBytes($pyBody)) | ForEach-Object { $_.ToString('x2') })
        $script | Should -Match "fetch settings\.py '$pySha'"
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"DESKTOP (WSL)","os":"wsl"}' $bearer) -Ctx $ctx).Status | Should -Be 200
        $ctx.Network.devices[0].os | Should -Be 'wsl'
        Get-NotifierDeviceKindText -Device $ctx.Network.devices[0] | Should -Be 'WSL · сеансы видны здесь'
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"MacBook Pro Саши","os":"evil"}' $bearer) -Ctx $ctx).Status | Should -Be 200
        $ctx.Network.devices[0].os | Should -Be 'mac'
        $ev = Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{"session_id":"m1","cwd":"/Users/a/dev/site","last_assistant_message":"Готово"}' $bearer @{ kind = 'stop'; entry = 'cli' }) -Ctx $ctx
        $ev.Status | Should -Be 200
        $ctx.Events.Count | Should -Be 1
        $ctx.Events[0].type | Should -Be 'done'
        $ctx.Events[0].device | Should -Be $d.id
        $ctx.Events[0].project | Should -Be 'site'
        $ctx.Events[0].origin | Should -Be 'cli'
        $ctx.Events[0].title | Should -Be "Готово $([char]0x00B7) site $([char]0x00B7) MacBook Pro Саши"
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{}' $bearer @{ kind = 'bogus' }) -Ctx $ctx).Status | Should -Be 400
        # Сеанс этого ПК (device '') токен Mac перехватить не может; свой сеанс Mac — обновляет
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 'pc1'; device = ''; state = 'working'; project = 'p' },
            [pscustomobject]@{ session_id = 'm1'; device = $d.id; state = 'working'; project = 'site' }) -DataRoot $ctx.DataRoot
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{"session_id":"pc1"}' $bearer @{ kind = 'stop'; entry = 'cli' }) -Ctx $ctx).Status | Should -Be 403
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{"session_id":"m1"}' $bearer @{ kind = 'stop'; entry = 'cli' }) -Ctx $ctx).Status | Should -Be 200
        # Запрос с Mac: начало текста — если включено «Показывать запрос»; сводка ECC помечена служебной
        Set-NotifierConfigValue -Name showPrompt -Value $true -DataRoot $ctx.DataRoot
        $ctx.Events.Clear()
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{"session_id":"m2","cwd":"/Users/a/dev/site","prompt":"Почини кнопку"}' $bearer @{ kind = 'prompt'; entry = 'cli' }) -Ctx $ctx).Status | Should -Be 200
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/event' '{"session_id":"m3","cwd":"/Users/a/dev/site","prompt":"Below is a conversation log from a Claude Code coding session.\n\nx"}' $bearer @{ kind = 'prompt'; entry = 'cli' }) -Ctx $ctx).Status | Should -Be 200
        $ctx.Events[0].prompt | Should -Be 'Почини кнопку'
        $ctx.Events[0].PSObject.Properties['helper'] | Should -Be $null
        $ctx.Events[1].helper | Should -Be $true
    }

    It 'просроченная ссылка установки не выдаёт токен' {
        $ctx = New-Ctx (Join-Path $TestDrive 'r5')
        $a = Add-NotifierDevice -Network $ctx.Network -Name 'Mac'
        $ctx.InstallCodes['abcdefgh12345678'] = @{ DeviceId = $a.Device.id; Expires = [DateTime]::UtcNow.AddMinutes(-1) }
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/install/abcdefgh12345678') -Ctx $ctx).Body | Should -Match 'устарела'
        @($a.Device.tokens).Count | Should -Be 1
    }

    It 'файлы для Mac отдаются без авторизации и только с LF; 404; 413' {
        $ctx = New-Ctx (Join-Path $TestDrive 'r6')
        foreach ($p in '/mac/hook.sh', '/mac/settings.js', '/mac/uninstall.sh') {
            $r = Invoke-NotifierHttpRequest -Request (New-Req GET $p) -Ctx $ctx
            $r.Status | Should -Be 200
            $r.Body.Contains("`r") | Should -Be $false
        }
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/mac/env') -Ctx $ctx).Status | Should -Be 401
        $token = Connect-Device $ctx
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/nope' '' @{ cookie = "cn_token=$token" }) -Ctx $ctx).Status | Should -Be 404
        $big = New-Req POST '/api/event'; $big.TooLarge = $true
        (Invoke-NotifierHttpRequest -Request $big -Ctx $ctx).Status | Should -Be 413
    }

    It 'отключённое устройство больше не принимается' {
        $ctx = New-Ctx (Join-Path $TestDrive 'r7')
        $token = Connect-Device $ctx
        [void](Remove-NotifierDevice -Network $ctx.Network -Id $ctx.Network.devices[0].id)
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/me' '' @{ cookie = "cn_token=$token" }) -Ctx $ctx).Status | Should -Be 401
    }
}

Describe 's_007_01 · настоящий HTTP на localhost' {
    It 'запрос проходит через HttpListener: очередь → обработка → ответ клиенту' {
        $root = Join-Path $TestDrive 'live'
        $ctx = New-Ctx $root
        $port = (Get-FreePort)
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server = Start-NotifierHttpServer -Prefix "http://localhost:$port/" -Queue $q
        $client = New-Object System.Net.Http.HttpClient
        try {
            $task = $client.GetAsync("http://localhost:$port/")
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not $task.IsCompleted -and [DateTime]::UtcNow -lt $deadline) {
                $c = $null
                if ($q.TryDequeue([ref]$c)) {
                    Write-NotifierHttpResponse -Context $c -Response (Invoke-NotifierHttpRequest -Request (ConvertFrom-NotifierHttpContext -Context $c) -Ctx $ctx)
                }
                Start-Sleep -Milliseconds 20
            }
            $resp = $task.Result
            [int]$resp.StatusCode | Should -Be 200
            $resp.Headers.GetValues('Cache-Control') | Should -Be 'no-store'
            # same-origin: со своей страницы браузер шлёт настоящий Origin (при no-referrer — «null», и вход ломался)
            $resp.Headers.GetValues('Referrer-Policy') | Should -Be 'same-origin'
            $resp.Content.ReadAsStringAsync().Result | Should -Match 'TESTPC'
        }
        finally {
            $client.Dispose()
            Stop-NotifierHttpServer -Server $server | Should -Be $true
        }
    }

    It 'тот же Mac подключён заново: сеансы прежнего подключения переходят к новому, отключённого — возвращаются' {
        $ctx = New-Ctx (Join-Path $TestDrive 'repair')
        $old = Add-NotifierDevice -Network $ctx.Network -Name 'MacBook Air' -Kind mac
        $old.Device.hooks = $true
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 's1'; device = $old.Device.id; state = 'working'; project = 'shop' },
            [pscustomobject]@{ session_id = 'pc'; device = ''; state = 'waiting'; project = 'x' }) -DataRoot $ctx.DataRoot
        $new = Add-NotifierDevice -Network $ctx.Network -Name 'Mac'
        $tok = Add-NotifierDeviceToken -Device $new.Device -Hook
        $bearer = @{ authorization = "Bearer $tok" }
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"MacBook Air","replies":true}' $bearer) -Ctx $ctx).Status | Should -Be 200
        @($ctx.Network.devices).Count | Should -Be 1
        $ctx.Network.devices[0].id | Should -Be $new.Device.id
        (@(Get-NotifierSessions -DataRoot $ctx.DataRoot) | Where-Object session_id -eq 's1').device | Should -Be $new.Device.id
        # Отключили и подключили снова: сеансы хранятся сутки и возвращаются новому подключению с тем же именем
        $all = @(Get-NotifierSessions -DataRoot $ctx.DataRoot)
        Save-NotifierRemovedSessions -Name 'MacBook Air' -Sessions @($all | Where-Object session_id -eq 's1') -DataRoot $ctx.DataRoot
        Save-NotifierSessions -Sessions @($all | Where-Object session_id -ne 's1') -DataRoot $ctx.DataRoot
        [void](Remove-NotifierDevice -Network $ctx.Network -Id $new.Device.id)
        $third = Add-NotifierDevice -Network $ctx.Network -Name 'Mac'
        $tok3 = Add-NotifierDeviceToken -Device $third.Device -Hook
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"MacBook Air"}' @{ authorization = "Bearer $tok3" }) -Ctx $ctx).Status | Should -Be 200
        (@(Get-NotifierSessions -DataRoot $ctx.DataRoot) | Where-Object session_id -eq 's1').device | Should -Be $third.Device.id
        Test-Path (Join-Path $ctx.DataRoot 'removed-sessions.json') | Should -Be $false   # возвращено — запись удалена
        Restore-NotifierRemovedSessions -Name 'MacBook Air' -DeviceId 'x' -DataRoot $ctx.DataRoot | Should -Be 0
        # Версия хуков: без неё (старая установка) или другая — «обновите хуки»; текущая — всё в порядке
        $ver = Get-NotifierMacHooksVersion
        $ver | Should -Match '^[0-9a-f]{12}$'
        Test-NotifierMacHooksOutdated -Device $third.Device | Should -Be $true
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' "{`"name`":`"MacBook Air`",`"version`":`"$ver`"}" @{ authorization = "Bearer $tok3" }) -Ctx $ctx).Status | Should -Be 200
        Test-NotifierMacHooksOutdated -Device $third.Device | Should -Be $false
        # Самообновление хуков: та же версия — 204; старая — версия и SHA-256 файлов, как их раздаёт сервер.
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/update' '' @{ authorization = "Bearer $tok3" } @{ have = $ver }) -Ctx $ctx).Status | Should -Be 204
        $u = Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/update' '' @{ authorization = "Bearer $tok3" } @{ have = 'old' }) -Ctx $ctx
        $u.Status | Should -Be 200
        $u.Body | Should -Match "(?m)^version $ver$"
        $sha = [System.Security.Cryptography.SHA256]::Create()
        foreach ($f in @('hook.sh', 'settings.js', 'settings.py', 'uninstall.sh')) {
            $b = (Invoke-NotifierHttpRequest -Request (New-Req GET "/mac/$f") -Ctx $ctx).Body
            $h = -join ($sha.ComputeHash((New-Object Text.UTF8Encoding $false).GetBytes($b)) | ForEach-Object { $_.ToString('x2') })
            $u.Body | Should -Match "(?m)^$([regex]::Escape($f)) $h$"
        }
        # Без токена — 401.
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/update') -Ctx $ctx).Status | Should -Be 401
        $ctx.InstallCodes['codever12345'] = @{ DeviceId = $third.Device.id; Expires = [DateTime]::UtcNow.AddMinutes(5) }
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/install/codever12345') -Ctx $ctx).Body | Should -Match "`"version`":`"$ver`""
    }

    It 'hook.sh (через sh) отправляет событие хука на сервер' -Skip:(-not $shPath) {
        $root = Join-Path $TestDrive 'hooksh'
        $ctx = New-Ctx $root
        $a = Add-NotifierDevice -Network $ctx.Network -Name 'MacBook'
        $hookToken = Add-NotifierDeviceToken -Device $a.Device -Hook
        $port = (Get-FreePort)
        $macHome = Join-Path $TestDrive 'machome'
        New-Item -ItemType Directory -Path (Join-Path $macHome '.claude-notifier') -Force | Out-Null
        # Как пишет install.sh: адреса в env, токен — в файле заголовка auth
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $macHome '.claude-notifier\env'), "CN_URL='http://localhost:$port'`nCN_URL2=''`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $macHome '.claude-notifier\auth'), "Authorization: Bearer $hookToken`n", $utf8)
        $stdin = Join-Path $TestDrive 'stdin.json'
        [IO.File]::WriteAllText($stdin, '{"session_id":"mac-1","cwd":"/Users/a/dev/shop","message":"Разрешить?"}', (New-Object Text.UTF8Encoding $false))
        # Отложенное событие (ПК был недоступен 5 минут назад) уходит первым — без уведомления задним числом
        $qdir = Join-Path $macHome '.claude-notifier\queue'
        New-Item -ItemType Directory -Path $qdir -Force | Out-Null
        $old = [DateTimeOffset]::UtcNow.AddMinutes(-5).ToUnixTimeSeconds()
        [IO.File]::WriteAllText((Join-Path $qdir "$old.77.stop.claude-desktop.ev"), '{"session_id":"mac-1","cwd":"/Users/a/dev/shop","last_assistant_message":"Готово"}', $utf8)
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server = Start-NotifierHttpServer -Prefix "http://localhost:$port/" -Queue $q
        $oldHome = $env:HOME
        try {
            $env:HOME = $macHome
            $hook = (Join-Path $repoRoot 'src\mac\hook.sh')
            $p = Start-Process -FilePath $shPath -ArgumentList @("`"$hook`"", 'notification') -RedirectStandardInput $stdin -NoNewWindow -PassThru
            [void]$p.Handle   # иначе в PS 5.1 ExitCode после выхода пуст
            $deadline = [DateTime]::UtcNow.AddSeconds(15)
            while (-not $p.HasExited -and [DateTime]::UtcNow -lt $deadline) {
                $c = $null
                if ($q.TryDequeue([ref]$c)) {
                    Write-NotifierHttpResponse -Context $c -Response (Invoke-NotifierHttpRequest -Request (ConvertFrom-NotifierHttpContext -Context $c) -Ctx $ctx)
                }
                Start-Sleep -Milliseconds 20
            }
            $p.WaitForExit(2000) | Out-Null
            $p.ExitCode | Should -Be 0
            $ctx.Events.Count | Should -Be 2
            $ctx.Events[0].type | Should -Be 'done'
            $ctx.Events[0].origin | Should -Be 'desktop'
            $ctx.Events[0].late | Should -Be $true
            $ctx.Events[0].ts | Should -Be ([DateTimeOffset]::FromUnixTimeSeconds($old).UtcDateTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"))
            @(Get-ChildItem $qdir).Count | Should -Be 0
            $ctx.Events[1].type | Should -Be 'permission'
            $ctx.Events[1].PSObject.Properties['late'] | Should -Be $null
            $ctx.Events[1].preview | Should -Be 'Разрешить?'
            $ctx.Events[1].project | Should -Be 'shop'
            $ctx.Events[1].device | Should -Be $a.Device.id
        }
        finally {
            $env:HOME = $oldHome
            [void](Stop-NotifierHttpServer -Server $server)
        }
    }

    It 'hook.sh: ПК недоступен → код 0 без вывода' -Skip:(-not $shPath) {
        $macHome = Join-Path $TestDrive 'machome2'
        New-Item -ItemType Directory -Path (Join-Path $macHome '.claude-notifier') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $macHome '.claude-notifier\env'), "CN_URL='http://127.0.0.1:9'`nCN_URL2=''`nCN_TOKEN='x'`n", (New-Object Text.UTF8Encoding $false))
        $oldHome = $env:HOME
        try {
            $env:HOME = $macHome
            $out = '{"session_id":"q1"}' | & $shPath (Join-Path $repoRoot 'src\mac\hook.sh') stop 2>&1
            $LASTEXITCODE | Should -Be 0
            "$out" | Should -Be ''
            # Событие не потеряно: ждёт в очереди до следующей связи с ПК
            $queued = @(Get-ChildItem (Join-Path $macHome '.claude-notifier\queue') -Filter '*.ev')
            $queued.Count | Should -Be 1
            $queued[0].Name | Should -Match '^\d+\.\d+\.stop\.[A-Za-z0-9_-]+\.ev$'
        }
        finally { $env:HOME = $oldHome }
    }

    It 'скрипты для Mac проходят проверку синтаксиса sh -n' -Skip:(-not $shPath) {
        $ctx = New-Ctx (Join-Path $TestDrive 'syntax')
        $a = Add-NotifierDevice -Network $ctx.Network -Name 'Mac'
        $ctx.InstallCodes['code12345678'] = @{ DeviceId = $a.Device.id; Expires = [DateTime]::UtcNow.AddMinutes(5) }
        $install = Join-Path $TestDrive 'install.sh'
        [IO.File]::WriteAllText($install, (Invoke-NotifierHttpRequest -Request (New-Req GET '/install/code12345678') -Ctx $ctx).Body, (New-Object Text.UTF8Encoding $false))
        foreach ($f in @($install, (Join-Path $repoRoot 'src\mac\hook.sh'), (Join-Path $repoRoot 'src\mac\uninstall.sh'))) {
            & $shPath -n $f 2>&1 | Out-Null
            $LASTEXITCODE | Should -Be 0
        }
    }
}

Describe 's_007_01 · ответы на Mac' {
    It 'сервер: запрос разрешения с Mac → решение с телефона → хук получает JSON; чужой сеанс — нельзя; срок продлевается опросом' {
        $ctx = New-Ctx (Join-Path $TestDrive 'macreq')
        $mac = (Add-NotifierDevice -Network $ctx.Network -Name 'MacBook').Device
        $hookTok = Add-NotifierDeviceToken -Device $mac -Hook
        $phoneTok = (Add-NotifierDevice -Network $ctx.Network -Name 'iPhone').Token
        $mb = @{ authorization = "Bearer $hookTok" }
        # hello с replies — у устройства есть ответы
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/hello' '{"name":"MacBook","replies":true}' $mb) -Ctx $ctx).Status | Should -Be 200
        $mac.replies | Should -Be $true
        $perm = '{"session_id":"m1","cwd":"/Users/a/dev/shop","tool_name":"Bash","tool_input":{"command":"npm test"}}'
        # CLI без ожидания (cliWaitSeconds = 0) — запрос не создаётся, Claude спросит сам
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/permreq' $perm $mb @{ entry = 'cli' }) -Ctx $ctx).Status | Should -Be 204
        $r = Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/permreq' $perm $mb @{ entry = 'claude-desktop' }) -Ctx $ctx
        $r.Status | Should -Be 200
        $j = $r.Body | ConvertFrom-Json
        $j.wait | Should -Be 600
        $ctx.Events[-1].type | Should -Be 'request'   # как от моста на ПК: статус «Нужно разрешение» и кнопки
        $ctx.Events[-1].device | Should -Be $mac.id
        $ctx.Events[-1].request_id | Should -Be $j.id
        # Пока не решено — 204, срок продлевается
        $reqFile = Join-Path $ctx.DataRoot "requests\perm-$($j.id).json"
        $e0 = (Get-Content $reqFile -Raw | ConvertFrom-Json).expires
        Start-Sleep -Milliseconds 30
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/decision' '' $mb @{ id = $j.id }) -Ctx $ctx).Status | Should -Be 204
        ((Get-Content $reqFile -Raw | ConvertFrom-Json).expires -gt $e0) | Should -Be $true
        # Решение с телефона (cookie браузера) → хук Mac получает JSON для Claude Code
        $ph = @{ cookie = "cn_token=$phoneTok" }
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/decision' (ConvertTo-Json @{ id = $j.id; behavior = 'allow' }) $ph) -Ctx $ctx).Status | Should -Be 200
        $d = Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/decision' '' $mb @{ id = $j.id }) -Ctx $ctx
        $d.Status | Should -Be 200
        ($d.Body | ConvertFrom-Json).hookSpecificOutput.decision.behavior | Should -Be 'allow'
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/decision' '' $mb @{ id = $j.id }) -Ctx $ctx).Status | Should -Be 410
        # Снять запрос (решили в Claude на Mac)
        $j2 = (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/permreq' $perm $mb @{ entry = 'claude-desktop' }) -Ctx $ctx).Body | ConvertFrom-Json
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/done' '{}' $mb @{ id = $j2.id }) -Ctx $ctx).Status | Should -Be 200
        Test-Path (Join-Path $ctx.DataRoot "requests\perm-$($j2.id).json") | Should -Be $false
        # Чужой сеанс (этого ПК) — ни запроса, ни ожидания
        Save-NotifierSessions -Sessions @([pscustomobject]@{ session_id = 'pc1'; device = ''; state = 'waiting'; project = 'p' }) -DataRoot $ctx.DataRoot
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/permreq' '{"session_id":"pc1","tool_name":"Bash","tool_input":{}}' $mb @{ entry = 'claude-desktop' }) -Ctx $ctx).Status | Should -Be 403
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/replywait' '{"session_id":"pc1"}' $mb) -Ctx $ctx).Status | Should -Be 403
        # Быстрый ответ: ожидание → ответ с телефона → хук Mac получает текст
        $w = Invoke-NotifierHttpRequest -Request (New-Req POST '/api/mac/replywait' '{"session_id":"m1"}' $mb) -Ctx $ctx
        ($w.Body | ConvertFrom-Json).minutes | Should -Be 60
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/reply' '' $mb @{ session = 'm1' }) -Ctx $ctx).Status | Should -Be 204
        (Invoke-NotifierHttpRequest -Request (New-Req POST '/api/reply' '{"session":"m1","text":"Да, продолжай"}' $ph) -Ctx $ctx).Status | Should -Be 200
        $t = Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/reply' '' $mb @{ session = 'm1' }) -Ctx $ctx
        $t.Status | Should -Be 200
        $t.Body | Should -Be 'Да, продолжай'
        (Invoke-NotifierHttpRequest -Request (New-Req GET '/api/mac/reply' '' $mb @{ session = 'm1' }) -Ctx $ctx).Status | Should -Be 410
        # Служебное «Работает» после ответа не уводит сеанс Mac на этот ПК
        $list = Update-NotifierSessionList -Sessions @([pscustomobject]@{ session_id = 'm1'; device = $mac.id; state = 'waiting'; project = 'shop' }) -Event ([pscustomobject]@{ type = 'working'; session_id = 'm1'; ts = '2026-11-18T10:00:00Z' })
        @($list)[0].device | Should -Be $mac.id
    }

    It 'hook.sh permreq и replywait (через sh): ждут ответа с ПК и отдают его Claude' -Skip:(-not $shPath) {
        $ctx = New-Ctx (Join-Path $TestDrive 'macsh')
        $mac = (Add-NotifierDevice -Network $ctx.Network -Name 'MacBook').Device
        $hookTok = Add-NotifierDeviceToken -Device $mac -Hook
        $port = (Get-FreePort)
        $macHome = Join-Path $TestDrive 'machome3'
        New-Item -ItemType Directory -Path (Join-Path $macHome '.claude-notifier') -Force | Out-Null
        $utf8 = New-Object Text.UTF8Encoding $false
        [IO.File]::WriteAllText((Join-Path $macHome '.claude-notifier\env'), "CN_URL='http://localhost:$port'`nCN_URL2=''`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $macHome '.claude-notifier\auth'), "Authorization: Bearer $hookTok`n", $utf8)
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $server = Start-NotifierHttpServer -Prefix "http://localhost:$port/" -Queue $q
        $oldHome = $env:HOME; $oldEntry = $env:CLAUDE_CODE_ENTRYPOINT
        $serve = { param($Until) $deadline = [DateTime]::UtcNow.AddSeconds(25); while (-not (& $Until) -and [DateTime]::UtcNow -lt $deadline) { $c = $null; if ($q.TryDequeue([ref]$c)) { Write-NotifierHttpResponse -Context $c -Response (Invoke-NotifierHttpRequest -Request (ConvertFrom-NotifierHttpContext -Context $c) -Ctx $ctx) }; Start-Sleep -Milliseconds 20 } }
        $hook = (Join-Path $repoRoot 'src\mac\hook.sh')
        try {
            $env:HOME = $macHome; $env:CLAUDE_CODE_ENTRYPOINT = 'claude-desktop'
            # Запрос разрешения: хук ждёт, решение «разрешить» с ПК → JSON на stdout, код 0
            $in = Join-Path $TestDrive 'perm.json'; $out = Join-Path $TestDrive 'perm.out'
            [IO.File]::WriteAllText($in, '{"session_id":"m2","cwd":"/Users/a/dev/shop","tool_name":"Bash","tool_input":{"command":"npm test"}}', $utf8)
            $p = Start-Process -FilePath $shPath -ArgumentList @("`"$hook`"", 'permreq') -RedirectStandardInput $in -RedirectStandardOutput $out -NoNewWindow -PassThru
            [void]$p.Handle
            & $serve { @((Get-NotifierPendingRequests -DataRoot $ctx.DataRoot).Permissions).Count -gt 0 }
            $req = @((Get-NotifierPendingRequests -DataRoot $ctx.DataRoot).Permissions)[0]
            $req.device | Should -Be $mac.id
            [void](Write-NotifierDecision -RequestId $req.id -Behavior allow -DataRoot $ctx.DataRoot)
            & $serve { $p.HasExited }
            $p.WaitForExit(3000) | Out-Null
            $p.ExitCode | Should -Be 0
            ((Get-Content $out -Raw) | ConvertFrom-Json).hookSpecificOutput.decision.behavior | Should -Be 'allow'
            # Быстрый ответ: хук ждёт, ответ с ПК → текст в stderr, код 2 (Claude получит сообщение)
            $in2 = Join-Path $TestDrive 'stop.json'; $err2 = Join-Path $TestDrive 'stop.err'
            [IO.File]::WriteAllText($in2, '{"session_id":"m2","cwd":"/Users/a/dev/shop"}', $utf8)
            $p2 = Start-Process -FilePath $shPath -ArgumentList @("`"$hook`"", 'replywait') -RedirectStandardInput $in2 -RedirectStandardError $err2 -NoNewWindow -PassThru
            [void]$p2.Handle
            & $serve { (Get-NotifierPendingRequests -DataRoot $ctx.DataRoot).Replies.ContainsKey('m2') }
            (Write-NotifierReply -SessionId 'm2' -Text 'Да, продолжай' -DataRoot $ctx.DataRoot) | Should -Be $true
            & $serve { $p2.HasExited }
            $p2.WaitForExit(3000) | Out-Null
            $p2.ExitCode | Should -Be 2
            [IO.File]::ReadAllText($err2, [Text.Encoding]::UTF8) | Should -Match 'Да, продолжай'
        }
        finally {
            $env:HOME = $oldHome; $env:CLAUDE_CODE_ENTRYPOINT = $oldEntry
            [void](Stop-NotifierHttpServer -Server $server)
        }
    }
}

Describe 's_007_01 · settings.js (слияние хуков на Mac)' {
    It 'install добавляет 6 хуков, чужие сохраняет, повтор без дублей; uninstall убирает только свои' -Skip:(-not $node) {
        $js = (Join-Path $repoRoot 'src\mac\settings.js').Replace('\', '/')
        $code = @"
const { mergeHooks } = require('$js');
const hook = '/Users/a b/.claude-notifier/hook.sh';
let s = { model: 'opus', hooks: { Stop: [ { hooks: [ { type: 'command', command: '/my/stop.sh' } ] } ] } };
s = mergeHooks(s, 'install', hook);
s = mergeHooks(s, 'install', hook);
const ours = Object.values(s.hooks).flat().flatMap(g => g.hooks).filter(h => h.command.includes('.claude-notifier/hook.sh'));
const out = { events: Object.keys(s.hooks).sort(), ours: ours.length, stop: s.hooks.Stop.length,
  cmd: s.hooks.UserPromptSubmit[0].hooks[0].command,
  async: ours.filter(h => !/ (permreq|replywait)$/.test(h.command)).every(h => h.async === true),
  perm: s.hooks.PermissionRequest[0].hooks[0], rewake: s.hooks.Stop.flatMap(g => g.hooks).find(h => / replywait$/.test(h.command)),
  matcher: s.hooks.Notification[0].matcher };
const u = mergeHooks(s, 'uninstall', hook);
out.after = JSON.stringify(u);
console.log(JSON.stringify(out));
"@
        $r = node -e $code | ConvertFrom-Json
        ($r.events -join ',') | Should -Be 'Notification,PermissionRequest,SessionEnd,SessionStart,Stop,StopFailure,UserPromptSubmit'
        $r.ours | Should -Be 8
        $r.stop | Should -Be 3   # свой хук пользователя + событие + ожидание быстрого ответа
        # Запрос разрешения — синхронный (Claude ждёт решения с ПК); быстрый ответ — asyncRewake
        $r.perm.timeout | Should -Be 610
        $null -eq $r.perm.async | Should -Be $true
        $r.rewake.asyncRewake | Should -Be $true
        $r.rewake.timeout | Should -Be 14700
        $r.cmd | Should -Be "'/Users/a b/.claude-notifier/hook.sh' prompt"
        $r.async | Should -Be $true
        $r.matcher | Should -Be 'permission_prompt|elicitation_dialog|agent_needs_input'
        $r.after | Should -Be '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"/my/stop.sh"}]}]}}'
    }
}

Describe 's_007_01 · трей и устройства' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('tray-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
    }

    It 'событие с устройства: уведомления выключены → только статус; включены → показ; отключено → отброшено' {
        $q = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $quiet = (Add-NotifierDevice -Network $script:Net.Network -Name 'MacQuiet').Device
        $loud = (Add-NotifierDevice -Network $script:Net.Network -Name 'MacLoud').Device
        $loud.notify = $true
        Mock Show-NotifierToast { $true }
        Mock Invoke-NotifierSound { $true }
        foreach ($x in @(@('a', $quiet.id), @('b', $loud.id), @('c', 'dgone'))) {
            $q.Enqueue([pscustomobject]@{ v = 1; id = [guid]::NewGuid().ToString(); ts = [DateTime]::UtcNow.ToString('o'); type = 'done'; title = 't'; preview = 'p'; session_id = $x[0]; origin = 'cli'; project = 'p'; device = $x[1]; window = $null })
        }
        Invoke-NotifierEventBatch -Queue $q -DataRoot $script:TrayDataRoot -NoOutput | Out-Null
        $sessions = @(Get-NotifierSessions -DataRoot $script:TrayDataRoot)
        ($sessions | ForEach-Object { $_.session_id } | Sort-Object) -join ',' | Should -Be 'a,b'
        @(Get-NotifierHistory -DataRoot $script:TrayDataRoot).Count | Should -Be 1
        Test-NotifierRemoteEventMuted -Event ([pscustomobject]@{ type = 'done' }) | Should -Be 'show'
    }

    It 'отключение устройства удаляет его сеансы' {
        $d = (Add-NotifierDevice -Network $script:Net.Network -Name 'Mac').Device
        Save-NotifierSessions -Sessions @(
            [pscustomobject]@{ session_id = 'local'; device = ''; updated = [DateTime]::UtcNow.ToString('o'); window = $null },
            [pscustomobject]@{ session_id = 'remote'; device = $d.id; updated = [DateTime]::UtcNow.ToString('o'); window = $null }
        ) -DataRoot $script:TrayDataRoot
        Remove-NotifierDeviceAndSessions -Id $d.id | Should -Be $true
        (@(Get-NotifierSessions -DataRoot $script:TrayDataRoot) | ForEach-Object { $_.session_id }) -join ',' | Should -Be 'local'
        (Get-NotifierNetwork -DataRoot $script:TrayDataRoot).devices.Count | Should -Be 0
        Get-NotifierDeviceName $d.id | Should -Be 'Отключено'
        Get-NotifierDeviceName '' | Should -Be 'Этот ПК'
    }

    It 'вкладка «Устройства»: карточка доступа, карточки устройств, число сеансов, подзаголовок' {
        $ui = New-NotifierDevicesPage -Theme (Get-NotifierTheme)
        Update-NotifierDevicesView -Ui $ui
        $ui.NetTitle.Text | Should -Be 'Доступ из сети'
        $ui.NetSub.Text | Should -Be 'Выключен — Mac и телефон не видят этот ПК'
        $ui.NetSwitch.Checked | Should -Be $false
        $ui.Devices.Count | Should -Be 1   # только строка «Подключить устройство…»
        $ui.Devices[0].IsAction | Should -Be $true
        Format-NotifierDevicesSubtitle | Should -Be "Нет подключённых устройств $([char]0x00B7) доступ из сети выключен"
        $d = (Add-NotifierDevice -Network $script:Net.Network -Name 'MacBook').Device
        $d.hooks = $true
        Update-NotifierDevicesView -Ui $ui -Sessions @([pscustomobject]@{ device = $d.id }, [pscustomobject]@{ device = $d.id }, [pscustomobject]@{ device = '' })
        $ui.Devices.Count | Should -Be 2
        $ui.Devices[0].Section | Should -Be 'Устройства'
        $ui.Devices[0].Title | Should -Be 'MacBook'
        $ui.Devices[0].State | Should -Be 'online'
        $ui.Devices[0].StateText | Should -Be 'В сети'
        $ui.Devices[0].Meta | Should -Be "Mac · сеансы видны здесь $([char]0x00B7) 2 сеанса"
        $d.notify = $true; $d.last_seen = ''
        Update-NotifierDevicesView -Ui $ui
        $ui.Devices[0].StateText | Should -Be 'Ещё не на связи'
        $ui.Devices[0].HollowDot | Should -Be $true
        $ui.Devices[0].Meta | Should -Match 'нет сеансов · уведомления на ПК$'
        Format-NotifierDevicesSubtitle | Should -Be "1 устройство $([char]0x00B7) доступ из сети выключен"
        $script:Net.Network.enabled = $true; $script:Net.Error = 'Access is denied'
        Update-NotifierDevicesView -Ui $ui
        $ui.NetSub.Text | Should -Be 'Сервер не запустился: Access is denied'
        $ui.NetSwitch.Checked | Should -Be $true
        Format-NotifierSessionCount 3 | Should -Be '3 сеанса'
        Format-NotifierSessionCount 11 | Should -Be '11 сеансов'
        Format-NotifierSessionCount 21 | Should -Be '21 сеанс'
        $ui.Page.Dispose()
    }

    It 'окно сеансов с вкладкой «Устройства»; удалённый сеанс не пытается фокусировать окно' {
        $d = (Add-NotifierDevice -Network $script:Net.Network -Name 'MacBook').Device
        Save-NotifierSessions -Sessions @([pscustomobject]@{ session_id = 'r'; project = 'x'; device = $d.id; state = 'working'; since = ''; updated = [DateTime]::UtcNow.ToString('o'); preview = ''; window = $null }) -DataRoot $script:TrayDataRoot
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            $script:SessionsForm.Tag.Net | Should -Not -Be $null
            [void](Invoke-NotifierSessionsRefresh)
            $cards = $script:SessionsForm.Tag.Cards
            $cards[0].Meta | Should -Be 'Терминал'
            $cards[0].Section | Should -Be 'MacBook'
            $cards.Select(0)
            Mock Set-SessionWindowFocus { 'focused' }
            Invoke-NotifierSelectedSession -Action focus
            Assert-MockCalled Set-SessionWindowFocus -Times 0 -Scope It
            $script:SessionsForm.Tag.Subtitle.Text | Should -Be 'Этот сеанс идёт на устройстве «MacBook»'
            $script:SessionsForm.Tag.Net.Devices[0].Meta | Should -Match '1 сеанс'
            $script:SessionsForm.Tag.Tabs.SelectedIndex = 1
            $script:SessionsForm.Tag.Title.Text | Should -Be 'Устройства'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }

    It 'HTTP-пакет трея: события устройств уходят в очередь трея, PIN-подключение сохраняется в network.json' {
        $port = (Get-FreePort)
        $script:Net.Server = Start-NotifierHttpServer -Prefix "http://localhost:$port/" -Queue $script:Net.Queue
        $script:Net.Pairing = New-NotifierPairing
        $eventQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        $client = New-Object System.Net.Http.HttpClient
        try {
            $content = New-Object System.Net.Http.StringContent("pin=$($script:Net.Pairing.Pin)", [Text.Encoding]::UTF8, 'application/x-www-form-urlencoded')
            $task = $client.PostAsync("http://localhost:$port/login", $content)
            $deadline = [DateTime]::UtcNow.AddSeconds(5)
            while (-not $task.IsCompleted -and [DateTime]::UtcNow -lt $deadline) { [void](Invoke-NotifierHttpBatch -EventQueue $eventQueue); Start-Sleep -Milliseconds 20 }
            $task.Result.Content.ReadAsStringAsync().Result | Should -Match 'Сеансы Claude'   # 303 → / с cookie
            (Get-NotifierNetwork -DataRoot $script:TrayDataRoot).devices.Count | Should -Be 1
        }
        finally {
            $client.Dispose()
            Stop-NotifierNetServer
        }
        $script:Net.Server | Should -Be $null
    }
}
