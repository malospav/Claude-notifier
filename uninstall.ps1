<#
.SYNOPSIS
Удаляет claude-notifier: свои хуки из ~/.claude/settings.json и каталог app\.

.DESCRIPTION
Чужие хуки и настройки не трогаются. config.json, history.json и лог остаются,
если не указан -Purge (тогда удаляется весь %LOCALAPPDATA%\claude-notifier).

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -Purge
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'claude-notifier'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [switch]$Purge
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src\lib\Settings.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\lib\Registration.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'src\lib\Config.psm1') -Force

try {
    $settings = Read-ClaudeSettings -Path $SettingsPath
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $removed = Remove-NotifierHooks -Settings $settings
    $restored = Restore-NotifierStatusLine -Settings $settings -Previous $config.chainStatusLine
    if ($removed -gt 0 -or $restored) {
        $backup = Save-ClaudeSettings -Settings $settings -Path $SettingsPath
        Write-Output "Удалено хуков claude-notifier: $removed (резервная копия: $backup)"
        if ($restored -and $null -ne $config.chainStatusLine) { Write-Output 'Прежняя строка статуса восстановлена' }
        elseif ($restored) { Write-Output 'Строка статуса claude-notifier удалена' }
    }
    else {
        Write-Output 'Хуков claude-notifier в settings.json нет'
    }
    if ($restored -and $null -ne $config.chainStatusLine -and -not $Purge) {
        try { Set-NotifierConfigValue -Name chainStatusLine -Value $null -DataRoot $DataRoot } catch { }
    }

    if (Unregister-NotifierProtocol -ClassesRoot $ClassesRoot) { Write-Output 'URL-протокол claude-notifier: удалён' }
    if (Unregister-NotifierAumid -ClassesRoot $ClassesRoot) { Write-Output 'AppUserModelID ClaudeNotifier удалён' }

    $target = Join-Path $DataRoot 'app'
    if ($Purge) { $target = $DataRoot }
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
        Write-Output "Удалено: $target"
    }
    exit 0
}
catch {
    Write-Error -ErrorAction Continue "Удаление прервано: $($_.Exception.Message)"
    exit 1
}
