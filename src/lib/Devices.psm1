Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# network.json — доступ из локальной сети и подключённые устройства. Пишет только трей.
# { enabled, port, devices: [ { id, name, kind, hooks, notify, tokens[], created, last_seen } ] }
# kind: browser (телефон, браузер) | mac (на устройстве стоят хуки). В tokens — только SHA-256 токенов.
$script:DefaultPort = 47600
$script:PairingMinutes = 10
$script:PairingMaxAttempts = 5

function Get-NetworkPath([string]$DataRoot) { return (Join-Path $DataRoot 'network.json') }

function Get-UtcStamp { return [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }

function Get-NotifierNetwork {
    <#
    .SYNOPSIS
    Читает network.json. Нет файла или он повреждён → настройки по умолчанию (выключено, порт 47600, устройств нет).
    #>
    [CmdletBinding()]
    param([string]$DataRoot = (Get-NotifierDataRoot))
    $net = @{ enabled = $false; port = $script:DefaultPort; devices = New-Object System.Collections.ArrayList }
    $path = Get-NetworkPath $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $net }
    try { $obj = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)) -ErrorAction Stop }
    catch {
        Write-NotifierLog -Level WARN -Message 'network: network.json повреждён; доступ из сети выключен, устройства нужно подключить заново' -DataRoot $DataRoot
        return $net
    }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) { return $net }
    $p = $obj.PSObject.Properties
    if ($p['enabled'] -and $p['enabled'].Value -is [bool]) { $net.enabled = $p['enabled'].Value }
    if ($p['port'] -and ($p['port'].Value -is [int] -or $p['port'].Value -is [long]) -and $p['port'].Value -ge 1024 -and $p['port'].Value -le 65535) { $net.port = [int]$p['port'].Value }
    if ($p['devices']) {
        foreach ($d in @($p['devices'].Value)) {
            if ($d -isnot [System.Management.Automation.PSCustomObject] -or $null -eq $d.PSObject.Properties['id']) { continue }
            foreach ($f in @(@('name', ''), @('kind', 'browser'), @('hooks', $false), @('notify', $false), @('created', ''), @('last_seen', ''))) {
                if ($null -eq $d.PSObject.Properties[$f[0]]) { $d | Add-Member -NotePropertyName $f[0] -NotePropertyValue $f[1] }
            }
            if ($null -eq $d.PSObject.Properties['tokens']) { $d | Add-Member -NotePropertyName tokens -NotePropertyValue @() }
            $d.tokens = @($d.tokens | Where-Object { $_ -is [string] })
            [void]$net.devices.Add($d)
        }
    }
    return $net
}

function Save-NotifierNetwork {
    <# .SYNOPSIS Атомарно записывает network.json. #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][hashtable]$Network, [string]$DataRoot = (Get-NotifierDataRoot))
    if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
    $obj = [ordered]@{ enabled = [bool]$Network.enabled; port = [int]$Network.port; devices = @($Network.devices) }
    $path = Get-NetworkPath $DataRoot
    $tmp = "$path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $obj -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function New-NotifierToken {
    <# .SYNOPSIS Случайный токен: 32 байта в base64url (43 символа). #>
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([Convert]::ToBase64String($bytes)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function Get-NotifierTokenHash {
    <# .SYNOPSIS SHA-256 токена в hex: в файле хранится только он. #>
    param([Parameter(Mandatory = $true)][string]$Token)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Token)) } finally { $sha.Dispose() }
    return -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

function Find-NotifierDeviceByToken {
    <# .SYNOPSIS Устройство, которому выдан этот токен, или $null. #>
    param([Parameter(Mandatory = $true)][hashtable]$Network, [AllowEmptyString()][string]$Token)
    if ([string]::IsNullOrEmpty($Token) -or $Token.Length -gt 200) { return $null }
    $hash = Get-NotifierTokenHash $Token
    foreach ($d in $Network.devices) {
        if (@($d.tokens) -contains $hash) { return $d }
    }
    return $null
}

function Find-NotifierDevice {
    <# .SYNOPSIS Устройство по id или $null. #>
    param([Parameter(Mandatory = $true)][hashtable]$Network, [string]$Id)
    foreach ($d in $Network.devices) { if ([string]$d.id -eq $Id) { return $d } }
    return $null
}

function Add-NotifierDevice {
    <#
    .SYNOPSIS
    Регистрирует новое устройство. Возвращает @{ Device; Token } — токен показывается один раз, в файле только хэш.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Network,
        [Parameter(Mandatory = $true)][string]$Name,
        [ValidateSet('browser', 'mac')][string]$Kind = 'browser'
    )
    $token = New-NotifierToken
    $now = Get-UtcStamp
    $device = [pscustomobject][ordered]@{
        id        = 'd' + [guid]::NewGuid().ToString('N').Substring(0, 10)
        name      = $Name
        kind      = $Kind
        hooks     = $false
        notify    = $false
        tokens    = @(Get-NotifierTokenHash $token)
        created   = $now
        last_seen = $now
    }
    [void]$Network.devices.Add($device)
    return @{ Device = $device; Token = $token }
}

function Add-NotifierDeviceToken {
    <# .SYNOPSIS Выдаёт устройству ещё один токен (для хуков Mac) и возвращает его. #>
    param([Parameter(Mandatory = $true)]$Device)
    $token = New-NotifierToken
    $Device.tokens = @(@($Device.tokens) + (Get-NotifierTokenHash $token))
    return $token
}

function Remove-NotifierDevice {
    <# .SYNOPSIS Отключает устройство: его токены перестают действовать. Возвращает $true, если устройство было. #>
    param([Parameter(Mandatory = $true)][hashtable]$Network, [Parameter(Mandatory = $true)][string]$Id)
    $d = Find-NotifierDevice -Network $Network -Id $Id
    if ($null -eq $d) { return $false }
    $Network.devices.Remove($d)
    return $true
}

function New-NotifierPairing {
    <#
    .SYNOPSIS
    Новый одноразовый PIN для подключения устройства: 6 цифр, действует 10 минут, 5 попыток.
    #>
    param([datetime]$Now = [DateTime]::UtcNow)
    $bytes = New-Object byte[] 4
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    $pin = ([BitConverter]::ToUInt32($bytes, 0) % 1000000).ToString('000000')
    return @{ Pin = $pin; Expires = $Now.AddMinutes($script:PairingMinutes); Attempts = 0; Used = $false; DeviceName = $null }
}

function Test-NotifierPairingPin {
    <#
    .SYNOPSIS
    Проверяет PIN. Возвращает 'ok' | 'bad' | 'expired' | 'locked' | 'none'. После 'ok' PIN израсходован;
    после 5 неверных попыток заблокирован.
    #>
    param($Pairing, [AllowEmptyString()][string]$Pin, [datetime]$Now = [DateTime]::UtcNow)
    if ($null -eq $Pairing -or $Pairing.Used) { return 'none' }
    if ($Now -gt $Pairing.Expires) { return 'expired' }
    if ($Pairing.Attempts -ge $script:PairingMaxAttempts) { return 'locked' }
    $clean = ([string]$Pin) -replace '\s', ''
    if ($clean -ne $Pairing.Pin) {
        $Pairing.Attempts++
        if ($Pairing.Attempts -ge $script:PairingMaxAttempts) { return 'locked' }
        return 'bad'
    }
    $Pairing.Used = $true
    return 'ok'
}

function Get-NotifierDeviceNameFromAgent {
    <# .SYNOPSIS Имя нового устройства по User-Agent браузера: iPhone, iPad, Android, Mac, Windows… #>
    param([AllowEmptyString()][string]$UserAgent)
    $ua = [string]$UserAgent
    if ($ua -match 'iPhone') { return 'iPhone' }
    if ($ua -match 'iPad') { return 'iPad' }
    if ($ua -match 'Android') { return 'Android' }
    if ($ua -match 'Macintosh|Mac OS X') { return 'Mac' }
    if ($ua -match 'Windows') { return 'Windows' }
    if ($ua -match 'Linux') { return 'Linux' }
    return 'Браузер'
}

function Get-NotifierLanAddress {
    <#
    .SYNOPSIS
    IPv4-адрес этого ПК в локальной сети: работающий адаптер с основным шлюзом, частный адрес
    (10.x, 172.16–31.x, 192.168.x). Wi-Fi и Ethernet предпочтительнее виртуальных. Нет — $null.
    #>
    $best = $null
    $bestScore = -1
    foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($nic.OperationalStatus -ne 'Up') { continue }
        $props = $nic.GetIPProperties()
        if (@($props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' }).Count -eq 0) { continue }
        foreach ($ua in $props.UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.ToString()
            if ($ip -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)') { continue }
            $score = 1
            if ($nic.NetworkInterfaceType -eq 'Wireless80211' -or $nic.NetworkInterfaceType -eq 'Ethernet') { $score = 2 }
            if ($nic.Description -match 'Virtual|Hyper-V|VMware|VirtualBox|WSL') { $score = 0 }
            if ($score -gt $bestScore) { $best = $ip; $bestScore = $score }
        }
    }
    return $best
}

function Format-NotifierLastSeen {
    <# .SYNOPSIS «в сети» (до 2 мин), «5 мин назад», «3 ч назад», «12.11», «—». #>
    param([AllowEmptyString()][string]$Ts, [datetime]$Now = [DateTime]::UtcNow)
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Ts, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return '—' }
    $span = $Now - $parsed.UtcDateTime
    if ($span.TotalMinutes -lt 2) { return 'в сети' }
    if ($span.TotalHours -lt 1) { return "$([int][Math]::Floor($span.TotalMinutes)) мин назад" }
    if ($span.TotalDays -lt 1) { return "$([int][Math]::Floor($span.TotalHours)) ч назад" }
    return $parsed.ToLocalTime().ToString('dd.MM', [Globalization.CultureInfo]::InvariantCulture)
}

Export-ModuleMember -Function Get-NotifierNetwork, Save-NotifierNetwork, New-NotifierToken, Get-NotifierTokenHash, Find-NotifierDeviceByToken, Find-NotifierDevice, Add-NotifierDevice, Add-NotifierDeviceToken, Remove-NotifierDevice, New-NotifierPairing, Test-NotifierPairingPin, Get-NotifierDeviceNameFromAgent, Get-NotifierLanAddress, Format-NotifierLastSeen
