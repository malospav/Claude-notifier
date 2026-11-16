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
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Ui.ps1')        # окно «Сеансы», точка в трее, диалоги
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Network.ps1')   # доступ из сети, вкладка «Устройства»

$script:EventTypes = @('done', 'permission', 'error', 'limit', 'start', 'working', 'end', 'show')
# Служебные события (SessionStart, UserPromptSubmit, SessionEnd): только для окна «Сеансы».
$script:SilentTypes = @('start', 'working', 'end')
$script:SessionsRefreshMs = 5000
$script:SessionsForm = $null
$script:SessionsDirty = $false
$script:SessionsRefreshedAt = [datetime]::MinValue
$script:MaxBatch = 20
$script:TickMs = 100
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
    }
}
'@
    }
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
    for ($i = 0; $i -lt $MaxBatch; $i++) {
        $event = $null
        if (-not $Queue.TryDequeue([ref]$event)) { break }
        try {
            if (-not (Test-NotifierEventShape $event)) {
                Write-NotifierLog -Level WARN -Message 'tray: отброшено событие неверного формата' -DataRoot $DataRoot
                continue
            }
            if ($event.type -eq 'show') { Show-NotifierSessionsWindow; $shown++; continue }   # щелчок по ярлыку
            $remote = Test-NotifierRemoteEventMuted -Event $event   # show | quiet | drop (события других устройств)
            if ($remote -eq 'drop') { continue }
            # Статус сеанса обновляется для любого события, даже если уведомление этого типа выключено.
            try {
                if ($null -eq $sessions) { $sessions = @(Get-NotifierSessions -DataRoot $DataRoot) }
                $sessions = Update-NotifierSessionList -Sessions $sessions -Event $event
            }
            catch { Write-NotifierLog -Level ERROR -Message "tray: статус сеанса не обновлён: $($_.Exception.Message)" -DataRoot $DataRoot }
            if ($script:SilentTypes -contains $event.type -or $remote -eq 'quiet') { $shown++; continue }
            if (-not $config.events[$event.type].enabled) { continue }
            # В историю — до показа: клик по toast сразу ищет событие в history.json.
            try { [void](Add-NotifierHistory -Event $event -DataRoot $DataRoot) }
            catch { Write-NotifierLog -Level ERROR -Message "tray: история не записана: $($_.Exception.Message)" -DataRoot $DataRoot }
            if (-not $NoOutput) {
                [void](Show-NotifierToast -Event $event -DataRoot $DataRoot)
                [void](Invoke-NotifierSound -Type $event.type -Config $config -DataRoot $DataRoot)
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

function Stop-NotifierTray {
    <#
    .SYNOPSIS
    Пункт «Выход»: останавливает таймер и сервер pipe, убирает иконку, освобождает мьютекс.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)
    if ($State.Timer) { $State.Timer.Stop(); $State.Timer.Dispose() }
    if ($State.Server) { [void](Stop-NotifierPipeServer -Server $State.Server) }
    try { Stop-NotifierNetServer } catch { }
    if ($script:ConnectForm -and -not $script:ConnectForm.IsDisposed) { $script:ConnectForm.Dispose() }
    if ($script:SessionsForm -and -not $script:SessionsForm.IsDisposed) { $script:SessionsForm.Dispose() }
    if ($State.Icon) { $State.Icon.Visible = $false; $State.Icon.Dispose() }
    if ($State.Mutex) { $State.Mutex.ReleaseMutex(); $State.Mutex.Dispose() }
    $State.Stopped = $true
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
    $icon.add_DoubleClick({ Show-NotifierSessionsWindow -Tab 0 })
    $menu = New-NotifierMenu -Theme $theme -Items @(
        @('Сеансы', { Show-NotifierSessionsWindow -Tab 0 }),
        @('Устройства', { Show-NotifierSessionsWindow -Tab 1 }),
        @('История', $null),
        '-',
        @('Выход', $OnExit)
    )
    $menu.Items[0].Font = [ClaudeNotifier.Ui.Fonts]::Semibold(9.5)
    $history = $menu.Items[2]
    $history.Tag = $DataRoot   # обработчику нужен каталог данных: $this.Tag вместо замыкания
    [void]$history.DropDownItems.Add('(пусто)')   # чтобы у пункта была стрелка подменю
    $history.DropDown.Renderer = $menu.Renderer
    $history.DropDown.Font = $menu.Font
    $history.add_DropDownOpening({ Update-NotifierHistoryMenu -MenuItem $this -DataRoot $this.Tag })
    $icon.ContextMenuStrip = $menu
    $icon.Visible = $true
    return $icon
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
        [void](Import-NotifierUi)
        [ClaudeNotifier.Ui.Native]::EnableDpiAwareness()
        [void][ClaudeNotifier.Ui.Native]::SetAppId((Get-NotifierAppId))   # иконка и имя приложения на панели задач
    }
    catch { Write-NotifierLog -Level WARN -Message "tray: интерфейс не загружен: $($_.Exception.Message)" -DataRoot $DataRoot }
    try { Import-TrayNative } catch { Write-NotifierLog -Level WARN -Message "tray: нативный помощник не загружен: $($_.Exception.Message)" -DataRoot $DataRoot }   # компиляция при старте, а не на первом событии
    $script:TrayState = @{ Mutex = $mutex; Stopped = $false; Timer = $null; Server = $null; Icon = $null; Context = $null }
    $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:TrayDataRoot = $DataRoot
    $script:TrayNoOutput = [bool]$NoOutput
    try {
        $script:TrayState.Server = Start-NotifierPipeServer -Queue $script:TrayQueue -DataRoot $DataRoot
        try { Initialize-NotifierNet -DataRoot $DataRoot }
        catch { Write-NotifierLog -Level ERROR -Message "tray: доступ из сети не запущен: $($_.Exception.Message)" -DataRoot $DataRoot }
        $script:TrayState.Context = New-Object System.Windows.Forms.ApplicationContext
        $script:TrayState.Icon = New-NotifierTrayIcon -DataRoot $DataRoot -OnExit {
            Stop-NotifierTray -State $script:TrayState
            $script:TrayState.Context.ExitThread()
        }
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $script:TickMs
        $script:LastActivity = [datetime]::UtcNow   # старт считается активностью: первая обрезка через 30 с
        $script:LastTrim = [datetime]::MinValue
        $timer.add_Tick({
            try {
                $now = [datetime]::UtcNow
                try { if ((Invoke-NotifierHttpBatch) -gt 0) { $script:LastActivity = $now } }
                catch { Write-NotifierLog -Level ERROR -Message "tray: ошибка сети: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
                if ((Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput:$script:TrayNoOutput) -gt 0) {
                    $script:LastActivity = $now
                }
                # Раз в 5 с и сразу после событий: точка в трее и открытое окно.
                if (Test-SessionsRefreshDue -Dirty $script:SessionsDirty -LastRefresh $script:SessionsRefreshedAt -Now $now) {
                    [void](Invoke-NotifierSessionsRefresh)
                }
                elseif (Test-IdleTrimDue -LastActivity $script:LastActivity -LastTrim $script:LastTrim -Now $now) {
                    [void](Invoke-WorkingSetTrim)
                    $script:LastTrim = $now
                }
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
