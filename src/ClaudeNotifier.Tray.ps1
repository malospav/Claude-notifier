<#
.SYNOPSIS
Трей-программа claude-notifier: принимает события по named pipe, показывает toast и играет звук.

.DESCRIPTION
Один экземпляр на пользователя (мьютекс Local\claude-notifier). Сервер pipe работает в фоновом
runspace и кладёт события в очередь; таймер WinForms раз в 100 мс разбирает её в UI-потоке.
Обычно запускается hook-bridge.ps1 через conhost --headless.

.PARAMETER NoOutput
Для тестов: события обрабатываются и логируются, но уведомление не показывается и звук не играет.

.PARAMETER MutexName
Имя мьютекса одного экземпляра; тесты задают своё, чтобы не мешать установленному трею.
#>
param(
    [switch]$NoOutput,
    [string]$MutexName = 'Local\claude-notifier',
    [switch]$Show   # запуск ярлыком: открыть окно «Сеансы» (если трей уже работает — попросить его)
)

Import-Module (Join-Path $PSScriptRoot 'lib\Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Ipc.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Toast.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Sound.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\History.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Window.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Sessions.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Shortcut.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Usage.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Limits.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Text.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Transcript.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Event.psm1')        # события из хуков, принятых треем напрямую (curl)
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Ui.ps1')        # окно «Сеансы», точка в трее, диалоги
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Network.ps1')   # доступ из сети, вкладка «Устройства»
. (Join-Path $PSScriptRoot 'ClaudeNotifier.SettingsUi.ps1')  # вкладка «Настройки», автозапуск
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Replies.ps1')     # ответы из приложения: разрешения, вопросы, быстрые ответы
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Popover.ps1')     # мини-окно у трея по одиночному щелчку
. (Join-Path $PSScriptRoot 'ClaudeNotifier.StatsUi.ps1')     # страница «Статистика»: токены и время по дням и проектам
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Attention.ps1')   # контекст, напоминания, мигание точки, горячая клавиша, имя/закрепление
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Notch.ps1')       # шторка вверху экрана: персонажи сеансов, раскрытая панель

$script:EventTypes = @('done', 'permission', 'error', 'limit', 'start', 'working', 'end', 'show', 'request')
# Служебные события (SessionStart, UserPromptSubmit, SessionEnd): только для окна «Сеансы».
$script:SilentTypes = @('start', 'working', 'end')
$script:SessionsRefreshMs = 5000
$script:SessionsForm = $null
$script:SessionsDirty = $false
$script:SessionsRefreshedAt = [datetime]::MinValue
$script:MaxBatch = 20
$script:TickMs = 100
$script:IdleTickMs = 250
$script:AwayTickMs = 1000  # вас нет за компьютером: события всё равно доходят (секунда задержки не важна)   # в покое (нет событий 5 с, шторка свёрнута) таймер реже — меньше нагрузки в фоне
$script:IdleTrimMs = 30000
$script:RepeatTrimMs = 300000

function Invoke-WorkingSetTrim {
    # Отдаёт системе неиспользуемые страницы рабочего набора (EmptyWorkingSet).
    # Процесс PowerShell с WinForms и WinRT держит ≈ 140 МБ рабочего набора; в простое после
    # обрезки — ≈ 6–8 МБ. Приватная (выделенная) память при этом не уменьшается.
    Import-TrayNative
    return [ClaudeNotifier.TrayNative]::EmptyWorkingSet([System.Diagnostics.Process]::GetCurrentProcess().Handle)
}

function Import-TrayNative {
    # Нативные функции трея (компилируются один раз за запуск, при первом использовании).
    if (-not ('ClaudeNotifier.TrayNative' -as [type])) {
        Add-Type -TypeDefinition @'
namespace ClaudeNotifier {
    public static class TrayNative {
        [System.Runtime.InteropServices.DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(System.IntPtr h);
        [System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct LastInput { public uint cbSize; public uint dwTime; }
        [System.Runtime.InteropServices.DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput info);
        // Сколько секунд не было ввода с клавиатуры и мыши.
        public static double IdleSeconds() {
            LastInput i = new LastInput(); i.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(i);
            if (!GetLastInputInfo(ref i)) return 0;
            return unchecked((uint)System.Environment.TickCount - i.dwTime) / 1000.0;
        }
    }
}
'@
    }
}

function Get-NotifierIdleSeconds {
    <# .SYNOPSIS Сколько секунд пользователь не трогал клавиатуру и мышь (0 — не удалось узнать). #>
    try { Import-TrayNative; return [ClaudeNotifier.TrayNative]::IdleSeconds() } catch { return 0 }
}

function Invoke-AllowForeground {
    # Передаёт право вывести окно на передний план процессу, который трей запустит по клику (ASFW_ANY).
    Import-TrayNative
    return [ClaudeNotifier.TrayNative]::AllowSetForegroundWindow(-1)
}

function Start-NotifierFocusHandler {
    <#
    .SYNOPSIS
    Запускает focus-handler.ps1 с URI события — тот же путь, что у клика по toast (ADR-004).
    #>
    param([Parameter(Mandatory = $true)][string]$Id)
    [void](Invoke-AllowForeground)
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $handler = Join-Path $PSScriptRoot 'focus-handler.ps1'
    Start-Process -FilePath $conhost -ArgumentList @('--headless', "`"$ps`"", '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', "`"$handler`"", "`"claude-notifier:focus?id=$Id`"") -WindowStyle Hidden | Out-Null
}

function Update-NotifierHistoryMenu {
    <#
    .SYNOPSIS
    Заполняет подменю «История» 20 последними событиями (новые сверху); клик → Start-NotifierFocusHandler.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.ToolStripMenuItem]$MenuItem,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    $MenuItem.DropDownItems.Clear()
    $items = @(Get-NotifierHistory -DataRoot $DataRoot)
    if ($items.Count -eq 0) {
        $empty = New-Object System.Windows.Forms.ToolStripMenuItem '(пусто)'
        $empty.Enabled = $false
        [void]$MenuItem.DropDownItems.Add($empty)
        return
    }
    $last = @($items[([Math]::Max(0, $items.Count - 20))..($items.Count - 1)])
    [array]::Reverse($last)
    foreach ($ev in $last) {
        $entry = New-Object System.Windows.Forms.ToolStripMenuItem (Format-NotifierHistoryItem -Event $ev)
        $entry.Tag = [string]$ev.id
        $entry.add_Click({ Start-NotifierFocusHandler -Id $this.Tag })
        [void]$MenuItem.DropDownItems.Add($entry)
    }
}

function Test-IdleTrimDue {
    <#
    .SYNOPSIS
    Нужно ли обрезать рабочий набор: с последней активности прошло ≥ IdleMs и после неё ещё не
    обрезали — либо простой продолжается и с прошлой обрезки прошло ≥ RepeatMs (таймер понемногу
    возвращает страницы в рабочий набор).
    #>
    param([datetime]$LastActivity, [datetime]$LastTrim, [datetime]$Now, [int]$IdleMs = $script:IdleTrimMs, [int]$RepeatMs = $script:RepeatTrimMs)
    if (($Now - $LastActivity).TotalMilliseconds -lt $IdleMs) { return $false }
    return ($LastTrim -lt $LastActivity) -or (($Now - $LastTrim).TotalMilliseconds -ge $RepeatMs)
}

function Enter-NotifierMutex {
    <#
    .SYNOPSIS
    Захватывает именованный мьютекс. Возвращает объект Mutex или $null, если экземпляр уже запущен.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $created = $false
    $mutex = New-Object System.Threading.Mutex($true, $Name, [ref]$created)
    if ($created) { return $mutex }
    $mutex.Dispose()
    return $null
}

function Test-NotifierEventShape {
    <# .SYNOPSIS $true, если объект из pipe похож на событие v1 (тип из списка, строки title/preview). #>
    param($Event)
    if ($Event -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    foreach ($name in @('type', 'title')) {
        $p = $Event.PSObject.Properties[$name]
        if ($null -eq $p -or $p.Value -isnot [string]) { return $false }
    }
    if ($script:EventTypes -notcontains $Event.type) { return $false }
    $preview = $Event.PSObject.Properties['preview']
    if ($preview -and $null -ne $preview.Value -and $preview.Value -isnot [string]) { return $false }
    return $true
}

function Get-EventLatencyMs {
    <# .SYNOPSIS Миллисекунды от поля ts события до сейчас или -1, если ts нет или он не разобран. #>
    param($Event)
    $ts = $Event.PSObject.Properties['ts']
    if ($null -eq $ts) { return -1 }
    $parsed = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse([string]$ts.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return -1 }
    return [int]([DateTimeOffset]::UtcNow - $parsed).TotalMilliseconds
}

function Invoke-NotifierEventBatch {
    <#
    .SYNOPSIS
    Разбирает до MaxBatch событий из очереди: для каждого toast + звук. Ошибка одного события
    логируется и не мешает остальным.

    .OUTPUTS
    Число обработанных (показанных) событий.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Queue,
        [string]$DataRoot = (Get-NotifierDataRoot),
        [switch]$NoOutput,
        [int]$MaxBatch = $script:MaxBatch
    )
    if ($Queue.IsEmpty) { return 0 }
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $shown = 0
    $sessions = $null
    $prefs = $null
    for ($i = 0; $i -lt $MaxBatch; $i++) {
        $event = $null
        if (-not $Queue.TryDequeue([ref]$event)) { break }
        try {
            if (-not (Test-NotifierEventShape $event)) {
                Write-NotifierLog -Level WARN -Message 'tray: отброшено событие неверного формата' -DataRoot $DataRoot
                continue
            }
            if ($event.type -eq 'show') { Show-NotifierSessionsWindow; $shown++; continue }   # щелчок по ярлыку
            if (Test-NotifierHelperEvent -Event $event -DataRoot $DataRoot) {
                # Уже попавший в список служебный сеанс (распознан не с первого события) — убрать.
                if ($null -eq $sessions) { $sessions = @(Get-NotifierSessions -DataRoot $DataRoot) }
                $sid = [string]$event.session_id
                if (@($sessions | Where-Object { [string]$_.session_id -eq $sid }).Count -gt 0) {
                    $sessions = @($sessions | Where-Object { [string]$_.session_id -ne $sid })
                    Save-NotifierSessions -Sessions $sessions -DataRoot $DataRoot
                }
                continue
            }
            $remote = Test-NotifierRemoteEventMuted -Event $event   # show | quiet | drop (события других устройств)
            $duplicate = Test-NotifierDuplicatePermissionToast -Event $event
            # Новый запрос или ответ прямо в Claude: ожидание быстрого ответа по этому сеансу больше не нужно.
            if (@('working', 'start', 'end') -contains $event.type -and $event.PSObject.Properties['session_id'] -and $event.session_id) {
                try { Remove-NotifierReplyWait -SessionId ([string]$event.session_id) -DataRoot $DataRoot } catch { }
            }
            if ($remote -eq 'drop') { continue }
            # Статус сеанса обновляется для любого события, даже если уведомление этого типа выключено
            # (кроме notifyOnly — «сеанс, похоже, остановился»: статус не меняется).
            $notifyOnly = $event.PSObject.Properties['notifyOnly'] -and $event.notifyOnly
            $before = $null
            try {
                if ($null -eq $sessions) { $sessions = @(Get-NotifierSessions -DataRoot $DataRoot) }
                if ($event.PSObject.Properties['session_id'] -and $event.session_id) {
                    $before = @($sessions | Where-Object { [string]$_.session_id -eq [string]$event.session_id }) | Select-Object -First 1
                }
                if (-not $notifyOnly) { $sessions = Update-NotifierSessionList -Sessions $sessions -Event $event }
            }
            catch { Write-NotifierLog -Level ERROR -Message "tray: статус сеанса не обновлён: $($_.Exception.Message)" -DataRoot $DataRoot }
            $wasRequest = $event.type -eq 'request'
            if ($wasRequest) { $event.type = 'permission' }   # уведомление, звук и история — как «Нужно разрешение»
            elseif ($duplicate -and -not ($event.PSObject.Properties['reminder'] -and $event.reminder)) { $shown++; continue }   # дубль уведомления Claude о том же запросе
            $late = $event.PSObject.Properties['late'] -and $event.late   # отложенное событие с Mac: только статус
            if ($script:SilentTypes -contains $event.type -or $remote -eq 'quiet' -or $late) { $shown++; continue }
            # Сеанс «без уведомлений»: статус обновлён, но ни уведомления, ни звука.
            if ($event.PSObject.Properties['session_id'] -and $event.session_id) {
                if ($null -eq $prefs) { $prefs = Get-NotifierSessionPrefs -DataRoot $DataRoot }
                if (Test-NotifierSessionMuted ([string]$event.session_id) $prefs) { $shown++; continue }
            }
            # Предупреждение о контексте и «сеанс остановился» включаются своими тумблерами, а не тумблерами типа.
            $option = ''
            if ($event.PSObject.Properties['option']) { $option = [string]$event.option }
            elseif ($event.PSObject.Properties['context'] -and $event.context) { $option = 'context' }
            if ($option -ne '') { if (-not $config[$option].enabled) { continue } }
            elseif (-not $config.events[$event.type].enabled) { continue }
            # «Готово» после короткой задачи, пока вы за компьютером, — без уведомления и звука (в истории остаётся).
            $quiet = $event.type -eq 'done' -and (Test-NotifierQuickTask -Session $before -Event $event -Config $config -IdleSeconds (Get-NotifierIdleSeconds))
            # В историю — до показа: клик по toast сразу ищет событие в history.json.
            try { [void](Add-NotifierHistory -Event $event -DataRoot $DataRoot) }
            catch { Write-NotifierLog -Level ERROR -Message "tray: история не записана: $($_.Exception.Message)" -DataRoot $DataRoot }
            if ($quiet) {
                $shown++
                Write-NotifierLog -Level INFO -Message "tray: 'done' без уведомления — короткая задача" -DataRoot $DataRoot
                continue
            }
            if (-not $NoOutput) {
                $buttons = @()
                try { $buttons = @(Get-NotifierToastButtons -Event $event -Config $config -Request:$wasRequest -DataRoot $DataRoot) } catch { }
                [void](Show-NotifierToast -Event $event -Actions $buttons -DataRoot $DataRoot)
                if (-not (Test-NotifierQuietTime -Config $config)) { [void](Invoke-NotifierSound -Type $event.type -Config $config -DataRoot $DataRoot) }   # звук выключен в шторке или по расписанию
            }
            $shown++
            Write-NotifierLog -Level INFO -Message "tray: показано '$($event.type)', задержка $(Get-EventLatencyMs $event) мс" -DataRoot $DataRoot
        }
        catch {
            Write-NotifierLog -Level ERROR -Message "tray: ошибка обработки события: $($_.Exception.Message)" -DataRoot $DataRoot
        }
    }
    if ($null -ne $sessions) {
        try {
            Save-NotifierSessions -Sessions $sessions -DataRoot $DataRoot
            $script:SessionsDirty = $true
        }
        catch { Write-NotifierLog -Level ERROR -Message "tray: sessions.json не записан: $($_.Exception.Message)" -DataRoot $DataRoot }
    }
    return $shown
}

function New-NotifierShowEvent {
    <# .SYNOPSIS Служебное событие «открыть окно Сеансы» (ярлык → трей). #>
    return [pscustomobject]@{ v = 1; type = 'show'; title = 'show'; preview = '' }
}

function Request-NotifierShowWindow {
    <#
    .SYNOPSIS
    Трей уже работает: разрешить ему вывести окно на передний план (право есть у процесса,
    запущенного щелчком по ярлыку) и передать команду «показать окно» по pipe. Возвращает $true, если доставлено.
    #>
    param([string]$DataRoot = (Get-NotifierDataRoot), [string]$PipeName = (Get-NotifierPipeName))
    try { [void](Import-NotifierUi); [void][ClaudeNotifier.Ui.Native]::AllowForeground() } catch { }
    $ok = Send-NotifierEvent -Event (New-NotifierShowEvent) -PipeName $PipeName
    if (-not $ok) { Write-NotifierLog -Level WARN -Message 'tray: окно не открыто — трей не ответил' -DataRoot $DataRoot }
    return $ok
}

$script:UsageFetch = $null
$script:UsageNextAt = [datetime]::MinValue
$script:UsageIntervalMin = 5

function Invoke-NotifierUsageTick {
    <#
    .SYNOPSIS
    Раз в 5 минут спрашивает сервер Anthropic о расходе (если есть вход в Claude Code CLI); по готовности
    обновляет полосы и проверяет пороги 80/90 % — так предупреждения о лимите работают и в приложении Claude.
    #>
    param([datetime]$Now = [DateTime]::UtcNow)
    if ($script:UsageFetch) {
        $r = Complete-NotifierUsageFetch -Fetch $script:UsageFetch -DataRoot $script:TrayDataRoot
        if ($r -eq 'pending') {
            if (($Now - $script:UsageFetch.Started).TotalSeconds -gt 30) { $script:UsageFetch = $null }
            return
        }
        $script:UsageFetch = $null
        if ($r -eq 'ok') {
            $usage = Get-NotifierUsage -DataRoot $script:TrayDataRoot
            $status = ConvertTo-NotifierLimitStatus -Usage $usage
            foreach ($res in @(Test-NotifierLimits -StatusJson $status -DataRoot $script:TrayDataRoot)) {
                if ($res) { $script:TrayQueue.Enqueue((New-NotifierLimitEvent -Result $res -StatusJson $status)) }
            }
            $script:SessionsDirty = $true
        }
        return
    }
    if ($Now -lt $script:UsageNextAt) { return }
    $script:UsageNextAt = $Now.AddMinutes($script:UsageIntervalMin)
    $script:UsageFetch = Start-NotifierUsageFetch
    # Нет действующего входа Claude Code CLI (токен истёк — CLI обновляет его только при запуске): расход не
    # обновляется. Пишем в журнал один раз, пока ситуация не изменится.
    if ($null -eq $script:UsageFetch) {
        if (-not $script:UsageNoTokenLogged) {
            Write-NotifierLog -Level WARN -Message 'usage: нет действующего входа Claude Code CLI — расход не обновляется (запустите claude в терминале)' -DataRoot $script:TrayDataRoot
            $script:UsageNoTokenLogged = $true
        }
    }
    else { $script:UsageNoTokenLogged = $false }
}

function Stop-NotifierTray {
    <#
    .SYNOPSIS
    Пункт «Выход»: останавливает таймер и сервер pipe, убирает иконку, освобождает мьютекс.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)
    # Каждый шаг — сам по себе: сбой одного не должен оставить «призрак» иконки в трее и занятый мьютекс.
    try {
        try { if ($State.Timer) { $State.Timer.Stop(); $State.Timer.Dispose() } } catch { }
        try { if ($State.Server) { [void](Stop-NotifierPipeServer -Server $State.Server) } } catch { }
        try { if ('ClaudeNotifier.Ui.HookServer' -as [type]) { [ClaudeNotifier.Ui.HookServer]::Stop() } } catch { }
        if ($script:HotKey) { try { $script:HotKey.Dispose() } catch { }; $script:HotKey = $null }
        if ($script:TrayClickTimer) { try { $script:TrayClickTimer.Stop(); $script:TrayClickTimer.Dispose() } catch { }; $script:TrayClickTimer = $null }
        try { if ('ClaudeNotifier.Ui.NotchHost' -as [type]) { [ClaudeNotifier.Ui.NotchHost]::Stop() } } catch { }
        try { Stop-NotifierNetServer } catch { }
        try { if ($script:ConnectForm -and -not $script:ConnectForm.IsDisposed) { $script:ConnectForm.Dispose() } } catch { }
        try { if ($script:SessionsForm -and -not $script:SessionsForm.IsDisposed) { $script:SessionsForm.Dispose() } } catch { }
    }
    finally {
        try { if ($State.Icon) { $State.Icon.Visible = $false; $State.Icon.Dispose() } } catch { }
        try { if ($State.Mutex) { $State.Mutex.ReleaseMutex(); $State.Mutex.Dispose() } } catch { }
        $State.Stopped = $true
    }
}

function New-NotifierTrayIcon {
    <#
    .SYNOPSIS
    Иконка трея — цветная точка статуса сеансов; меню «Сеансы» / «Устройства» / «История ▸» / «Выход»
    в цветах темы Windows. Двойной клик — окно сеансов.
    #>
    param([Parameter(Mandatory = $true)][scriptblock]$OnExit, [string]$DataRoot = (Get-NotifierDataRoot))
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $theme = Get-NotifierTheme
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $icon.Icon = Get-NotifierDotIcon 'none'
    $icon.Text = 'Claude · сеансов нет'
    Register-NotifierTrayClicks -Icon $icon   # щелчок — мини-окно, двойной щелчок — полное окно
    $menu = New-NotifierMenu -Theme $theme -Items @(
        @('Сеансы', { Show-NotifierSessionsWindow -Tab 0 }),
        @('Устройства', { Show-NotifierSessionsWindow -Tab 1 }),
        @('Настройки', { Show-NotifierSessionsWindow -Tab 2 }),
        @('Статистика', { Show-NotifierSessionsWindow -Tab 3 }),
        @('История', $null),
        '-',
        @('Выход', $OnExit)
    )
    $menu.Items[0].Font = [ClaudeNotifier.Ui.Fonts]::Semibold(9.5)
    $history = $menu.Items[4]
    $history.Tag = $DataRoot   # обработчику нужен каталог данных: $this.Tag вместо замыкания
    [void]$history.DropDownItems.Add('(пусто)')   # чтобы у пункта была стрелка подменю
    $history.DropDown.Renderer = $menu.Renderer
    $history.DropDown.Font = $menu.Font
    $history.add_DropDownOpening({ Update-NotifierHistoryMenu -MenuItem $this -DataRoot $this.Tag })
    $icon.ContextMenuStrip = $menu
    $icon.Visible = $true
    return $icon
}

function Get-NotifierTickInterval {
    <#
    .SYNOPSIS
    Частота таймера трея: 100 мс, пока идут события или открыта шторка (быстрый отклик), иначе 250 мс;
    вас нет за компьютером (2 мин без ввода) — раз в секунду.
    #>
    param([datetime]$LastActivity, [datetime]$Now = [datetime]::UtcNow, [bool]$Expanded = $(try { [ClaudeNotifier.Ui.NotchHost]::ExpandedNow } catch { $false }),
        [double]$IdleSeconds = $(try { [ClaudeNotifier.Ui.Native]::InputIdleSeconds() } catch { 0 }))
    if ($Expanded -or ($Now - $LastActivity).TotalSeconds -lt 5) { return $script:TickMs }
    if ($IdleSeconds -ge 120) { return $script:AwayTickMs }
    return $script:IdleTickMs
}

function Add-NotifierHelperSession {
    <# .SYNOPSIS Запомнить служебный сеанс: все его дальнейшие события отбрасываются. В журнал — один раз. #>
    param([AllowEmptyString()][string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    if ([string]::IsNullOrEmpty($SessionId)) { return }
    if (-not $script:NestedLogged) { $script:NestedLogged = @{} }
    if ($script:NestedLogged.ContainsKey($SessionId)) { return }
    $script:NestedLogged[$SessionId] = $true
    Write-NotifierLog -Level INFO -Message "tray: служебный запуск Claude внутри другого сеанса ($SessionId) — не показывается" -DataRoot $DataRoot
}

function Test-NotifierHelperEvent {
    <#
    .SYNOPSIS
    Событие служебного запуска Claude (сводка сеанса через «claude -p»)? Однажды распознанный сеанс запоминается:
    проверка по дереву процессов срабатывает не на каждый хук — сводка идёт при завершении сеанса, и к хуку Stop
    его родитель уже может выйти. Поэтому ещё и по журналу: первый запрос — «Below is a conversation log…».
    #>
    param([Parameter(Mandatory = $true)]$Event, [string]$DataRoot = $script:TrayDataRoot)
    if (-not ($Event.PSObject.Properties['session_id'] -and $Event.session_id)) { return $false }
    $sid = [string]$Event.session_id
    if (-not $script:NestedLogged) { $script:NestedLogged = @{} }
    if ($script:NestedLogged.ContainsKey($sid)) { return $true }
    if ($Event.PSObject.Properties['helper'] -and $Event.helper) { Add-NotifierHelperSession -SessionId $sid -DataRoot $DataRoot; return $true }
    if (-not $script:HelperChecked) { $script:HelperChecked = @{} }
    if ($script:HelperChecked.ContainsKey($sid)) { return $false }
    $path = ''
    if ($Event.PSObject.Properties['transcript'] -and $Event.transcript) { $path = [string]$Event.transcript }
    $helper = Test-NotifierHelperTranscript -Path $path
    if ($null -eq $helper) { return $false }   # журнала ещё нет — проверим на следующем событии
    $script:HelperChecked[$sid] = $true
    if ($helper) { Add-NotifierHelperSession -SessionId $sid -DataRoot $DataRoot }
    return [bool]$helper
}

function ConvertFrom-NotifierHookCall {
    <#
    .SYNOPSIS
    Хук, принятый треем напрямую (curl → HookServer) → событие v1, как от PowerShell-моста; $null — отброшено
    (неразобранный JSON или тип уведомлений выключен).
    #>
    param([Parameter(Mandatory = $true)]$Call, [string]$DataRoot = $script:TrayDataRoot)
    # Служебный Claude, запущенный изнутри другого сеанса (хук плагина делает сводку через «claude -p» и т. п.), —
    # не ваш сеанс: иначе в шторке дубль проекта, а его «вопрос» зажигает свечение.
    if ($Call.PSObject.Properties['Nested'] -and $Call.Nested) {
        $sid = ''
        try { $sid = [string](ConvertFrom-Json -InputObject ([string]$Call.Body) -ErrorAction Stop).session_id } catch { }
        Add-NotifierHelperSession -SessionId $sid -DataRoot $DataRoot
        return $null
    }
    $config = Get-NotifierConfig -DataRoot $DataRoot
    $event = ConvertTo-NotifierEvent -HookKind ([string]$Call.Kind) -Json ([string]$Call.Body) -EntryPoint ([string]$Call.Entry) -HostSessionId ([string]$Call.HostSession) -Config $config -DataRoot $DataRoot
    if ($null -eq $event) { return $null }
    if ($config.events.ContainsKey($event.type) -and -not $config.events[$event.type].enabled) { return $null }
    # Окно сеанса — как в мосте: у CLI окно консоли (Windows Terminal), иначе первый предок с окном.
    $hwnd = [int64]0
    if ($event.origin -eq 'cli') { $hwnd = [int64]$Call.ConsoleHwnd }
    if ($hwnd -eq 0) { $hwnd = [int64]$Call.WalkHwnd }
    $event.window = [pscustomobject]@{ hwnd = $hwnd; pid = [int]$Call.ClaudePid }
    Add-NotifierEventDetails -Event $event -Kind ([string]$Call.Kind) -InputJson ([string]$Call.Body) -Config $config -DataRoot $DataRoot
    # Тот же вид, что у события из канала (JSON → объект): вложенные таблицы становятся объектами.
    return (ConvertFrom-Json -InputObject ($event | ConvertTo-Json -Depth 8 -Compress))
}

function Invoke-NotifierHookCalls {
    <# .SYNOPSIS Из таймера трея: хуки, принятые напрямую, — в общую очередь событий. Возвращает их число. #>
    param([int]$Max = 20)
    if (-not ('ClaudeNotifier.Ui.HookServer' -as [type])) { return 0 }
    $n = 0
    $call = $null
    while ($n -lt $Max -and [ClaudeNotifier.Ui.HookServer]::Calls.TryDequeue([ref]$call)) {
        $n++
        try {
            $event = ConvertFrom-NotifierHookCall -Call $call
            if ($event) { $script:TrayQueue.Enqueue($event) }
        }
        catch { Write-NotifierLog -Level ERROR -Message "tray: хук '$($call.Kind)': $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    }
    return $n
}

function Start-NotifierHookServer {
    <# .SYNOPSIS Приём хуков от curl на 127.0.0.1:<порт>. Ошибка (порт занят) — в журнал; мост SessionStart работает и так. #>
    param([string]$DataRoot = $script:TrayDataRoot)
    try {
        [ClaudeNotifier.Ui.HookServer]::Secret = Get-NotifierHookSecret -DataRoot $DataRoot   # '' — старая установка без секрета
        if ([ClaudeNotifier.Ui.HookServer]::Start((Get-NotifierHookPort))) { return $true }
        Write-NotifierLog -Level ERROR -Message "tray: приём хуков на порту $(Get-NotifierHookPort) не запущен: $([ClaudeNotifier.Ui.HookServer]::Error)" -DataRoot $DataRoot
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: приём хуков: $($_.Exception.Message)" -DataRoot $DataRoot }
    return $false
}

function Clear-NotifierStaleFiles {
    <#
    .SYNOPSIS
    Уборка при запуске трея, чтобы папка данных не росла бесконечно:
    состояние журналов (stats\, activity\), не обновлявшееся 30 дней (в activity хранится 21 день, так что
    в таком файле уже нет нужных дней); временные *.tmp-* и сборки cache\build.*.dll, оставшиеся от сбоев.
    Возвращает число удалённых файлов.
    #>
    param([string]$DataRoot = (Get-NotifierDataRoot), [datetime]$Now = [DateTime]::Now)
    $removed = 0
    $targets = @(
        @{ Dir = 'stats'; Filter = '*.json'; Days = 30 },
        @{ Dir = 'activity'; Filter = '*.json'; Days = 30 },
        @{ Dir = ''; Filter = '*.tmp-*'; Days = 1 },
        @{ Dir = 'stats'; Filter = '*.tmp-*'; Days = 1 },
        @{ Dir = 'activity'; Filter = '*.tmp-*'; Days = 1 },
        @{ Dir = 'cache'; Filter = 'build.*.dll'; Days = 1 }
    )
    foreach ($t in $targets) {
        $dir = if ($t.Dir) { Join-Path $DataRoot $t.Dir } else { $DataRoot }
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        $cut = $Now.AddDays(-$t.Days)
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter $t.Filter -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt $cut })) {
            try { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed++ } catch { }
        }
    }
    if ($removed -gt 0) { Write-NotifierLog -Level INFO -Message "tray: удалено устаревших файлов: $removed" -DataRoot $DataRoot }
    return $removed
}

function Start-NotifierTray {
    <#
    .SYNOPSIS
    Главный цикл трея. Возвращает код выхода: 0 — нормальное завершение или уже запущен.
    #>
    param([string]$MutexName, [switch]$NoOutput, [string]$DataRoot = (Get-NotifierDataRoot), [switch]$Show)
    $mutex = Enter-NotifierMutex -Name $MutexName
    if ($null -eq $mutex) {
        if ($Show) { [void](Request-NotifierShowWindow -DataRoot $DataRoot) }
        return 0
    }

    Add-Type -AssemblyName System.Windows.Forms
    try {
        if ((Import-NotifierUi) -eq 'inline') {
            Write-NotifierLog -Level WARN -Message "tray: кэш сборки интерфейса не сработал, загрузка без кэша: $(Get-NotifierUiImportError)" -DataRoot $DataRoot
        }
        [ClaudeNotifier.Ui.Native]::EnableDpiAwareness()
        [void][ClaudeNotifier.Ui.Native]::SetAppId((Get-NotifierAppId))   # иконка и имя приложения на панели задач
    }
    catch { Write-NotifierLog -Level WARN -Message "tray: интерфейс не загружен: $($_.Exception.Message)" -DataRoot $DataRoot }
    try { Import-TrayNative } catch { Write-NotifierLog -Level WARN -Message "tray: нативный помощник не загружен: $($_.Exception.Message)" -DataRoot $DataRoot }   # компиляция при старте, а не на первом событии
    $script:TrayState = @{ Mutex = $mutex; Stopped = $false; Timer = $null; Server = $null; Icon = $null; Context = $null }
    $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:TrayDataRoot = $DataRoot
    $script:TrayNoOutput = [bool]$NoOutput
    try { [void](Clear-NotifierStaleFiles -DataRoot $DataRoot) } catch { Write-NotifierLog -Level WARN -Message "tray: уборка: $($_.Exception.Message)" -DataRoot $DataRoot }
    try {
        $script:TrayState.Server = Start-NotifierPipeServer -Queue $script:TrayQueue -DataRoot $DataRoot
        [void](Start-NotifierHookServer -DataRoot $DataRoot)
        try { Initialize-NotifierNet -DataRoot $DataRoot }
        catch { Write-NotifierLog -Level ERROR -Message "tray: доступ из сети не запущен: $($_.Exception.Message)" -DataRoot $DataRoot }
        $script:TrayState.Context = New-Object System.Windows.Forms.ApplicationContext
        $script:TrayState.Icon = New-NotifierTrayIcon -DataRoot $DataRoot -OnExit {
            Stop-NotifierTray -State $script:TrayState
            $script:TrayState.Context.ExitThread()
        }
        try { [void](Register-NotifierHotKey -DataRoot $DataRoot) }
        catch { Write-NotifierLog -Level WARN -Message "tray: горячая клавиша: $($_.Exception.Message)" -DataRoot $DataRoot }
        try { Initialize-NotifierNotch -DataRoot $DataRoot }
        catch { Write-NotifierLog -Level WARN -Message "tray: шторка: $($_.Exception.Message)" -DataRoot $DataRoot }
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $script:TickMs
        $script:LastActivity = [datetime]::UtcNow   # старт считается активностью: первая обрезка через 30 с
        $script:LastTrim = [datetime]::MinValue
        $timer.add_Tick({
            try {
                $now = [datetime]::UtcNow
                try { if ((Invoke-NotifierHttpBatch) -gt 0) { $script:LastActivity = $now } }
                catch { Write-NotifierLog -Level ERROR -Message "tray: ошибка сети: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                try { if ((Invoke-NotifierHookCalls) -gt 0) { $script:LastActivity = $now } }
                catch { Write-NotifierLog -Level ERROR -Message "tray: хуки: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                if ((Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput:$script:TrayNoOutput) -gt 0) {
                    $script:LastActivity = $now
                }
                try { Invoke-NotifierUsageTick -Now $now } catch { Write-NotifierLog -Level WARN -Message "tray: расход: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                try { Update-NotifierLiveContext -Now $now } catch { Write-NotifierLog -Level WARN -Message "tray: контекст: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                try { Update-NotifierTrayBlink -Now $now } catch { }
                try { Invoke-NotifierNotchCommands } catch { Write-NotifierLog -Level WARN -Message "tray: шторка: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                try { Invoke-NotifierToastButtons } catch { Write-NotifierLog -Level WARN -Message "tray: кнопка уведомления: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                try { Invoke-NotifierActivityTick -Now $now } catch { Write-NotifierLog -Level WARN -Message "tray: статистика: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                # Раз в 5 с и сразу после событий: точка в трее и открытое окно.
                if (Test-SessionsRefreshDue -Dirty $script:SessionsDirty -LastRefresh $script:SessionsRefreshedAt -Now $now) {
                    [void](Invoke-NotifierSessionsRefresh)
                }
                elseif (Test-IdleTrimDue -LastActivity $script:LastActivity -LastTrim $script:LastTrim -Now $now) {
                    [void](Invoke-WorkingSetTrim)
                    $script:LastTrim = $now
                }
                $want = Get-NotifierTickInterval -LastActivity $script:LastActivity -Now $now
                if ($script:TrayState.Timer.Interval -ne $want) { $script:TrayState.Timer.Interval = $want }
            }
            catch { Write-NotifierLog -Level ERROR -Message "tray: ошибка таймера: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
        })
        $timer.Start()
        $script:TrayState.Timer = $timer
        if ($Show) { $script:TrayQueue.Enqueue((New-NotifierShowEvent)) }
        Write-NotifierLog -Level INFO -Message "tray: запущен (pid $PID)" -DataRoot $DataRoot
        [System.Windows.Forms.Application]::Run($script:TrayState.Context)
        return 0
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "tray: аварийное завершение: $($_.Exception.Message)" -DataRoot $DataRoot
        return 1
    }
    finally {
        if (-not $script:TrayState.Stopped) { Stop-NotifierTray -State $script:TrayState }
        Write-NotifierLog -Level INFO -Message 'tray: остановлен' -DataRoot $DataRoot
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    exit (Start-NotifierTray -MutexName $MutexName -NoOutput:$NoOutput -Show:$Show)
}
