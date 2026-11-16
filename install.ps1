<#
.SYNOPSIS
Устанавливает claude-notifier: копирует src\ в %LOCALAPPDATA%\claude-notifier\app\ и добавляет хуки в ~/.claude/settings.json.

.DESCRIPTION
Повторный запуск безопасен: старые записи claude-notifier заменяются, чужие настройки не трогаются.
Перед изменением settings.json рядом сохраняется settings.json.bak-<дата>.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$DataRoot = (Join-Path $env:LOCALAPPDATA 'claude-notifier'),
    [string]$SourceRoot = '',   # по умолчанию <папка скрипта>\src ($PSScriptRoot пуст в значениях параметров при -File в PS 5.1)
    [string]$ClassesRoot = 'HKCU:\Software\Classes'
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($SourceRoot)) { $SourceRoot = Join-Path $PSScriptRoot 'src' }
Import-Module (Join-Path $SourceRoot 'lib\Settings.psm1') -Force
Import-Module (Join-Path $SourceRoot 'lib\Registration.psm1') -Force
Import-Module (Join-Path $SourceRoot 'lib\Config.psm1') -Force

try {
    # 1. Сначала проверяем settings.json: при ошибке ничего не меняем.
    $settings = Read-ClaudeSettings -Path $SettingsPath

    # 2. Копируем приложение начисто.
    $app = Join-Path $DataRoot 'app'
    if (Test-Path -LiteralPath $app) { Remove-Item -LiteralPath $app -Recurse -Force }
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $app -Recurse -Force
    Get-ChildItem -LiteralPath $app -Recurse -File | Unblock-File

    # 3. Хуки и строка статуса. Прежний statusLine пользователя сохраняется в config.json
    #    (chainStatusLine) до записи settings.json: если config.json записать нельзя, settings не меняется.
    [void](Remove-NotifierHooks -Settings $settings)
    Add-NotifierHooks -Settings $settings -AppRoot $app
    $previousStatusLine = Set-NotifierStatusLine -Settings $settings -AppRoot $app
    if ($null -ne $previousStatusLine) {
        Set-NotifierConfigValue -Name chainStatusLine -Value $previousStatusLine -DataRoot $DataRoot
    }
    $backup = Save-ClaudeSettings -Settings $settings -Path $SettingsPath

    # 4. URL-протокол claude-notifier:focus?id=<id> — переход к сессии из «Истории» и по ссылке.
    #    AUMID «Claude Notifier» не регистрируется (ADR-006): без exe-активатора клик по такому
    #    уведомлению открывает окно Microsoft Store; ключ от прежних версий удаляется.
    Register-NotifierProtocol -AppRoot $app -ClassesRoot $ClassesRoot
    [void](Unregister-NotifierAumid -ClassesRoot $ClassesRoot)

    Write-Output "claude-notifier установлен в $app"
    Write-Output "Хуки Stop, Notification, StopFailure и строка статуса добавлены в $SettingsPath"
    if ($null -ne $previousStatusLine) { Write-Output 'Прежняя строка статуса сохранена в config.json (chainStatusLine) и будет показываться первой' }
    Write-Output 'URL-протокол claude-notifier: зарегистрирован'
    if ($backup) { Write-Output "Резервная копия настроек: $backup" }
    exit 0
}
catch {
    Write-Error -ErrorAction Continue "Установка прервана: $($_.Exception.Message)"
    exit 1
}
