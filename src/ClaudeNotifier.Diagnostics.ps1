<#
.SYNOPSIS
Самодиагностика: «Проверить работу» в меню трея и в шторке. Одним окном — что работает, а что нет.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Проверки только читают: settings.json Claude Code,
приём хуков, строку статуса, доступ из сети, устройства, журнал, автозапуск, уведомления на телефон, обновления.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Settings.psm1')

$script:DiagHookEvents = @('Stop', 'Notification', 'StopFailure', 'SessionStart', 'UserPromptSubmit', 'SessionEnd', 'PermissionRequest')

function New-NotifierDiagItem([string]$Level, [string]$Title, [string]$Detail = '') {
    return [pscustomobject][ordered]@{ Level = $Level; Title = $Title; Detail = $Detail }
}

function Get-NotifierDiagHooks {
    <# .SYNOPSIS Хуки этого ПК в settings.json: каких событий не хватает. #>
    param([string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'))
    try { $s = Read-ClaudeSettings -Path $SettingsPath }
    catch { return (New-NotifierDiagItem error 'Хуки Claude Code' $_.Exception.Message) }
    $missing = @()
    foreach ($ev in $script:DiagHookEvents) {
        $ok = $false
        if ($s.PSObject.Properties['hooks'] -and $s.hooks.PSObject.Properties[$ev]) {
            foreach ($g in @($s.hooks.$ev)) {
                if ($g -and $g.PSObject.Properties['hooks']) { foreach ($h in @($g.hooks)) { if (Test-NotifierHook $h) { $ok = $true } } }
            }
        }
        if (-not $ok) { $missing += $ev }
    }
    if ($missing.Count -eq 0) { return (New-NotifierDiagItem ok 'Хуки Claude Code' 'Все 7 событий подключены') }
    if ($missing.Count -eq $script:DiagHookEvents.Count) { return (New-NotifierDiagItem error 'Хуки Claude Code' "Не установлены $([char]0x2014) запустите install.ps1") }
    return (New-NotifierDiagItem warn 'Хуки Claude Code' "Нет хуков: $($missing -join ', ') $([char]0x2014) запустите install.ps1")
}

function Get-NotifierDiagLogErrors {
    <# .SYNOPSIS Ошибки (ERROR) в журнале за последние 24 часа: сколько и последняя. #>
    param([string]$DataRoot, [datetime]$Now = [DateTime]::UtcNow)
    $p = Join-Path $DataRoot 'log.txt'
    if (-not (Test-Path -LiteralPath $p)) { return (New-NotifierDiagItem ok 'Журнал' 'Ошибок нет') }
    $since = $Now.AddHours(-24).ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture)
    $errors = @()
    try {
        $lines = @(Get-Content -LiteralPath $p -Tail 3000 -Encoding UTF8 -ErrorAction Stop)
        $errors = @($lines | Where-Object { $_ -match '^(\S+) \[ERROR\] (.*)$' -and $Matches[1] -ge $since })
    }
    catch { return (New-NotifierDiagItem warn 'Журнал' "Не читается: $($_.Exception.Message)") }
    if ($errors.Count -eq 0) { return (New-NotifierDiagItem ok 'Журнал' 'Ошибок за сутки нет') }
    $last = ($errors[-1] -replace '^\S+ \[ERROR\] ', '')
    if ($last.Length -gt 120) { $last = $last.Substring(0, 119) + [char]0x2026 }
    return (New-NotifierDiagItem warn 'Журнал' "Ошибок за сутки: $($errors.Count). Последняя: $last")
}

function Get-NotifierDiagnostics {
    <# .SYNOPSIS Все проверки: массив @{ Level = ok | warn | error; Title; Detail }. #>
    param([string]$DataRoot = $script:TrayDataRoot, [string]$SettingsPath = (Join-Path $env:USERPROFILE '.claude\settings.json'), [datetime]$Now = [DateTime]::UtcNow)
    $items = @()
    $items += Get-NotifierDiagHooks -SettingsPath $SettingsPath
    # Приём хуков треем (curl → 127.0.0.1).
    $running = $false
    try { $running = ('ClaudeNotifier.Ui.HookServer' -as [type]) -and [ClaudeNotifier.Ui.HookServer]::Running } catch { }
    if ($running) { $items += New-NotifierDiagItem ok 'Приём событий' "Порт $(Get-NotifierHookPort) слушает" }
    else {
        $err = ''
        try { $err = [string][ClaudeNotifier.Ui.HookServer]::Error } catch { }
        $items += New-NotifierDiagItem error 'Приём событий' "Порт $(Get-NotifierHookPort) не слушает$(if ($err) { ": $err" }) $([char]0x2014) события идут медленным запасным путём"
    }
    try {
        $s = Read-ClaudeSettings -Path $SettingsPath
        if (Test-NotifierStatusLine -Settings $s) { $items += New-NotifierDiagItem ok 'Строка статуса' 'Подключена: лимиты и контекст обновляются' }
        else { $items += New-NotifierDiagItem warn 'Строка статуса' "Не подключена $([char]0x2014) лимиты не видны; запустите install.ps1" }
    }
    catch { }
    # Доступ из сети и устройства.
    $net = $script:Net
    if ($net -and $net.Network -and $net.Network.enabled) {
        if ($net.Server) { $items += New-NotifierDiagItem ok 'Доступ из сети' (Get-NotifierServerBaseUrl $net) }
        else { $items += New-NotifierDiagItem error 'Доступ из сети' "Сервер не запущен: $($net.Error)" }
        foreach ($d in @($net.Network.devices | Where-Object { $_ -and [string]$_.kind -eq 'mac' -and $_.hooks })) {
            $label = "$(Get-NotifierDeviceOsLabel $d) «$([string]$d.name)»"
            $seen = [DateTimeOffset]::MinValue
            $old = -not [DateTimeOffset]::TryParse([string]$d.last_seen, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$seen) -or ($Now - $seen.UtcDateTime).TotalHours -gt 24
            if (Test-NotifierMacHooksOutdated -Device $d) { $items += New-NotifierDiagItem warn $label "Хуки устарели $([char]0x2014) обновятся сами при новом сеансе или «Получить команду установки»" }
            elseif ($old) { $items += New-NotifierDiagItem warn $label "Давно не на связи ($(Format-NotifierLastSeen -Ts ([string]$d.last_seen) -Now $Now))" }
            else { $items += New-NotifierDiagItem ok $label "На связи $(Format-NotifierLastSeen -Ts ([string]$d.last_seen) -Now $Now)" }
        }
    }
    else { $items += New-NotifierDiagItem ok 'Доступ из сети' 'Выключен (Mac и телефон не подключаются)' }
    $config = Get-NotifierConfig -DataRoot $DataRoot
    if ($config.push.enabled) {
        if (Get-NotifierPushTarget ([string]$config.push.url)) { $items += New-NotifierDiagItem ok 'На телефон вне сети' (Format-NotifierPushTarget ([string]$config.push.url)) }
        else { $items += New-NotifierDiagItem error 'На телефон вне сети' 'Включено, но адрес не подходит' }
    }
    $auto = $false; try { $auto = [bool](Test-NotifierAutostart) } catch { }
    if ($auto) { $items += New-NotifierDiagItem ok 'Автозапуск' 'Запускается при входе в Windows' }
    if ($config.notch.stats) {
        try {
            $ct = [ClaudeNotifier.Ui.SysStats]::CpuTemp; $gt = [ClaudeNotifier.Ui.SysStats]::GpuTemp
            if ($ct -gt 0) { $items += New-NotifierDiagItem ok 'Температура' "ЦП $([int][Math]::Round($ct))°$(if ($gt -gt 0) { ", ГП $([int][Math]::Round($gt))°" })" }
            elseif ([ClaudeNotifier.Ui.SysStats]::Cpu -ge 0) { $items += New-NotifierDiagItem warn 'Температура ЦП' "Недоступна $([char]0x2014) запустите LibreHardwareMonitor от администратора (шторка берёт данные из него)" }
        }
        catch { }
    }
    else { $items += New-NotifierDiagItem warn 'Автозапуск' "Выключен $([char]0x2014) после перезагрузки уведомлений не будет, пока не откроете приложение" }
    if ($script:UpdateInfo) { $items += New-NotifierDiagItem warn 'Обновления' "Доступно: новых изменений $($script:UpdateInfo.Count)" }
    elseif (Get-NotifierAppVersion) { $items += New-NotifierDiagItem ok 'Обновления' (Format-NotifierUpdateSubtitle) }
    $items += Get-NotifierDiagLogErrors -DataRoot $DataRoot -Now $Now
    return $items
}

function Format-NotifierDiagnostics {
    <# .SYNOPSIS Текст окна: строка на проверку со значком ✓ / ! / ✗; первой строкой — итог. #>
    param([Parameter(Mandatory = $true)][object[]]$Items)
    $bad = @($Items | Where-Object { $_.Level -eq 'error' }).Count
    $warn = @($Items | Where-Object { $_.Level -eq 'warn' }).Count
    $head = 'Всё работает.'
    if ($bad -gt 0) { $head = "Есть неполадки: $bad." }
    elseif ($warn -gt 0) { $head = "Работает, но обратите внимание: $warn." }
    $mark = @{ ok = [string][char]0x2713; warn = '!'; error = [string][char]0x2717 }
    $lines = @($head, '')
    foreach ($i in $Items) {
        $t = "$($mark[$i.Level])  $($i.Title)"
        if ($i.Detail) { $t += " $([char]0x2014) $($i.Detail)" }
        $lines += $t
    }
    return ($lines -join "`n")
}

function Show-NotifierDiagnostics {
    <# .SYNOPSIS «Проверить работу»: окно с итогами; «Открыть журнал» — log.txt в Блокноте. #>
    $items = @(Get-NotifierDiagnostics)
    Write-NotifierLog -Level INFO -Message "tray: проверка работы $([char]0x2014) $(@($items | Where-Object { $_.Level -ne 'ok' }).Count) замечаний" -DataRoot $script:TrayDataRoot
    $script:DialogOpen = $true
    try { $r = Show-NotifierDialog -Owner $null -Title 'Проверка работы' -Message (Format-NotifierDiagnostics -Items $items) -Primary 'Открыть журнал' -Secondary 'Закрыть' }
    finally { $script:DialogOpen = $false }
    if ($r.Ok) {
        $log = Join-Path $script:TrayDataRoot 'log.txt'
        if (Test-Path -LiteralPath $log) { Start-Process notepad.exe -ArgumentList "`"$log`"" }
    }
}
