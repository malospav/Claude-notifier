<#
.SYNOPSIS
Разовая настройка Windows для доступа к claude-notifier из локальной сети. Нужны права администратора:
трей запускает этот скрипт через запрос UAC, когда вы включаете «Доступ из сети».

.DESCRIPTION
1. Резервирует URL http://+:<Port>/ за текущим пользователем (netsh http add urlacl) — без этого
   программа без прав администратора не может принимать подключения из сети.
2. Добавляет правило брандмауэра «claude-notifier» — входящий TCP на порт <Port> только из локальной
   подсети (remoteip=localsubnet), для любого профиля сети: на этом ПК Wi-Fi помечен как «Общедоступная».
С ключом -Remove удаляет и то, и другое. Пишет результат в <DataRoot>\setup-network.log.
#>
param(
    [int]$Port = 47600,
    [string]$User = '',
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'claude-notifier'),
    [switch]$Remove
)

$rule = 'claude-notifier'
$url = "http://+:$Port/"
$lines = New-Object System.Collections.ArrayList
function Note([string]$Text) { [void]$lines.Add("$(Get-Date -Format s) $Text") }

$code = 0
try {
    if ($Remove) {
        $o = & netsh http delete urlacl url=$url 2>&1; Note "urlacl delete: exit $LASTEXITCODE $o"
        $o = & netsh advfirewall firewall delete rule name=$rule 2>&1; Note "firewall delete: exit $LASTEXITCODE $o"
    }
    else {
        if ([string]::IsNullOrEmpty($User)) { $User = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
        & netsh http delete urlacl url=$url 2>&1 | Out-Null
        $o = & netsh http add urlacl url=$url user="$User" 2>&1; Note "urlacl add ($User): exit $LASTEXITCODE $o"
        if ($LASTEXITCODE -ne 0) { $code = 1 }
        & netsh advfirewall firewall delete rule name=$rule 2>&1 | Out-Null
        $o = & netsh advfirewall firewall add rule name=$rule dir=in action=allow protocol=TCP localport=$Port remoteip=localsubnet profile=any 2>&1
        Note "firewall add: exit $LASTEXITCODE $o"
        if ($LASTEXITCODE -ne 0) { $code = 1 }
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
