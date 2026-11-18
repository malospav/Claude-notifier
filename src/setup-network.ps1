<#
.SYNOPSIS
Разовая настройка Windows для доступа к claude-notifier из локальной сети. Нужны права администратора:
трей запускает этот скрипт через запрос UAC, когда вы включаете «Доступ из сети».

.DESCRIPTION
1. Резервирует URL http://+:<Port>/ за текущим пользователем (netsh http add urlacl) — без этого
   программа без прав администратора не может принимать подключения из сети.
2. Добавляет правило брандмауэра «claude-notifier» — входящий TCP на порт <Port> только из локальной
   подсети (remoteip=localsubnet), для любого профиля сети: на этом ПК Wi-Fi помечен как «Общедоступная».
3. Шифрование: самоподписанный сертификат «claude-notifier» (LocalMachine\My, RSA 2048, 10 лет) привязывается
   к порту <Port + 1> (netsh http add sslcert), резервируется https://+:<Port + 1>/. Хуки Mac, Linux и WSL ходят
   туда и сверяют отпечаток ключа, запомненный при установке.
С ключом -Remove удаляет резервации, привязку и правило (сертификат остаётся: тот же отпечаток при повторном включении).
Пишет результат в <DataRoot>\setup-network.log.
#>
param(
    [int]$Port = 47600,
    [string]$User = '',
    [string]$DataRoot = $(if ($env:CLAUDE_NOTIFIER_HOME) { $env:CLAUDE_NOTIFIER_HOME } else { Join-Path $env:USERPROFILE '.claude-notifier' }),
    [switch]$Remove
)

$rule = 'claude-notifier'
$url = "http://+:$Port/"
$tlsPort = $Port + 1
$tlsUrl = "https://+:$tlsPort/"
$appId = '{6f2b6d3e-3c1a-4b8e-9f62-5d0c4e7a9b11}'   # постоянный id приложения для привязки сертификата
$lines = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$lines.Add("$(Get-Date -Format s) $Text") }

$code = 0
try {
    if ($Remove) {
        $o = & netsh http delete urlacl url=$url 2>&1; Note "urlacl delete: exit $LASTEXITCODE $o"
        $o = & netsh advfirewall firewall delete rule name=$rule 2>&1; Note "firewall delete: exit $LASTEXITCODE $o"
        $o = & netsh http delete urlacl url=$tlsUrl 2>&1; Note "urlacl https delete: exit $LASTEXITCODE $o"
        $o = & netsh http delete sslcert ipport=0.0.0.0:$tlsPort 2>&1; Note "sslcert delete: exit $LASTEXITCODE $o"
    }
    else {
        if ([string]::IsNullOrEmpty($User)) { $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        & netsh http delete urlacl url=$url 2>&1 | Out-Null
        $o = & netsh http add urlacl url=$url user="$User" 2>&1; Note "urlacl add ($User): exit $LASTEXITCODE $o"
        if ($LASTEXITCODE -ne 0) { $code = 1 }
        & netsh advfirewall firewall delete rule name=$rule 2>&1 | Out-Null
        $o = & netsh advfirewall firewall add rule name=$rule dir=in action=allow protocol=TCP localport="$Port,$tlsPort" remoteip=localsubnet profile=any 2>&1
        Note "firewall add: exit $LASTEXITCODE $o"
        if ($LASTEXITCODE -ne 0) { $code = 1 }
        # Шифрование. Сбой здесь не мешает http: сервер тогда работает без https, как раньше.
        # Только если резервация и брандмауэр удались (иначе дальше всё равно не заработает).
        if ($code -eq 0) { try {
            $cert = @(Get-ChildItem -LiteralPath 'Cert:\LocalMachine\My' | Where-Object { $_.FriendlyName -eq 'claude-notifier' -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
                Sort-Object NotAfter -Descending) | Select-Object -First 1
            if ($null -eq $cert) {
                $names = @($env:COMPUTERNAME, "$($env:COMPUTERNAME.ToLowerInvariant()).local", 'localhost')
                $cert = New-SelfSignedCertificate -DnsName $names -CertStoreLocation 'Cert:\LocalMachine\My' -FriendlyName 'claude-notifier' `
                    -NotAfter (Get-Date).AddYears(10) -KeyAlgorithm RSA -KeyLength 2048 -KeyExportPolicy NonExportable
                Note "certificate created: $($cert.Thumbprint)"
            }
            & netsh http delete sslcert ipport=0.0.0.0:$tlsPort 2>&1 | Out-Null
            $o = & netsh http add sslcert ipport=0.0.0.0:$tlsPort certhash=$($cert.Thumbprint) appid=$appId certstorename=MY 2>&1
            Note "sslcert add ($($cert.Thumbprint)): exit $LASTEXITCODE $o"
            & netsh http delete urlacl url=$tlsUrl 2>&1 | Out-Null
            $o = & netsh http add urlacl url=$tlsUrl user="$User" 2>&1; Note "urlacl https add ($User): exit $LASTEXITCODE $o"
        }
        catch { Note "tls error: $($_.Exception.Message)" } }
    }
}
catch { Note "error: $($_.Exception.Message)"; $code = 1 }
finally {
    try {
        if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
        [IO.File]::AppendAllText((Join-Path $DataRoot 'setup-network.log'), (($lines -join "`r`n") + "`r`n"), (New-Object Text.UTF8Encoding $false))
    }
    catch { }
}
exit $code
