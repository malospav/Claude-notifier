<#
.SYNOPSIS
Умная тишина, голос и правила проектов.

.DESCRIPTION
* Умная тишина (config.smartQuiet): пока идёт игра или другое полноэкранное приложение, презентация или звонок
  (микрофон занят), уведомления не всплывают и не звучат — копятся и приходят одной сводкой, когда вы освободились.
  Статус сеансов и шторка обновляются как обычно.
* Голос (config.voice): вас нет за ПК дольше voice.idle минут — короткая фраза голосом Windows
  («Claude закончил: проект»). Молчит в тихие часы и при «Без звука».
* Правила проектов (config.projects): для проекта — все уведомления, только важные (без «Готово») или никаких.
  Задаются в меню сеанса (правый щелчок по сеансу).
#>

$script:HeldEvents = New-Object System.Collections.ArrayList
$script:BusyCache = @{ At = [datetime]::MinValue; Reason = '' }
$script:Speaker = $null

# --- Правила проектов ---

function Get-NotifierProjectRule {
    <# .SYNOPSIS Правило уведомлений проекта: all | important | off. #>
    param($Config, [string]$Project)
    if ([string]::IsNullOrEmpty($Project) -or $null -eq $Config -or -not $Config.ContainsKey('projects') -or $null -eq $Config.projects) { return 'all' }
    $p = $Config.projects
    if ($p -is [hashtable] -and $p.ContainsKey($Project)) { return [string]$p[$Project] }
    return 'all'
}

function Test-NotifierProjectAllows {
    <# .SYNOPSIS Показывать ли уведомление этого события по правилу его проекта. #>
    param([Parameter(Mandatory = $true)]$Event, $Config)
    $project = if ($Event.PSObject.Properties['project']) { [string]$Event.project } else { '' }
    switch (Get-NotifierProjectRule -Config $Config -Project $project) {
        'off' { return $false }
        'important' { return [string]$Event.type -ne 'done' }
    }
    return $true
}

function Set-NotifierProjectRule {
    <# .SYNOPSIS Задать правило проекта (all — убрать правило). #>
    param([Parameter(Mandatory = $true)][string]$Project, [Parameter(Mandatory = $true)][ValidateSet('all', 'important', 'off')][string]$Rule, [string]$DataRoot = $script:TrayDataRoot)
    if ($Project.Trim() -eq '') { return }
    $c = Get-NotifierConfig -DataRoot $DataRoot
    $map = [ordered]@{}
    if ($c.projects -is [hashtable]) { foreach ($k in $c.projects.Keys) { $map[[string]$k] = [string]$c.projects[$k] } }
    if ($Rule -eq 'all') { $map.Remove($Project) } else { $map[$Project] = $Rule }
    $value = if ($map.Count -eq 0) { $null } else { [pscustomobject]$map }
    Set-NotifierConfigValue -Name projects -Value $value -DataRoot $DataRoot
    Write-NotifierLog -Level INFO -Message "notch: правило уведомлений проекта — $Rule" -DataRoot $DataRoot
}

# --- Умная тишина ---

function Test-NotifierMicrophoneBusy {
    <# .SYNOPSIS Микрофон сейчас занят каким-то приложением (идёт звонок или запись) — по журналу доступа Windows. #>
    $roots = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone\NonPackaged')
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($k in @(Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue)) {
            if ($k.PSChildName -eq 'NonPackaged') { continue }
            try {
                $start = [int64]$k.GetValue('LastUsedTimeStart', 0)
                $stop = [int64]$k.GetValue('LastUsedTimeStop', 0)
                if ($start -gt 0 -and $stop -eq 0) { return $true }
            }
            catch { }
        }
    }
    return $false
}

function Get-NotifierBusyReason {
    <#
    .SYNOPSIS
    Чем вы заняты: fullscreen (игра, видео на весь экран), presentation (режим презентации), call (микрофон занят)
    или '' — не заняты. Проверка не чаще раза в 2 с.
    #>
    param([datetime]$Now = [DateTime]::UtcNow, [switch]$Force)
    if (-not $Force -and $script:BusyProbe -eq $false) { return '' }
    if (($Now - $script:BusyCache.At).TotalSeconds -lt 2) { return $script:BusyCache.Reason }
    $reason = ''
    try {
        # SHQueryUserNotificationState: 3 — Direct3D на весь экран, 4 — презентация. «2 — занят» Windows отвечает
        # и без полноэкранного окна — тогда проверяем, правда ли активное окно закрывает весь монитор.
        $st = [ClaudeNotifier.Win32]::UserNotificationState()
        if ($st -eq 3) { $reason = 'fullscreen' }
        elseif ($st -eq 4) { $reason = 'presentation' }
        elseif ($st -eq 2 -and [ClaudeNotifier.Win32]::ForegroundFullscreen()) { $reason = 'fullscreen' }
    }
    catch { }
    if ($reason -eq '') { try { if (Test-NotifierMicrophoneBusy) { $reason = 'call' } } catch { } }
    $script:BusyCache = @{ At = $Now; Reason = $reason }
    return $reason
}

function Add-NotifierHeldEvent {
    <# .SYNOPSIS Событие отложено умной тишиной (хранится до 50 последних). #>
    param([Parameter(Mandatory = $true)]$Event)
    [void]$script:HeldEvents.Add($Event)
    while ($script:HeldEvents.Count -gt 50) { $script:HeldEvents.RemoveAt(0) }
}

function New-NotifierHeldSummary {
    <# .SYNOPSIS Отложенные события → одно событие-сводка (тип — самое важное из них) или $null. #>
    param([object[]]$Events = @($script:HeldEvents))
    $list = @($Events | Where-Object { $_ })
    if ($list.Count -eq 0) { return $null }
    $names = [ordered]@{ permission = 'запросы'; error = 'ошибки'; limit = 'лимиты'; done = 'готово' }
    $parts = @()
    foreach ($t in $names.Keys) {
        $n = @($list | Where-Object { [string]$_.type -eq $t }).Count
        if ($n -gt 0) { $parts += "$($names[$t]): $n" }
    }
    $type = 'done'
    foreach ($t in @('permission', 'error', 'limit')) { if (@($list | Where-Object { [string]$_.type -eq $t }).Count -gt 0) { $type = $t; break } }
    $projects = @($list | ForEach-Object { if ($_.PSObject.Properties['project']) { [string]$_.project } } | Where-Object { $_ } | Select-Object -Unique)
    $preview = ($parts -join ', ')
    if ($projects.Count -gt 0) { $preview += " $([char]0x2014) " + (($projects | Select-Object -First 3) -join ', ') + $(if ($projects.Count -gt 3) { " и ещё $($projects.Count - 3)" }) }
    $last = $list[-1]
    return [pscustomobject]@{
        v = 1; id = [guid]::NewGuid().ToString(); ts = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        type = $type; title = "Пока вы были заняты $([char]0x00B7) событий: $($list.Count)"; preview = $preview
        session_id = $(if ($last.PSObject.Properties['session_id']) { [string]$last.session_id } else { '' })
        summary = $true
    }
}

function Invoke-NotifierHeldTick {
    <# .SYNOPSIS Из таймера трея: вы освободились — сводка отложенных уведомлений (одна, со звуком). #>
    param([string]$DataRoot = $script:TrayDataRoot)
    if ($script:HeldEvents.Count -eq 0) { return }
    if ((Get-NotifierBusyReason) -ne '') { return }
    $summary = New-NotifierHeldSummary
    $script:HeldEvents.Clear()
    if ($null -eq $summary -or $script:TrayNoOutput) { return }
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $inline = $false
    try { $inline = Test-NotifierNotchInline -Event $summary -Config $config -IdleSeconds (Get-NotifierIdleSeconds) } catch { }
    if ($inline) { [ClaudeNotifier.Ui.NotchHost]::Peek("$($summary.title) $([char]0x2014) $($summary.preview)", 7000) }
    else { [void](Show-NotifierToast -Event $summary -DataRoot $DataRoot) }
    if (-not (Test-NotifierQuietTime -Config $config)) { [void](Invoke-NotifierSound -Type $summary.type -Config $config -DataRoot $DataRoot) }
    Write-NotifierLog -Level INFO -Message "tray: умная тишина закончилась $([char]0x2014) сводка, событий: $(@($summary.title -split ': ')[-1])" -DataRoot $DataRoot
}

# --- Голос ---

function Get-NotifierSpeechText {
    <# .SYNOPSIS Короткая фраза для голоса: что случилось и в каком проекте. '' — не говорить. #>
    param([Parameter(Mandatory = $true)]$Event)
    $project = if ($Event.PSObject.Properties['project']) { [string]$Event.project } else { '' }
    $what = switch ([string]$Event.type) {
        'done' { 'Claude закончил' } 'permission' { 'Claude просит разрешения' } 'error' { 'Ошибка у Claude' } 'limit' { 'Лимит Claude почти исчерпан' }
        default { '' }
    }
    if ($what -eq '') { return '' }
    if ($project) { return "${what}: $project" }
    return $what
}

function Test-NotifierVoiceDue {
    <# .SYNOPSIS Говорить ли голосом: включено, вас нет за ПК дольше voice.idle минут, не тихие часы. #>
    param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Config, [double]$IdleSeconds = 0)
    if (-not $Config.ContainsKey('voice') -or -not $Config.voice.enabled) { return $false }
    if ($IdleSeconds -lt [int]$Config.voice.idle * 60) { return $false }
    if (Test-NotifierQuietTime -Config $Config) { return $false }
    return (Get-NotifierSpeechText -Event $Event) -ne ''
}

function Invoke-NotifierSpeak {
    <# .SYNOPSIS Сказать фразу голосом Windows (русский голос, если установлен), не блокируя трей. #>
    param([Parameter(Mandatory = $true)][string]$Text)
    try {
        if ($null -eq $script:Speaker) {
            Add-Type -AssemblyName System.Speech
            $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
            $ru = @($sp.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'ru*' }) | Select-Object -First 1
            if ($ru) { $sp.SelectVoice($ru.VoiceInfo.Name) }
            $sp.Rate = 0
            $script:Speaker = $sp
        }
        $script:Speaker.SpeakAsyncCancelAll()
        [void]$script:Speaker.SpeakAsync($Text)
        return $true
    }
    catch {
        Write-NotifierLog -Level WARN -Message "tray: голос: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot
        return $false
    }
}
