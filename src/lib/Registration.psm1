Set-StrictMode -Version 2.0

# Регистрация claude-notifier в HKCU (без прав администратора).
# ClassesRoot — параметр, чтобы тесты писали в отдельный ключ, а не в настоящий HKCU:\Software\Classes.

$script:DefaultClassesRoot = 'HKCU:\Software\Classes'

function Register-NotifierProtocol {
    <#
    .SYNOPSIS
    Регистрирует URL-протокол <Name>: (по умолчанию claude-notifier:). Клик открывает
    focus-handler.ps1 через conhost --headless, поэтому окно консоли не появляется.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [string]$ClassesRoot = $script:DefaultClassesRoot,
        [string]$Name = 'claude-notifier'
    )
    $key = Join-Path $ClassesRoot $Name
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $handler = Join-Path $AppRoot 'focus-handler.ps1'
    $command = "`"$conhost`" --headless `"$ps`" -NoProfile -NonInteractive -WindowStyle Hidden -File `"$handler`" `"%1`""

    New-Item -Path (Join-Path $key 'shell\open\command') -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name '(default)' -Value 'URL:Claude Notifier'
    Set-ItemProperty -LiteralPath $key -Name 'URL Protocol' -Value ''
    Set-ItemProperty -LiteralPath (Join-Path $key 'shell\open\command') -Name '(default)' -Value $command
}

function Unregister-NotifierProtocol {
    <#
    .SYNOPSIS
    Удаляет ключ URL-протокола. Возвращает $true, если ключ был.
    #>
    [CmdletBinding()]
    param(
        [string]$ClassesRoot = $script:DefaultClassesRoot,
        [string]$Name = 'claude-notifier'
    )
    $key = Join-Path $ClassesRoot $Name
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    Remove-Item -LiteralPath $key -Recurse -Force
    return $true
}

function Register-NotifierAumid {
    <#
    .SYNOPSIS
    Регистрирует AppUserModelID ClaudeNotifier: имя «Claude Notifier» и иконка в уведомлениях Windows
    (вместо «Windows PowerShell»). Иконка — <AppRoot>\assets\icon.ico.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [string]$ClassesRoot = $script:DefaultClassesRoot,
        [string]$AppId = 'ClaudeNotifier'
    )
    $key = Join-Path $ClassesRoot "AppUserModelId\$AppId"
    New-Item -Path $key -Force | Out-Null
    Set-ItemProperty -LiteralPath $key -Name 'DisplayName' -Value 'Claude Notifier'
    Set-ItemProperty -LiteralPath $key -Name 'IconUri' -Value (Join-Path $AppRoot 'assets\icon.ico')
}

function Unregister-NotifierAumid {
    <# .SYNOPSIS Удаляет ключ AppUserModelID. Возвращает $true, если ключ был. #>
    [CmdletBinding()]
    param(
        [string]$ClassesRoot = $script:DefaultClassesRoot,
        [string]$AppId = 'ClaudeNotifier'
    )
    $key = Join-Path $ClassesRoot "AppUserModelId\$AppId"
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    Remove-Item -LiteralPath $key -Recurse -Force
    return $true
}

Export-ModuleMember -Function Register-NotifierProtocol, Unregister-NotifierProtocol, Register-NotifierAumid, Unregister-NotifierAumid
