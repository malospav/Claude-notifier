Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Event.psm1')
Import-Module (Join-Path $PSScriptRoot 'Sessions.psm1')
Import-Module (Join-Path $PSScriptRoot 'Devices.psm1')

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

$script:AcceptLoop = {
    param($Listener, $Queue)
    while ($Listener.IsListening) {
        try { $ctx = $Listener.GetContext() } catch { break }
        $Queue.Enqueue($ctx)
    }
}

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
    [void]$ps.AddScript($script:AcceptLoop.ToString()).AddArgument($listener).AddArgument($Queue)
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
    $r = $Context.Request
    $headers = @{}
    foreach ($k in $r.Headers.AllKeys) { $headers[$k.ToLowerInvariant()] = $r.Headers[$k] }
    $query = @{}
    foreach ($k in $r.QueryString.AllKeys) { if ($k) { $query[$k] = $r.QueryString[$k] } }
    $body = ''
    $tooLarge = $false
    if ($r.HasEntityBody) {
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
    $resp = $Context.Response
    try {
        $resp.StatusCode = $Response.Status
        $resp.ContentType = $Response.ContentType
        $resp.Headers.Add('Cache-Control', 'no-store')
        $resp.Headers.Add('X-Content-Type-Options', 'nosniff')
        $resp.Headers.Add('Referrer-Policy', 'no-referrer')
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
    $items = @()
    foreach ($s in (Get-NotifierSortedSessions -Sessions $live)) {
        $dev = ''
        if ($s.PSObject.Properties['device']) { $dev = [string]$s.device }
        $devName = $names[$dev]
        if ($null -eq $devName) { $devName = 'Устройство отключено' }
        $items += [ordered]@{
            device      = $dev
            device_name = $devName
            project     = [string]$s.project
            state       = [string]$s.state
            state_text  = (Get-NotifierSessionStateText ([string]$s.state))
            elapsed     = (Format-NotifierElapsed -Ts ([string]$s.since) -Now $Now)
            origin      = [string]$s.origin
            preview     = [string]$s.preview
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
        $f = $script:StaticFiles[$path]
        return (New-HttpResponse 200 ([IO.File]::ReadAllText((Join-Path $script:AppRoot $f[0]), [Text.Encoding]::UTF8).Replace("`r`n", "`n")) $f[1])
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
        $token = Add-NotifierDeviceToken -Device $device
        $Ctx.NetworkDirty = $true
        $base = Get-NotifierServerBaseUrl $Ctx
        $alt = "http://$($Ctx.PcName.ToLowerInvariant()).local:$($Ctx.Network.port)"
        $script = Get-WebTemplate 'install.sh' @{ URL = $base; URL2 = $alt; TOKEN = $token; PCNAME = $Ctx.PcName }
        Write-NotifierLog -Level INFO -Message "network: скрипт установки выдан устройству $($device.id)" -DataRoot $Ctx.DataRoot
        return (New-HttpResponse 200 $script)
    }

    if ($method -eq 'POST' -and $path -eq '/login') {
        $result = Test-NotifierPairingPin -Pairing $Ctx.Pairing -Pin (Get-FormValue $Request.Body 'pin') -Now $Now
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
            'bad' { return (Get-LoginPage $Ctx "Неверный код. Осталось попыток: $(5 - $Ctx.Pairing.Attempts)." 401) }
            default { return (Get-LoginPage $Ctx 'Код недействителен. На ПК нажмите «Подключить устройство» и введите новый код.' 401) }
        }
    }

    $device = Find-NotifierDeviceByToken -Network $Ctx.Network -Token (Get-RequestToken $Request)
    if ($null -eq $device) {
        if ($method -eq 'GET' -and $path -eq '/') { return (Get-LoginPage $Ctx '') }
        return (New-JsonResponse 401 @{ error = 'unauthorized' })
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
