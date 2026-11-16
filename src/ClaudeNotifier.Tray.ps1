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
    [string]$MutexName = 'Local\claude-notifier'
)

Import-Module (Join-Path $PSScriptRoot 'lib\Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Ipc.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Toast.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Sound.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\History.psm1')

$script:EventTypes = @('done', 'permission', 'error', 'limit')
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
    for ($i = 0; $i -lt $MaxBatch; $i++) {
        $event = $null
        if (-not $Queue.TryDequeue([ref]$event)) { break }
        try {
            if (-not (Test-NotifierEventShape $event)) {
                Write-NotifierLog -Level WARN -Message 'tray: отброшено событие неверного формата' -DataRoot $DataRoot
                continue
            }
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
    return $shown
}

function Stop-NotifierTray {
    <#
    .SYNOPSIS
    Пункт «Выход»: останавливает таймер и сервер pipe, убирает иконку, освобождает мьютекс.
    #>
    param([Parameter(Mandatory = $true)][hashtable]$State)
    if ($State.Timer) { $State.Timer.Stop(); $State.Timer.Dispose() }
    if ($State.Server) { [void](Stop-NotifierPipeServer -Server $State.Server) }
    if ($State.Icon) { $State.Icon.Visible = $false; $State.Icon.Dispose() }
    if ($State.Mutex) { $State.Mutex.ReleaseMutex(); $State.Mutex.Dispose() }
    $State.Stopped = $true
}

function New-NotifierTrayIcon {
    <# .SYNOPSIS NotifyIcon с подсказкой «Claude Notifier» и меню «История ▸» / «Выход». #>
    param([Parameter(Mandatory = $true)][scriptblock]$OnExit, [string]$DataRoot = (Get-NotifierDataRoot))
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $iconPath = Join-Path $PSScriptRoot 'assets\icon.ico'
    if (Test-Path -LiteralPath $iconPath) { $icon.Icon = New-Object System.Drawing.Icon $iconPath, 32, 32 }
    else { $icon.Icon = [System.Drawing.SystemIcons]::Information }
    $icon.Text = 'Claude Notifier'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $history = New-Object System.Windows.Forms.ToolStripMenuItem 'История'
    $history.Tag = $DataRoot   # обработчику нужен каталог данных: $this.Tag вместо замыкания
    [void]$history.DropDownItems.Add('(пусто)')   # чтобы у пункта была стрелка подменю
    $history.add_DropDownOpening({ Update-NotifierHistoryMenu -MenuItem $this -DataRoot $this.Tag })
    [void]$menu.Items.Add($history)
    [void]$menu.Items.Add('Выход', $null, $OnExit)
    $icon.ContextMenuStrip = $menu
    $icon.Visible = $true
    return $icon
}

function Start-NotifierTray {
    <#
    .SYNOPSIS
    Главный цикл трея. Возвращает код выхода: 0 — нормальное завершение или уже запущен.
    #>
    param([string]$MutexName, [switch]$NoOutput, [string]$DataRoot = (Get-NotifierDataRoot))
    $mutex = Enter-NotifierMutex -Name $MutexName
    if ($null -eq $mutex) { return 0 }

    Add-Type -AssemblyName System.Windows.Forms
    try { Import-TrayNative } catch { Write-NotifierLog -Level WARN -Message "tray: нативный помощник не загружен: $($_.Exception.Message)" -DataRoot $DataRoot }   # компиляция при старте, а не на первом событии
    $script:TrayState = @{ Mutex = $mutex; Stopped = $false; Timer = $null; Server = $null; Icon = $null; Context = $null }
    $script:TrayQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $script:TrayDataRoot = $DataRoot
    $script:TrayNoOutput = [bool]$NoOutput
    try {
        $script:TrayState.Server = Start-NotifierPipeServer -Queue $script:TrayQueue -DataRoot $DataRoot
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
                if ((Invoke-NotifierEventBatch -Queue $script:TrayQueue -DataRoot $script:TrayDataRoot -NoOutput:$script:TrayNoOutput) -gt 0) {
                    $script:LastActivity = $now
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
    exit (Start-NotifierTray -MutexName $MutexName -NoOutput:$NoOutput)
}
