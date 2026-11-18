Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Event.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sessions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Devices.psm1')
Import-Module (Join-Path $PSScriptRoot 'Requests.psm1')
Import-Module (Join-Path $PSScriptRoot 'Transcript.psm1')
Import-Module (Join-Path $PSScriptRoot 'Text.psm1')

# HTTP-сервер для устройств в локальной сети (ADR-007).
# Фоновый runspace только принимает соединения (GetContext) и кладёт их в очередь; разбор запроса,
# проверка токена и ответ — в UI-потоке трея (Invoke-NotifierHttpRequest), где живут все данные.
$script:MaxBodyBytes = 262144
$script:CookieName = 'cn_token'
$script:InstallCodeMinutes = 10
$script:AppRoot = Split-Path -Parent $PSScriptRoot   # …\app (или src в репозитории)
$script:StaticFiles = @{
    '/mac/hook.sh'      = @('mac\hook.sh', 'text/plain; charset=utf-8')
    '/mac/settings.js'  = @('mac\settings.js', 'text/plain; charset=utf-8')
    '/mac/uninstall.sh' = @('mac\uninstall.sh', 'text/plain; charset=utf-8')
}

# Тело запроса читается здесь, в фоновом runspace, с жёстким сроком: медленный или зависший клиент
# (Content-Length есть, байтов нет) не должен блокировать UI-поток трея. Не уложился — соединение обрывается.
$script:AcceptLoop = {
    param($Listener, $Queue, [int]$MaxBody, [int]$BodyMs)
    while ($Listener.IsListening) {
        try { $ctx = $Listener.GetContext() } catch { break }
        $item = @{ Context = $ctx; Body = ''; TooLarge = $false }
        try {
            $r = $ctx.Request
            if ($r.HasEntityBody) {
                if ($r.ContentLength64 -gt $MaxBody) { $item.TooLarge = $true }
                else {
                    $buffer = New-Object byte[] ($MaxBody + 1)
                    $total = 0
                    $deadline = [DateTime]::UtcNow.AddMilliseconds($BodyMs)
                    $timedOut = $false
                    while ($total -le $MaxBody) {
                        $left = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
                        if ($left -le 0) { $timedOut = $true; break }
                        $task = $r.InputStream.ReadAsync($buffer, $total, $buffer.Length - $total)
                        if (-not $task.Wait($left)) { $timedOut = $true; break }
                        if ($task.Result -le 0) { break }
                        $total += $task.Result
                    }
                    if ($timedOut) { try { $ctx.Response.Abort() } catch { }; continue }
                    if ($total -gt $MaxBody) { $item.TooLarge = $true }
                    else { $item.Body = [Text.Encoding]::UTF8.GetString($buffer, 0, $total) }
                }
            }
        }
        catch { try { $ctx.Response.Abort() } catch { }; continue }
        $Queue.Enqueue([pscustomobject]$item)
    }
}
$script:BodyTimeoutMs = 3000

function Get-NotifierHttpPrefix {
    <# .SYNOPSIS Префикс HttpListener для всех адресов ПК: http://+:<port>/ (нужна резервация URL, setup-network.ps1). #>
    param([Parameter(Mandatory = $true)][int]$Port)
    return "http://+:$Port/"
}

function Start-NotifierHttpServer {
    <#
    .SYNOPSIS
    Запускает HttpListener на Prefix; принятые соединения (HttpListenerContext) кладутся в Queue.
    Ошибка запуска (нет резервации URL, порт занят) — исключение.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Prefix,
        [Parameter(Mandatory = $true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Queue
    )
    $listener = New-Object System.Net.HttpListener
    $listener.Prefixes.Add($Prefix)
    $listener.IgnoreWriteExceptions = $true
    $listener.Start()
    try {
        $listener.TimeoutManager.EntityBody = [TimeSpan]::FromSeconds(5)
        $listener.TimeoutManager.IdleConnection = [TimeSpan]::FromSeconds(30)
    }
    catch { }
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:AcceptLoop.ToString()).AddArgument($listener).AddArgument($Queue).AddArgument($script:MaxBodyBytes).AddArgument($script:BodyTimeoutMs)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{ Prefix = $Prefix; Listener = $listener; PowerShell = $ps; Runspace = $runspace; Handle = $handle }
}

function Stop-NotifierHttpServer {
    <# .SYNOPSIS Останавливает сервер. Возвращает $true, если фоновый runspace завершился. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Server, [int]$TimeoutMs = 3000)
    try { $Server.Listener.Stop() } catch { }
    try { $Server.Listener.Close() } catch { }
    $finished = $Server.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)
    if ($finished) { try { [void]$Server.PowerShell.EndInvoke($Server.Handle) } catch { } }
    else { $Server.PowerShell.Stop() }
    $Server.PowerShell.Dispose()
    $Server.Runspace.Dispose()
    return $finished
}

function ConvertFrom-NotifierHttpContext {
    <#
    .SYNOPSIS
    HttpListenerContext → простой объект запроса @{ Method; Path; Query; Headers; Body; TooLarge; Remote }.
    Заголовки — с ключами в нижнем регистре. Тело — UTF-8, не больше MaxBodyBytes.
    #>
    param([Parameter(Mandatory = $true)]$Context)
    # Из очереди сервера приходит обёртка { Context; Body; TooLarge }: тело уже прочитано фоновым runspace.
    $pre = $null
    if ($Context -isnot [System.Net.HttpListenerContext] -and $Context.PSObject.Properties['Context']) { $pre = $Context; $Context = $pre.Context }
    $r = $Context.Request
    $headers = @{}
    foreach ($k in $r.Headers.AllKeys) { $headers[$k.ToLowerInvariant()] = $r.Headers[$k] }
    $query = @{}
    foreach ($k in $r.QueryString.AllKeys) { if ($k) { $query[$k] = $r.QueryString[$k] } }
    $body = ''
    $tooLarge = $false
    if ($pre) { $body = [string]$pre.Body; $tooLarge = [bool]$pre.TooLarge }
    elseif ($r.HasEntityBody) {
        if ($r.ContentLength64 -gt $script:MaxBodyBytes) { $tooLarge = $true }
        else {
            $buffer = New-Object byte[] ($script:MaxBodyBytes + 1)
            $total = 0
            while ($total -le $script:MaxBodyBytes) {
                $n = $r.InputStream.Read($buffer, $total, $buffer.Length - $total)
                if ($n -le 0) { break }
                $total += $n
            }
            if ($total -gt $script:MaxBodyBytes) { $tooLarge = $true }
            else { $body = [Text.Encoding]::UTF8.GetString($buffer, 0, $total) }
        }
    }
    return @{
        Method   = $r.HttpMethod.ToUpperInvariant()
        Path     = $r.Url.AbsolutePath
        Query    = $query
        Headers  = $headers
        Body     = $body
        TooLarge = $tooLarge
        Remote   = [string]$r.RemoteEndPoint.Address
    }
}

function Write-NotifierHttpResponse {
    <# .SYNOPSIS Отправляет ответ Invoke-NotifierHttpRequest в HttpListenerContext и закрывает его. #>
    param([Parameter(Mandatory = $true)]$Context, [Parameter(Mandatory = $true)][hashtable]$Response)
    if ($Context -isnot [System.Net.HttpListenerContext] -and $Context.PSObject.Properties['Context']) { $Context = $Context.Context }
    $resp = $Context.Response
    try {
        $resp.StatusCode = $Response.Status
        $resp.ContentType = $Response.ContentType
        $resp.Headers.Add('Cache-Control', 'no-store')
        $resp.Headers.Add('X-Content-Type-Options', 'nosniff')
        # same-origin, а не no-referrer: при no-referrer браузер шлёт «Origin: null» даже со своей страницы
        # (форма PIN, fetch), и проверка Origin отклоняла их. С same-origin свои запросы несут настоящий Origin,
        # а со сторонних сайтов — по-прежнему «null» (и отклоняются). Наружу адрес страницы не уходит.
        $resp.Headers.Add('Referrer-Policy', 'same-origin')
        foreach ($h in $Response.Headers) {
            if ($h[0] -eq 'Location') { $resp.RedirectLocation = $h[1] }
            else { $resp.Headers.Add($h[0], $h[1]) }
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes([string]$Response.Body)
        $resp.ContentLength64 = $bytes.Length
        if ($bytes.Length -gt 0) { $resp.OutputStream.Write($bytes, 0, $bytes.Length) }
    }
    finally { try { $resp.Close() } catch { } }
}

function New-HttpResponse([int]$Status, [string]$Body = '', [string]$ContentType = 'text/plain; charset=utf-8') {
    return @{ Status = $Status; Body = $Body; ContentType = $ContentType; Headers = New-Object System.Collections.ArrayList }
}

function New-JsonResponse([int]$Status, $Object) {
    return (New-HttpResponse $Status (ConvertTo-Json -InputObject $Object -Depth 6 -Compress) 'application/json; charset=utf-8')
}

function ConvertTo-HtmlText([AllowNull()][string]$Text) {
    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Get-RequestToken([hashtable]$Request) {
    # Токен из «Authorization: Bearer …» (хуки Mac) или из cookie cn_token (браузер).
    $auth = [string]$Request.Headers['authorization']
    if ($auth -match '^Bearer\s+(\S+)$') { return $Matches[1] }
    $cookie = [string]$Request.Headers['cookie']
    foreach ($part in ($cookie -split ';')) {
        $kv = $part.Trim() -split '=', 2
        if ($kv.Count -eq 2 -and $kv[0] -eq $script:CookieName) { return $kv[1] }
    }
    return ''
}

function Get-FormValue([string]$Body, [string]$Name) {
    foreach ($pair in ($Body -split '&')) {
        $kv = $pair -split '=', 2
        if ($kv.Count -eq 2 -and [Uri]::UnescapeDataString($kv[0]) -eq $Name) { return [Uri]::UnescapeDataString($kv[1].Replace('+', ' ')) }
    }
    return ''
}

function Get-WebTemplate([string]$Name, [hashtable]$Values) {
    # Переводы строк — только LF: скрипты для Mac с CRLF не выполняются в sh.
    $text = [IO.File]::ReadAllText((Join-Path $script:AppRoot "web\$Name"), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
    foreach ($k in $Values.Keys) { $text = $text.Replace("__$($k)__", [string]$Values[$k]) }
    return $text
}

function Get-StaticText([string]$Path) {
    # Файлы для Mac — с LF, как их получит Mac (по нему же считается SHA-256 для install.sh).
    return [IO.File]::ReadAllText((Join-Path $script:AppRoot $script:StaticFiles[$Path][0]), [Text.Encoding]::UTF8).Replace("`r`n", "`n")
}

function Get-StaticSha256([string]$Path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash((New-Object System.Text.UTF8Encoding $false).GetBytes((Get-StaticText $Path))) } finally { $sha.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Get-NotifierServerBaseUrl([hashtable]$Ctx) {
    $address = $Ctx.Address
    if ([string]::IsNullOrEmpty($address)) { $address = '127.0.0.1' }
    return "http://$($address):$($Ctx.Network.port)"
}

function Get-LoginPage([hashtable]$Ctx, [string]$Message, [int]$Status = 200) {
    $html = Get-WebTemplate 'login.html' @{ PCNAME = (ConvertTo-HtmlText $Ctx.PcName); MESSAGE = (ConvertTo-HtmlText $Message) }
    return (New-HttpResponse $Status $html 'text/html; charset=utf-8')
}

function Get-NotifierSessionsPayload {
    <# .SYNOPSIS Данные для /api/sessions: сеансы всех устройств (живые, в порядке окна) и устройства. #>
    param([Parameter(Mandatory = $true)][hashtable]$Ctx, [datetime]$Now = [DateTime]::UtcNow)
    $names = @{ '' = 'Этот ПК'; 'local' = 'Этот ПК' }
    $devices = @()
    foreach ($d in $Ctx.Network.devices) {
        $names[[string]$d.id] = [string]$d.name
        $devices += [ordered]@{ id = [string]$d.id; name = [string]$d.name; kind = [string]$d.kind; seen = (Format-NotifierLastSeen -Ts ([string]$d.last_seen) -Now $Now) }
    }
    $all = @(Get-NotifierSessions -DataRoot $Ctx.DataRoot)
    $live = Select-NotifierLiveSessions -Sessions $all -Now $Now
    $pending = Get-NotifierPendingRequests -DataRoot $Ctx.DataRoot
    $items = @()
    $prefs = Get-NotifierSessionPrefs -DataRoot $Ctx.DataRoot
    $pinned = @($prefs.Keys | Where-Object { $prefs[$_].pinned })
    foreach ($s in (Get-NotifierSortedSessions -Sessions $live -Pinned $pinned)) {
        $dev = ''
        if ($s.PSObject.Properties['device']) { $dev = [string]$s.device }
        $devName = $names[$dev]
        if ($null -eq $devName) { $devName = 'Устройство отключено' }
        $stalled = [string]$s.state -eq 'working' -and $s.PSObject.Properties['stalledSince'] -and [string]$s.stalledSince -ne ''
        $items += [ordered]@{
            device      = $dev
            device_name = $devName
            project     = [string]$s.project
            title       = $(if ($prefs.ContainsKey([string]$s.session_id) -and $prefs[[string]$s.session_id].title) { [string]$prefs[[string]$s.session_id].title } else { [string]$s.project })
            pinned      = ($prefs.ContainsKey([string]$s.session_id) -and [bool]$prefs[[string]$s.session_id].pinned)
            context     = $(if ($s.PSObject.Properties['stats'] -and $s.stats -and $s.stats.PSObject.Properties['window']) { [int]$s.stats.percent } else { -1 })
            state       = $(if ($stalled) { 'error' } else { [string]$s.state })
            state_text  = $(if ($stalled) { 'Похоже, остановился' } elseif (Get-NotifierAgentsStateText $s) { Get-NotifierAgentsStateText $s } else { Get-NotifierSessionStateText ([string]$s.state) })
            elapsed     = $(if ($stalled) { Format-NotifierElapsed -Ts ([string]$s.stalledSince) -Now $Now } else { Format-NotifierElapsed -Ts ([string]$s.since) -Now $Now })
            origin      = [string]$s.origin
            preview     = (ConvertTo-NotifierPlainText ([string]$s.preview))
            id          = [string]$s.session_id
            details     = ((Format-NotifierSessionDetails -Session $s -Now $Now) -replace "`t", ': ')
            request     = $null
            can_reply   = $false
        }
        if ($dev -eq '') {
            $sid = [string]$s.session_id
            $req = @($pending.Permissions | Where-Object { [string]$_.session_id -eq $sid }) | Select-Object -First 1
            if ($req) {
                $items[-1].request = [ordered]@{ id = [string]$req.id; kind = [string]$req.kind; title = [string]$req.title; detail = [string]$req.detail; options = @($req.options); can_always = [bool]$req.canAlways }
            }
            elseif ($pending.Replies.ContainsKey($sid) -and [string]$s.state -eq 'waiting') { $items[-1].can_reply = $true }
        }
    }
    return [ordered]@{ pc = $Ctx.PcName; devices = $devices; sessions = $items }
}

function Invoke-NotifierHttpRequest {
    <#
    .SYNOPSIS
    Обрабатывает один запрос и возвращает ответ @{ Status; ContentType; Body; Headers }.

    .DESCRIPTION
    Ctx — состояние трея: Network (network.json), Pairing (PIN), InstallCodes, DataRoot, Address, PcName.
    Побочные эффекты: Ctx.NetworkDirty = $true при изменении устройств, события хуков Mac
    добавляются в Ctx.Events, новое подключённое устройство — в Ctx.Paired.

    Маршруты:
      GET  /                  страница сеансов (с cookie) или вход по PIN
      POST /login             PIN → cookie на год
      GET  /api/me            это устройство
      GET  /api/sessions      сеансы всех устройств
      POST /api/install-link  одноразовая команда установки хуков на этот Mac
      GET  /install/<code>    скрипт установки (токен внутри)
      GET  /mac/*.sh|js       файлы для Mac без секретов
      POST /api/hello         Mac сообщает своё имя после установки (Bearer)
      POST /api/event         событие хука Mac (Bearer, ?kind=…&entry=…)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][hashtable]$Request,
        [Parameter(Mandatory = $true)][hashtable]$Ctx,
        [datetime]$Now = [DateTime]::UtcNow
    )
    if ($Request.TooLarge) { return (New-HttpResponse 413 'too large') }
    $path = [string]$Request.Path
    $method = [string]$Request.Method

    if ($method -eq 'GET' -and $script:StaticFiles.ContainsKey($path)) {
        return (New-HttpResponse 200 (Get-StaticText $path) $script:StaticFiles[$path][1])
    }

    # Защита от подделки запросов со сторонних страниц: Origin, если браузер его прислал, должен совпадать с Host.
    if ($method -eq 'POST') {
        $origin = [string]$Request.Headers['origin']
        $hostHeader = [string]$Request.Headers['host']
        if ($origin -ne '' -and $hostHeader -ne '') {
            $originHost = ''
            try { $originHost = ([Uri]$origin).Authority } catch { }
            if (-not [string]::Equals($originHost, $hostHeader, [StringComparison]::OrdinalIgnoreCase)) {
                # Форма PIN — понятная страница, а не JSON (например, если открыта старая копия страницы).
                if ($path -eq '/login') { return (Get-LoginPage $Ctx 'Обновите страницу и введите код ещё раз.' 403) }
                return (New-JsonResponse 403 @{ error = 'bad origin' })
            }
        }
    }

    if ($method -eq 'GET' -and $path -match '^/install/([A-Za-z0-9_-]{8,64})$') {
        $code = $Matches[1]
        $entry = $Ctx.InstallCodes[$code]
        $Ctx.InstallCodes.Remove($code)
        $device = $null
        if ($entry -and $Now -le $entry.Expires) { $device = Find-NotifierDevice -Network $Ctx.Network -Id $entry.DeviceId }
        if ($null -eq $device) {
            return (New-HttpResponse 200 "echo 'claude-notifier: ссылка установки устарела. Откройте страницу на этом Mac и нажмите «Установить» ещё раз.' >&2`nexit 1`n")
        }
        $token = Add-NotifierDeviceToken -Device $device -Hook
        $Ctx.NetworkDirty = $true
        $base = Get-NotifierServerBaseUrl $Ctx
        $alt = "http://$($Ctx.PcName.ToLowerInvariant()).local:$($Ctx.Network.port)"
        # SHA-256 файлов: install.sh сверяет скачанное и не ставит подменённые по дороге скрипты.
        $script = Get-WebTemplate 'install.sh' @{
            URL = $base; URL2 = $alt; TOKEN = $token; PCNAME = $Ctx.PcName
            SHA_HOOK = (Get-StaticSha256 '/mac/hook.sh'); SHA_SETTINGS = (Get-StaticSha256 '/mac/settings.js'); SHA_UNINSTALL = (Get-StaticSha256 '/mac/uninstall.sh')
        }
        Write-NotifierLog -Level INFO -Message "network: скрипт установки выдан устройству $($device.id)" -DataRoot $Ctx.DataRoot
        return (New-HttpResponse 200 $script)
    }

    if ($method -eq 'POST' -and $path -eq '/login') {
        $result = Test-NotifierPairingPin -Pairing $Ctx.Pairing -Pin (Get-FormValue $Request.Body 'pin') -Now $Now -Remote ([string]$Request.Remote)
        switch ($result) {
            'ok' {
                $name = Get-NotifierDeviceNameFromAgent ([string]$Request.Headers['user-agent'])
                $added = Add-NotifierDevice -Network $Ctx.Network -Name $name -Kind browser
                $Ctx.NetworkDirty = $true
                $Ctx.Paired = $added.Device
                Write-NotifierLog -Level INFO -Message "network: подключено устройство $($added.Device.id) ($name)" -DataRoot $Ctx.DataRoot
                $resp = New-HttpResponse 303 ''
                [void]$resp.Headers.Add(@('Set-Cookie', "$($script:CookieName)=$($added.Token); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax"))
                [void]$resp.Headers.Add(@('Location', '/'))
                return $resp
            }
            'bad' { return (Get-LoginPage $Ctx "Неверный код. Осталось попыток: $(Get-NotifierPairingAttemptsLeft -Pairing $Ctx.Pairing -Remote ([string]$Request.Remote))." 401) }
            default { return (Get-LoginPage $Ctx 'Код недействителен. На ПК нажмите «Подключить устройство» и введите новый код.' 401) }
        }
    }

    $auth = Resolve-NotifierToken -Network $Ctx.Network -Token (Get-RequestToken $Request)
    if ($null -eq $auth) {
        if ($method -eq 'GET' -and $path -eq '/') { return (Get-LoginPage $Ctx '') }
        return (New-JsonResponse 401 @{ error = 'unauthorized' })
    }
    $device = $auth.Device
    # Токен хуков Mac ходит по сети открытым текстом: ему — только отправка событий и знакомство.
    if ($auth.Scope -eq 'hook' -and -not ($method -eq 'POST' -and ($path -eq '/api/event' -or $path -eq '/api/hello'))) {
        return (New-JsonResponse 403 @{ error = 'hook token' })
    }
    # POST от браузера — только JSON: такой запрос со сторонней страницы требует CORS-проверки и не пройдёт.
    if ($method -eq 'POST' -and ([string]$Request.Headers['content-type']) -notmatch '^application/json') {
        return (New-JsonResponse 415 @{ error = 'json only' })
    }
    $device.last_seen = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
    $Ctx.NetworkDirty = $true

    if ($method -eq 'GET' -and $path -eq '/') {
        $html = Get-WebTemplate 'index.html' @{ PCNAME = (ConvertTo-HtmlText $Ctx.PcName) }
        return (New-HttpResponse 200 $html 'text/html; charset=utf-8')
    }
    if ($method -eq 'GET' -and $path -eq '/api/me') {
        return (New-JsonResponse 200 ([ordered]@{ id = [string]$device.id; name = [string]$device.name; kind = [string]$device.kind; hooks = [bool]$device.hooks; pc = $Ctx.PcName }))
    }
    if ($method -eq 'GET' -and $path -eq '/api/sessions') {
        return (New-JsonResponse 200 (Get-NotifierSessionsPayload -Ctx $Ctx -Now $Now))
    }
    if ($method -eq 'POST' -and ($path -eq '/api/decision' -or $path -eq '/api/reply')) {
        $body = $null
        try { $body = ConvertFrom-Json -InputObject $Request.Body -ErrorAction Stop } catch { }
        if ($null -eq $body) { return (New-JsonResponse 400 @{ error = 'bad json' }) }
        $sid = $null
        if ($path -eq '/api/decision') {
            $behavior = [string]$body.behavior
            if (@('allow', 'always', 'deny') -notcontains $behavior) { return (New-JsonResponse 400 @{ error = 'bad behavior' }) }
            $answer = ''
            if ($body.PSObject.Properties['answer']) { $answer = [string]$body.answer }
            $sid = Write-NotifierDecision -RequestId ([string]$body.id) -Behavior $behavior -Answer $answer -DataRoot $Ctx.DataRoot
        }
        else {
            if (Write-NotifierReply -SessionId ([string]$body.session) -Text ([string]$body.text) -DataRoot $Ctx.DataRoot) { $sid = [string]$body.session }
        }
        if (-not $sid) { return (New-JsonResponse 410 @{ error = 'gone' }) }   # уже решено в Claude или сеанс не ждёт
        # Служебное событие: трей сразу переведёт сеанс в «Работает».
        [void]$Ctx.Events.Add([pscustomobject]@{ v = 1; type = 'working'; title = 'working'; preview = ''; session_id = $sid; ts = $Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) })
        Write-NotifierLog -Level INFO -Message "network: ответ с устройства $($device.id): $path" -DataRoot $Ctx.DataRoot
        return (New-JsonResponse 200 @{ ok = $true })
    }
    if ($method -eq 'POST' -and $path -eq '/api/install-link') {
        $code = New-NotifierToken
        $Ctx.InstallCodes[$code] = @{ DeviceId = [string]$device.id; Expires = $Now.AddMinutes($script:InstallCodeMinutes) }
        $command = "curl -fsSL $(Get-NotifierServerBaseUrl $Ctx)/install/$code | sh"
        return (New-JsonResponse 200 @{ command = $command; minutes = $script:InstallCodeMinutes })
    }
    if ($method -eq 'POST' -and $path -eq '/api/hello') {
        $name = ''
        try { $name = [string](ConvertFrom-Json -InputObject $Request.Body -ErrorAction Stop).name } catch { }
        $name = ($name -replace '[\x00-\x1f]', '').Trim()
        if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
        if ($name -ne '') { $device.name = $name }
        $device.kind = 'mac'
        $device.hooks = $true
        $Ctx.Paired = $device
        Write-NotifierLog -Level INFO -Message "network: на устройстве $($device.id) установлены хуки" -DataRoot $Ctx.DataRoot
        return (New-JsonResponse 200 @{ ok = $true })
    }
    if ($method -eq 'POST' -and $path -eq '/api/event') {
        $kind = [string]$Request.Query['kind']
        $entry = [string]$Request.Query['entry']
        $event = ConvertTo-NotifierEvent -HookKind $kind -Json $Request.Body -EntryPoint $entry -HostSessionId '' -DataRoot $Ctx.DataRoot
        if ($null -eq $event) { return (New-JsonResponse 400 @{ error = 'bad event' }) }
        # Устройство меняет только свои сеансы: id сеансов ПК виден в /api/sessions, и без проверки
        # токен Mac мог бы перезаписать или «завершить» чужой сеанс.
        $owner = @(Get-NotifierSessions -DataRoot $Ctx.DataRoot) | Where-Object { [string]$_.session_id -eq [string]$event.session_id } | Select-Object -First 1
        $ownerDevice = ''
        if ($owner -and $owner.PSObject.Properties['device']) { $ownerDevice = [string]$owner.device }
        if ($owner -and $ownerDevice -ne [string]$device.id) { return (New-JsonResponse 403 @{ error = 'foreign session' }) }
        $event | Add-Member -NotePropertyName device -NotePropertyValue ([string]$device.id) -Force
        $event.title = "$($event.title) $([char]0x00B7) $($device.name)"
        [void]$Ctx.Events.Add($event)
        return (New-JsonResponse 200 @{ ok = $true })
    }
    return (New-JsonResponse 404 @{ error = 'not found' })
}

function Test-NotifierNetworkSetup {
    <#
    .SYNOPSIS
    Сделана ли разовая настройка (setup-network.ps1): резервация URL http://+:<Port>/ и правило брандмауэра.
    Права администратора для проверки не нужны.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Port)
    $url = Get-NotifierHttpPrefix -Port $Port
    $acl = (& netsh http show urlacl url=$url 2>$null) -join "`n"
    if ($acl.IndexOf($url, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    & netsh advfirewall firewall show rule name=claude-notifier 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Invoke-NotifierNetworkSetup {
    <#
    .SYNOPSIS
    Запускает setup-network.ps1 с правами администратора (запрос UAC) и ждёт завершения.

    .OUTPUTS
    'ok' | 'cancelled' (пользователь отказал в UAC) | 'failed'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][int]$Port, [switch]$Remove, [string]$DataRoot = (Get-NotifierDataRoot))
    $script = Join-Path $script:AppRoot 'setup-network.ps1'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $argList = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$script`"", '-Port', $Port, '-User', "`"$user`"", '-DataRoot', "`"$DataRoot`"")
    if ($Remove) { $argList += '-Remove' }
    try {
        $p = Start-Process -FilePath $ps -ArgumentList $argList -Verb RunAs -WindowStyle Hidden -PassThru -Wait -ErrorAction Stop
    }
    catch {
        Write-NotifierLog -Level WARN -Message "network: настройка сети не запущена: $($_.Exception.Message)" -DataRoot $DataRoot
        return 'cancelled'
    }
    if ($p.ExitCode -eq 0) { return 'ok' }
    Write-NotifierLog -Level ERROR -Message "network: setup-network.ps1 завершился с кодом $($p.ExitCode), подробности в setup-network.log" -DataRoot $DataRoot
    return 'failed'
}

Export-ModuleMember -Function Test-NotifierNetworkSetup, Invoke-NotifierNetworkSetup, Get-NotifierHttpPrefix, Start-NotifierHttpServer, Stop-NotifierHttpServer, ConvertFrom-NotifierHttpContext, Write-NotifierHttpResponse, Get-NotifierSessionsPayload, Invoke-NotifierHttpRequest, Get-NotifierServerBaseUrl
