<#
.SYNOPSIS
Доступ из локальной сети для трея claude-notifier: HTTP-сервер, вкладка «Устройства», окно «Подключить устройство».

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source и работает в его области видимости ($script:…).
Состояние — $script:Net: настройки и устройства (network.json), текущий PIN, одноразовые коды установки,
сервер, события от устройств. Всё выполняется в UI-потоке трея.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Devices.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Server.psm1')
. (Join-Path $PSScriptRoot 'ClaudeNotifier.NetworkUi.ps1')   # вкладка «Устройства», окно подключения

$script:Net = $null
$script:NetSaveMs = 2000
$script:ConnectForm = $null

function Initialize-NotifierNet {
    <# .SYNOPSIS Создаёт $script:Net из network.json и, если доступ включён, запускает сервер. #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $script:Net = @{
        Network      = Get-NotifierNetwork -DataRoot $DataRoot
        Pairing      = $null
        InstallCodes = @{}
        Server       = $null
        Queue        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Events       = New-Object System.Collections.ArrayList
        NetworkDirty = $false
        LastSave     = [datetime]::MinValue
        Paired       = $null
        Error        = ''
        DataRoot     = $DataRoot
        Address      = Get-NotifierLanAddress
        Tls          = $null   # @{ Port; Pin } — шифрование настроено (setup-network.ps1), сервер слушает и https
        PcName       = $env:COMPUTERNAME
    }
    if ($script:Net.Network.enabled) { [void](Start-NotifierNetServer) }
}

function Start-NotifierNetServer {
    <# .SYNOPSIS Запускает HTTP-сервер. Возвращает $true при успехе; текст ошибки — в $script:Net.Error. #>
    $net = $script:Net
    if ($net.Server) { return $true }
    $net.Address = Get-NotifierLanAddress
    try {
        $prefixes = @(Get-NotifierHttpPrefix -Port $net.Network.port)
        $net.Tls = Test-NotifierTlsSetup -Port $net.Network.port
        if ($net.Tls) { $prefixes += "https://+:$($net.Tls.Port)/" }
        try { $net.Server = Start-NotifierHttpServer -Prefix $prefixes -Queue $net.Queue }
        catch {
            if (-not $net.Tls) { throw }
            # https не поднялся (нет резервации URL) — работаем без шифрования, как раньше.
            Write-NotifierLog -Level WARN -Message "network: https не запущен ($($_.Exception.Message)) $([char]0x2014) только http" -DataRoot $net.DataRoot
            $net.Tls = $null
            $net.Server = Start-NotifierHttpServer -Prefix $prefixes[0] -Queue $net.Queue
        }
        $net.Error = ''
        Write-NotifierLog -Level INFO -Message "network: сервер запущен на порту $($net.Network.port)" -DataRoot $net.DataRoot
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $net.Error = $msg
        Write-NotifierLog -Level WARN -Message "network: сервер не запущен: $msg" -DataRoot $net.DataRoot
        return $false
    }
}

function Stop-NotifierNetServer {
    $net = $script:Net
    if ($null -eq $net) { return }
    if ($net.Server) { [void](Stop-NotifierHttpServer -Server $net.Server); $net.Server = $null }
    if ($net.NetworkDirty) { Save-NotifierNet -Force }
}

function Save-NotifierNet {
    <# .SYNOPSIS Сохраняет network.json, если есть изменения (не чаще раза в NetSaveMs, с -Force — сразу). #>
    param([switch]$Force)
    $net = $script:Net
    if (-not $net.NetworkDirty) { return }
    $now = [datetime]::UtcNow
    if (-not $Force -and ($now - $net.LastSave).TotalMilliseconds -lt $script:NetSaveMs) { return }
    try {
        Save-NotifierNetwork -Network $net.Network -DataRoot $net.DataRoot
        $net.NetworkDirty = $false
        $net.LastSave = $now
    }
    catch { Write-NotifierLog -Level ERROR -Message "network: network.json не записан: $($_.Exception.Message)" -DataRoot $net.DataRoot }
}

function Invoke-NotifierHttpBatch {
    <#
    .SYNOPSIS
    Отвечает на принятые HTTP-запросы (до MaxBatch за тик), передаёт события устройств в очередь трея.
    Возвращает число обработанных запросов.
    #>
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$EventQueue = $script:TrayQueue, [int]$MaxBatch = 20)
    $net = $script:Net
    if ($null -eq $net -or $net.Queue.IsEmpty) { Save-NotifierNet; return 0 }
    $n = 0
    for ($i = 0; $i -lt $MaxBatch; $i++) {
        $ctx = $null
        if (-not $net.Queue.TryDequeue([ref]$ctx)) { break }
        $n++
        try {
            $req = ConvertFrom-NotifierHttpContext -Context $ctx
            $resp = Invoke-NotifierHttpRequest -Request $req -Ctx $net
        }
        catch {
            Write-NotifierLog -Level ERROR -Message "network: ошибка запроса: $($_.Exception.Message)" -DataRoot $net.DataRoot
            $resp = @{ Status = 500; Body = 'error'; ContentType = 'text/plain; charset=utf-8'; Headers = @() }
        }
        try { Write-NotifierHttpResponse -Context $ctx -Response $resp } catch { }
    }
    foreach ($ev in $net.Events) { $EventQueue.Enqueue($ev) }
    $net.Events.Clear()
    if ($net.Paired) {
        $paired = $net.Paired
        $net.Paired = $null
        Save-NotifierNet -Force
        Update-NotifierConnectStatus -Device $paired
        $script:SessionsDirty = $true
    }
    Save-NotifierNet
    return $n
}

function Test-NotifierRemoteEventMuted {
    <#
    .SYNOPSIS
    Для события с другого устройства: 'drop' — устройство отключено, 'quiet' — уведомления на ПК
    для него выключены (только статус сеанса), 'show' — показать как обычно. Для событий этого ПК — 'show'.
    #>
    param([Parameter(Mandatory = $true)]$Event)
    $p = $Event.PSObject.Properties['device']
    if ($null -eq $p -or [string]::IsNullOrEmpty([string]$p.Value)) { return 'show' }
    if ($null -eq $script:Net) { return 'drop' }
    $d = Find-NotifierDevice -Network $script:Net.Network -Id ([string]$p.Value)
    if ($null -eq $d) { return 'drop' }
    if ($d.notify) { return 'show' }
    return 'quiet'
}

function Get-NotifierDeviceName {
    <# .SYNOPSIS Имя устройства для таблицы сеансов: '' → «Этот ПК». #>
    param([AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return 'Этот ПК' }
    if ($script:Net) {
        $d = Find-NotifierDevice -Network $script:Net.Network -Id $Id
        if ($d) { return [string]$d.name }
    }
    return 'Отключено'
}

$script:DeviceSilentMinutes = 60

function Get-NotifierDeviceSilentSince {
    <#
    .SYNOPSIS
    Сеанс другого устройства «работает», а от устройства давно ни одного запроса (ни событий, ни опроса ответов):
    Mac выключен, уснул или потерял сеть — статус «работает» больше не правда. Возвращает время последней связи
    (UTC) или $null, если всё в порядке. Порог — час: долгая задача Claude тоже может молчать минут двадцать.
    #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow, [int]$Minutes = $script:DeviceSilentMinutes)
    if (-not ($Session.PSObject.Properties['device'] -and [string]$Session.device -ne '')) { return $null }
    if ([string]$Session.state -ne 'working') { return $null }
    if (-not $script:Net) { return $null }
    $d = Find-NotifierDevice -Network $script:Net.Network -Id ([string]$Session.device)
    if ($null -eq $d) { return $null }
    $seen = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$d.last_seen, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$seen)) { return $null }
    $at = $seen.UtcDateTime
    $upd = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse([string]$Session.updated, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$upd) -and $upd.UtcDateTime -gt $at) { $at = $upd.UtcDateTime }
    if (($Now - $at).TotalMinutes -lt $Minutes) { return $null }
    return $at
}

