<#
.SYNOPSIS
Устанавливает claude-notifier: копирует src\ в %USERPROFILE%\.claude-notifier\app\ и добавляет хуки в ~/.claude/settings.json.

.DESCRIPTION
Повторный запуск безопасен: старые записи claude-notifier заменяются, чужие настройки не трогаются.
Перед изменением settings.json рядом сохраняется settings.json.bak-<дата>.

.EXAMPLE
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
#>
[CmdletBinding()]
param(
    [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'),
    [string]$DataRoot = $(if ($env:CLAUDE_NOTIFIER_HOME) { $env:CLAUDE_NOTIFIER_HOME } else { Join-Path $env:USERPROFILE '.claude-notifier' }),
    # Прежнее место (до 2026-11-17): %LOCALAPPDATA%\claude-notifier. Данные переносятся, старый app\ удаляется.
    [string]$LegacyDataRoot = '',
    [string]$SourceRoot = '',   # по умолчанию <папка скрипта>\src ($PSScriptRoot пуст в значениях параметров при -File в PS 5.1)
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')),
    [string]$DesktopDir = ([Environment]::GetFolderPath('DesktopDirectory')),
    [switch]$NoDesktopShortcut
)

$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrEmpty($SourceRoot)) { $SourceRoot = Join-Path $PSScriptRoot 'src' }
Import-Module (Join-Path $SourceRoot 'lib\Settings.psm1') -Force
Import-Module (Join-Path $SourceRoot 'lib\Registration.psm1') -Force
Import-Module (Join-Path $SourceRoot 'lib\Config.psm1') -Force
Import-Module (Join-Path $SourceRoot 'lib\Shortcut.psm1') -Force

try {
    # 1. Сначала проверяем settings.json: при ошибке ничего не меняем.
    $settings = Read-ClaudeSettings -Path $SettingsPath

    # 1а. Перенос с прежнего места (%LOCALAPPDATA%): настройки, история, сеансы, устройства, пороги лимитов.
    #     Только при установке в каталог по умолчанию или с явным -LegacyDataRoot: тесты со своим -DataRoot реальные данные не трогают.
    if ([string]::IsNullOrEmpty($LegacyDataRoot) -and -not $PSBoundParameters.ContainsKey('DataRoot')) { $LegacyDataRoot = Join-Path $env:LOCALAPPDATA 'claude-notifier' }
    $migrated = @()
    if ($LegacyDataRoot -and (Test-Path -LiteralPath $LegacyDataRoot) -and ((Resolve-Path -LiteralPath $LegacyDataRoot).Path -ne $DataRoot)) {
        if (-not (Test-Path -LiteralPath $DataRoot)) { New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null }
        foreach ($name in 'config.json', 'history.json', 'sessions.json', 'network.json', 'limits.json') {
            $from = Join-Path $LegacyDataRoot $name
            $to = Join-Path $DataRoot $name
            if ((Test-Path -LiteralPath $from) -and -not (Test-Path -LiteralPath $to)) { Copy-Item -LiteralPath $from -Destination $to; $migrated += $name }
        }
        $legacyApp = Join-Path $LegacyDataRoot 'app'
        if (Test-Path -LiteralPath $legacyApp) { Remove-Item -LiteralPath $legacyApp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # 2. Копируем приложение начисто. Трей и мосты хуков, запущенные из app\, держат его файлы — закрываем их
    #    (мост, ждущий решения или быстрого ответа, просто выходит: Claude спросит как обычно), трей потом запускаем снова.
    $app = Join-Path $DataRoot 'app'
    $trayWasRunning = $false
    $appPrefix = [regex]::Escape((Join-Path $app ''))
    $holders = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and [string]$_.CommandLine -match $appPrefix })
    foreach ($p in $holders) {
        if ([string]$p.CommandLine -match 'ClaudeNotifier\.Tray\.ps1') { $trayWasRunning = $true }
        Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $app) {
        for ($try = 1; ; $try++) {
            try { Remove-Item -LiteralPath $app -Recurse -Force; break }
            catch { if ($try -ge 10) { throw }; Start-Sleep -Milliseconds 300 }   # процессы ещё выходят
        }
    }
    New-Item -ItemType Directory -Path $app -Force | Out-Null
    Copy-Item -Path (Join-Path $SourceRoot '*') -Destination $app -Recurse -Force
    Get-ChildItem -LiteralPath $app -Recurse -File | Unblock-File

    # 3. Хуки и строка статуса. Прежний statusLine пользователя сохраняется в config.json
    #    (chainStatusLine) до записи settings.json: если config.json записать нельзя, settings не меняется.
    [void](Remove-NotifierHooks -Settings $settings)
    Add-NotifierHooks -Settings $settings -AppRoot $app -Port (Get-NotifierHookPort) -Secret (Get-NotifierHookSecret -DataRoot $DataRoot -Create)
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

    # 5. Ярлыки «Claude Notifier» (иконка приложения, свой AppUserModelID): открывают окно «Сеансы».
    $links = @(Install-NotifierShortcuts -AppRoot $app -NoDesktop:$NoDesktopShortcut -StartMenuDir $StartMenuDir -DesktopDir $DesktopDir)

    Write-Output "claude-notifier установлен в $app"
    Write-Output "Хуки Stop, Notification, StopFailure, SessionStart, UserPromptSubmit, SessionEnd, PermissionRequest и строка статуса добавлены в $SettingsPath"
    if ($null -ne $previousStatusLine) { Write-Output 'Прежняя строка статуса сохранена в config.json (chainStatusLine) и будет показываться первой' }
    Write-Output 'URL-протокол claude-notifier: зарегистрирован'
    Write-Output "Ярлыки Claude Notifier: $($links -join ', ')"
    if ($migrated.Count -gt 0) { Write-Output "Перенесено из $($LegacyDataRoot): $($migrated -join ', ')" }
    if ($backup) { Write-Output "Резервная копия настроек: $backup" }
    if ($trayWasRunning) {
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList @('-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden',
            '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $app 'ClaudeNotifier.Tray.ps1'))
        Write-Output 'Трей перезапущен с новой версией'
    }
    exit 0
}
catch {
    Write-Error -ErrorAction Continue "Установка прервана: $($_.Exception.Message)"
    exit 1
}
