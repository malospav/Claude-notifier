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
Import-Module (Join-Path $PSScriptRoot 'lib\Window.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Sessions.psm1')
. (Join-Path $PSScriptRoot 'ClaudeNotifier.Network.ps1')   # доступ из сети, вкладка «Устройства»

$script:EventTypes = @('done', 'permission', 'error', 'limit', 'start', 'working', 'end')
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

# --- Окно «Сеансы Claude» ---

$script:StateColors = @{
    working    = @(0, 102, 204)
    waiting    = @(16, 124, 16)
    permission = @(202, 80, 16)
    error      = @(196, 43, 28)
}

function Update-NotifierSessionsView {
    <#
    .SYNOPSIS
    Заполняет таблицу сеансов: проект, устройство, статус (цветом), сколько в этом статусе, где запущен, последний ответ.
    Выделенная строка сохраняется. Возвращает текст строки состояния.
    #>
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.ListView]$ListView,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [datetime]$Now = [DateTime]::UtcNow
    )
    $selected = $null
    if ($ListView.SelectedItems.Count -gt 0) { $selected = [string]$ListView.SelectedItems[0].Tag.session_id }
    $ListView.BeginUpdate()
    try {
        $ListView.Items.Clear()
        foreach ($s in (Get-NotifierSortedSessions -Sessions $Sessions)) {
            $project = [string]$s.project
            if ($project -eq '') { $project = '(без проекта)' }
            $item = New-Object System.Windows.Forms.ListViewItem $project
            $item.UseItemStyleForSubItems = $false
            $deviceId = ''
            if ($s.PSObject.Properties['device']) { $deviceId = [string]$s.device }
            [void]$item.SubItems.Add((Get-NotifierDeviceName $deviceId))
            $state = [string]$s.state
            $sub = $item.SubItems.Add((Get-NotifierSessionStateText $state))
            if ($script:StateColors.ContainsKey($state)) {
                $c = $script:StateColors[$state]
                $sub.ForeColor = [System.Drawing.Color]::FromArgb($c[0], $c[1], $c[2])
            }
            [void]$item.SubItems.Add((Format-NotifierElapsed -Ts ([string]$s.since) -Now $Now))
            $where = 'Терминал'
            if ([string]$s.origin -eq 'desktop') { $where = 'Приложение' }
            [void]$item.SubItems.Add($where)
            [void]$item.SubItems.Add([string]$s.preview)
            $item.Tag = $s
            [void]$ListView.Items.Add($item)
            if ($selected -and [string]$s.session_id -eq $selected) { $item.Selected = $true }
        }
    }
    finally { $ListView.EndUpdate() }
    $count = $ListView.Items.Count
    if ($count -eq 0) { return 'Активных сеансов нет' }
    $need = @($Sessions | Where-Object { $_.state -eq 'permission' -or $_.state -eq 'error' }).Count
    $text = "Активных сеансов: $count"
    if ($need -gt 0) { $text += " $([char]0x00B7) требуют внимания: $need" }
    return $text
}

function Invoke-NotifierSessionsRefresh {
    <#
    .SYNOPSIS
    Перечитывает sessions.json, убирает завершившиеся сеансы (и сохраняет, если что-то убрано),
    обновляет открытое окно. Возвращает список живых сеансов.
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $all = @(Get-NotifierSessions -DataRoot $DataRoot)
    $live = Select-NotifierLiveSessions -Sessions $all   # уже массив; @() вложил бы его в ещё один
    if ($live.Count -ne $all.Count) { Save-NotifierSessions -Sessions $live -DataRoot $DataRoot }
    $script:SessionsDirty = $false
    $script:SessionsRefreshedAt = [datetime]::UtcNow
    $form = $script:SessionsForm
    if ($form -and -not $form.IsDisposed) {
        $form.Tag.Status.Text = Update-NotifierSessionsView -ListView $form.Tag.List -Sessions $live
        if ($form.Tag.Net) { Update-NotifierDevicesView -Ui $form.Tag.Net -Sessions $live }
    }
    return , $live
}

function Remove-NotifierSession {
    <# .SYNOPSIS Убирает сеанс из sessions.json по session_id. #>
    param([Parameter(Mandatory = $true)][string]$SessionId, [string]$DataRoot = $script:TrayDataRoot)
    $rest = @(Get-NotifierSessions -DataRoot $DataRoot | Where-Object { [string]$_.session_id -ne $SessionId })
    Save-NotifierSessions -Sessions $rest -DataRoot $DataRoot
    $script:SessionsDirty = $true
}

function Invoke-NotifierSessionFocus {
    <#
    .SYNOPSIS
    Выводит на передний план окно сеанса. Если окно закрыто — сеанс убирается из списка.

    .OUTPUTS
    'focused' | 'flashed' | 'closed' | 'unknown' (окно сеанса не определено).
    #>
    param([Parameter(Mandatory = $true)]$Session, [string]$DataRoot = $script:TrayDataRoot)
    $hwnd = [int64]0
    $win = $Session.PSObject.Properties['window']
    if ($win -and $win.Value -and $win.Value.PSObject.Properties['hwnd']) { $hwnd = [int64]$win.Value.hwnd }
    if ($hwnd -eq 0) { return 'unknown' }
    $result = Set-SessionWindowFocus -Hwnd $hwnd
    if ($result -eq 'closed') { Remove-NotifierSession -SessionId ([string]$Session.session_id) -DataRoot $DataRoot }
    return $result
}

function Invoke-NotifierSelectedSession {
    # Действие над выделенной строкой окна: focus | remove.
    param([Parameter(Mandatory = $true)][ValidateSet('focus', 'remove')][string]$Action)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed -or $form.Tag.List.SelectedItems.Count -eq 0) { return }
    $session = $form.Tag.List.SelectedItems[0].Tag
    if ($Action -eq 'remove') { Remove-NotifierSession -SessionId ([string]$session.session_id) }
    elseif ($session.PSObject.Properties['device'] -and [string]$session.device -ne '') {
        $form.Tag.Status.Text = "Этот сеанс идёт на устройстве «$(Get-NotifierDeviceName ([string]$session.device))»"
        return
    }
    elseif ((Invoke-NotifierSessionFocus -Session $session) -eq 'unknown') {
        $form.Tag.Status.Text = 'Окно этого сеанса не определено'
        return
    }
    [void](Invoke-NotifierSessionsRefresh)
}

function New-NotifierSessionsForm {
    <# .SYNOPSIS Окно «Сеансы Claude» (создаётся при открытии, уничтожается при закрытии). #>
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'Сеансы Claude'
    $form.Font = New-Object System.Drawing.Font('Segoe UI', 9)
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.ClientSize = New-Object System.Drawing.Size(940, 360)
    $form.MinimumSize = New-Object System.Drawing.Size(520, 200)
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $iconPath = Join-Path $PSScriptRoot 'assets\icon.ico'
    if (Test-Path -LiteralPath $iconPath) { $form.Icon = New-Object System.Drawing.Icon $iconPath }

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
    foreach ($col in @(@('Проект', 140), @('Устройство', 120), @('Статус', 135), @('Сколько', 85), @('Где', 85), @('Последний ответ', 320))) {
        [void]$list.Columns.Add($col[0], $col[1])
    }
    $list.add_DoubleClick({ Invoke-NotifierSelectedSession -Action focus })
    $list.add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Invoke-NotifierSelectedSession -Action focus; $e.Handled = $true }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) { Invoke-NotifierSelectedSession -Action remove; $e.Handled = $true }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) { [void](Invoke-NotifierSessionsRefresh); $e.Handled = $true }
        })
    $list.add_Resize({
            # Последняя колонка занимает оставшуюся ширину.
            $rest = $this.ClientSize.Width
            for ($i = 0; $i -lt $this.Columns.Count - 1; $i++) { $rest -= $this.Columns[$i].Width }
            if ($rest -gt 120) { $this.Columns[$this.Columns.Count - 1].Width = $rest }
        })

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $go = New-Object System.Windows.Forms.ToolStripMenuItem 'Перейти к окну'
    $go.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
    $go.add_Click({ Invoke-NotifierSelectedSession -Action focus })
    [void]$menu.Items.Add($go)
    $rm = New-Object System.Windows.Forms.ToolStripMenuItem 'Убрать из списка'
    $rm.add_Click({ Invoke-NotifierSelectedSession -Action remove })
    [void]$menu.Items.Add($rm)
    $menu.add_Opening({
            param($sender, $e)
            if ($null -eq $script:SessionsForm -or $script:SessionsForm.Tag.List.SelectedItems.Count -eq 0) { $e.Cancel = $true }
        })
    $list.ContextMenuStrip = $menu

    $strip = New-Object System.Windows.Forms.StatusStrip
    $status = New-Object System.Windows.Forms.ToolStripStatusLabel ''
    $status.Spring = $true
    $status.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    [void]$strip.Items.Add($status)
    $hint = New-Object System.Windows.Forms.ToolStripStatusLabel 'Двойной клик — перейти к окну · Del — убрать'
    $hint.ForeColor = [System.Drawing.SystemColors]::GrayText
    [void]$strip.Items.Add($hint)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Fill
    $sessionsPage = New-Object System.Windows.Forms.TabPage 'Сеансы'
    $sessionsPage.Controls.Add($list)
    [void]$tabs.TabPages.Add($sessionsPage)
    $netUi = $null
    if ($script:Net) {
        $netUi = New-NotifierDevicesTab
        [void]$tabs.TabPages.Add($netUi.Page)
    }

    $form.Controls.Add($tabs)
    $form.Controls.Add($strip)
    $form.Tag = @{ List = $list; Status = $status; Tabs = $tabs; Net = $netUi }
    $form.add_FormClosed({ $script:SessionsForm = $null })
    return $form
}

function Show-NotifierSessionsWindow {
    <# .SYNOPSIS Открывает окно «Сеансы Claude» или выводит уже открытое на передний план. #>
    try {
        if ($null -eq $script:SessionsForm -or $script:SessionsForm.IsDisposed) {
            $script:SessionsForm = New-NotifierSessionsForm
            [void](Invoke-NotifierSessionsRefresh)
            $script:SessionsForm.Show()
        }
        else {
            [void](Invoke-NotifierSessionsRefresh)
            if ($script:SessionsForm.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
                $script:SessionsForm.WindowState = [System.Windows.Forms.FormWindowState]::Normal
            }
        }
        $script:SessionsForm.Activate()
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: окно сеансов: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

function Test-SessionsRefreshDue {
    <# .SYNOPSIS Пора ли обновить открытое окно: пришли события или прошло RefreshMs. #>
    param([bool]$Dirty, [datetime]$LastRefresh, [datetime]$Now, [int]$RefreshMs = $script:SessionsRefreshMs)
    return $Dirty -or (($Now - $LastRefresh).TotalMilliseconds -ge $RefreshMs)
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
    <# .SYNOPSIS NotifyIcon «Claude Notifier»: меню «Сеансы» / «История ▸» / «Выход»; двойной клик — окно сеансов. #>
    param([Parameter(Mandatory = $true)][scriptblock]$OnExit, [string]$DataRoot = (Get-NotifierDataRoot))
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $icon = New-Object System.Windows.Forms.NotifyIcon
    $iconPath = Join-Path $PSScriptRoot 'assets\icon.ico'
    if (Test-Path -LiteralPath $iconPath) { $icon.Icon = New-Object System.Drawing.Icon $iconPath, 32, 32 }
    else { $icon.Icon = [System.Drawing.SystemIcons]::Information }
    $icon.Text = 'Claude Notifier'
    $icon.add_DoubleClick({ Show-NotifierSessionsWindow })
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $sessions = New-Object System.Windows.Forms.ToolStripMenuItem 'Сеансы'
    $sessions.Font = New-Object System.Drawing.Font($menu.Font, [System.Drawing.FontStyle]::Bold)
    $sessions.add_Click({ Show-NotifierSessionsWindow })
    [void]$menu.Items.Add($sessions)
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
                $form = $script:SessionsForm
                if ($form -and -not $form.IsDisposed -and $form.Visible -and (Test-SessionsRefreshDue -Dirty $script:SessionsDirty -LastRefresh $script:SessionsRefreshedAt -Now $now)) {
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
