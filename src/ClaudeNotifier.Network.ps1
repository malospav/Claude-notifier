<#
.SYNOPSIS
Доступ из локальной сети для трея claude-notifier: HTTP-сервер, вкладка «Устройства», окно «Подключить устройство».

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source и работает в его области видимости ($script:…).
Состояние — $script:Net: настройки и устройства (network.json), текущий PIN, одноразовые коды установки,
сервер, события от устройств. Всё выполняется в UI-потоке трея.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Devices.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Server.psm1')

$script:Net = $null
$script:NetSaveMs = 2000
$script:ConnectForm = $null

function Initialize-NotifierNet {
    <# .SYNOPSIS Создаёт $script:Net из network.json и, если доступ включён, запускает сервер. #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $script:Net = @{
        Network      = Get-NotifierNetwork -DataRoot $DataRoot
        Pairing      = $null
        InstallCodes = @{}
        Server       = $null
        Queue        = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        Events       = New-Object System.Collections.ArrayList
        NetworkDirty = $false
        LastSave     = [datetime]::MinValue
        Paired       = $null
        Error        = ''
        DataRoot     = $DataRoot
        Address      = Get-NotifierLanAddress
        PcName       = $env:COMPUTERNAME
    }
    if ($script:Net.Network.enabled) { [void](Start-NotifierNetServer) }
}

function Start-NotifierNetServer {
    <# .SYNOPSIS Запускает HTTP-сервер. Возвращает $true при успехе; текст ошибки — в $script:Net.Error. #>
    $net = $script:Net
    if ($net.Server) { return $true }
    $net.Address = Get-NotifierLanAddress
    try {
        $net.Server = Start-NotifierHttpServer -Prefix (Get-NotifierHttpPrefix -Port $net.Network.port) -Queue $net.Queue
        $net.Error = ''
        Write-NotifierLog -Level INFO -Message "network: сервер запущен на порту $($net.Network.port)" -DataRoot $net.DataRoot
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        if ($_.Exception.InnerException) { $msg = $_.Exception.InnerException.Message }
        $net.Error = $msg
        Write-NotifierLog -Level WARN -Message "network: сервер не запущен: $msg" -DataRoot $net.DataRoot
        return $false
    }
}

function Stop-NotifierNetServer {
    $net = $script:Net
    if ($null -eq $net) { return }
    if ($net.Server) { [void](Stop-NotifierHttpServer -Server $net.Server); $net.Server = $null }
    if ($net.NetworkDirty) { Save-NotifierNet -Force }
}

function Save-NotifierNet {
    <# .SYNOPSIS Сохраняет network.json, если есть изменения (не чаще раза в NetSaveMs, с -Force — сразу). #>
    param([switch]$Force)
    $net = $script:Net
    if (-not $net.NetworkDirty) { return }
    $now = [datetime]::UtcNow
    if (-not $Force -and ($now - $net.LastSave).TotalMilliseconds -lt $script:NetSaveMs) { return }
    try {
        Save-NotifierNetwork -Network $net.Network -DataRoot $net.DataRoot
        $net.NetworkDirty = $false
        $net.LastSave = $now
    }
    catch { Write-NotifierLog -Level ERROR -Message "network: network.json не записан: $($_.Exception.Message)" -DataRoot $net.DataRoot }
}

function Invoke-NotifierHttpBatch {
    <#
    .SYNOPSIS
    Отвечает на принятые HTTP-запросы (до MaxBatch за тик), передаёт события устройств в очередь трея.
    Возвращает число обработанных запросов.
    #>
    param([System.Collections.Concurrent.ConcurrentQueue[object]]$EventQueue = $script:TrayQueue, [int]$MaxBatch = 20)
    $net = $script:Net
    if ($null -eq $net -or $net.Queue.IsEmpty) { Save-NotifierNet; return 0 }
    $n = 0
    for ($i = 0; $i -lt $MaxBatch; $i++) {
        $ctx = $null
        if (-not $net.Queue.TryDequeue([ref]$ctx)) { break }
        $n++
        try {
            $req = ConvertFrom-NotifierHttpContext -Context $ctx
            $resp = Invoke-NotifierHttpRequest -Request $req -Ctx $net
        }
        catch {
            Write-NotifierLog -Level ERROR -Message "network: ошибка запроса: $($_.Exception.Message)" -DataRoot $net.DataRoot
            $resp = @{ Status = 500; Body = 'error'; ContentType = 'text/plain; charset=utf-8'; Headers = @() }
        }
        try { Write-NotifierHttpResponse -Context $ctx -Response $resp } catch { }
    }
    foreach ($ev in $net.Events) { $EventQueue.Enqueue($ev) }
    $net.Events.Clear()
    if ($net.Paired) {
        $paired = $net.Paired
        $net.Paired = $null
        Save-NotifierNet -Force
        Update-NotifierConnectStatus -Device $paired
        $script:SessionsDirty = $true
    }
    Save-NotifierNet
    return $n
}

function Test-NotifierRemoteEventMuted {
    <#
    .SYNOPSIS
    Для события с другого устройства: 'drop' — устройство отключено, 'quiet' — уведомления на ПК
    для него выключены (только статус сеанса), 'show' — показать как обычно. Для событий этого ПК — 'show'.
    #>
    param([Parameter(Mandatory = $true)]$Event)
    $p = $Event.PSObject.Properties['device']
    if ($null -eq $p -or [string]::IsNullOrEmpty([string]$p.Value)) { return 'show' }
    if ($null -eq $script:Net) { return 'drop' }
    $d = Find-NotifierDevice -Network $script:Net.Network -Id ([string]$p.Value)
    if ($null -eq $d) { return 'drop' }
    if ($d.notify) { return 'show' }
    return 'quiet'
}

function Get-NotifierDeviceName {
    <# .SYNOPSIS Имя устройства для таблицы сеансов: '' → «Этот ПК». #>
    param([AllowEmptyString()][string]$Id)
    if ([string]::IsNullOrEmpty($Id)) { return 'Этот ПК' }
    if ($script:Net) {
        $d = Find-NotifierDevice -Network $script:Net.Network -Id $Id
        if ($d) { return [string]$d.name }
    }
    return 'Отключено'
}

function Get-NotifierDeviceKindText {
    param([Parameter(Mandatory = $true)]$Device)
    if ($Device.hooks) { return 'Mac · сеансы видны здесь' }
    if ($Device.name -eq 'Mac') { return 'Браузер · хуки не установлены' }
    return 'Браузер · только просмотр'
}

function Update-NotifierDevicesView {
    <# .SYNOPSIS Заполняет вкладку «Устройства»: строка доступа из сети, кнопка, таблица устройств. #>
    param([Parameter(Mandatory = $true)][hashtable]$Ui, [object[]]$Sessions = @())
    $net = $script:Net
    if ($null -eq $net) { return }
    if ($net.Server) {
        $Ui.NetLabel.Text = "Доступ из сети включён: $(Get-NotifierServerBaseUrl $net)"
        $Ui.NetLabel.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
        $Ui.NetButton.Text = 'Выключить'
    }
    elseif ($net.Network.enabled -and $net.Error) {
        $Ui.NetLabel.Text = "Сервер не запустился: $($net.Error)"
        $Ui.NetLabel.ForeColor = [System.Drawing.Color]::FromArgb(196, 43, 28)
        $Ui.NetButton.Text = 'Повторить'
    }
    else {
        $Ui.NetLabel.Text = 'Доступ из сети выключен: другие устройства не видят этот ПК.'
        $Ui.NetLabel.ForeColor = [System.Drawing.SystemColors]::ControlText
        $Ui.NetButton.Text = 'Включить'
    }
    $counts = @{}
    foreach ($s in $Sessions) {
        $id = ''
        if ($s.PSObject.Properties['device']) { $id = [string]$s.device }
        $counts[$id] = 1 + [int]$counts[$id]
    }
    $list = $Ui.Devices
    $selected = $null
    if ($list.SelectedItems.Count -gt 0) { $selected = [string]$list.SelectedItems[0].Tag.id }
    $list.BeginUpdate()
    try {
        $list.Items.Clear()
        foreach ($d in $net.Network.devices) {
            $item = New-Object System.Windows.Forms.ListViewItem ([string]$d.name)
            [void]$item.SubItems.Add((Get-NotifierDeviceKindText $d))
            [void]$item.SubItems.Add((Format-NotifierLastSeen -Ts ([string]$d.last_seen)))
            [void]$item.SubItems.Add([string][int]$counts[[string]$d.id])
            $notify = 'нет'
            if ($d.notify) { $notify = 'да' }
            [void]$item.SubItems.Add($notify)
            $item.Tag = $d
            [void]$list.Items.Add($item)
            if ($selected -and [string]$d.id -eq $selected) { $item.Selected = $true }
        }
    }
    finally { $list.EndUpdate() }
    $Ui.Empty.Visible = ($list.Items.Count -eq 0)
}

function Enable-NotifierNetworkAccess {
    <#
    .SYNOPSIS
    Включает доступ из сети. При первом включении — разовая настройка Windows с запросом UAC.
    Возвращает $true, если сервер работает.
    #>
    param([System.Windows.Forms.IWin32Window]$Owner)
    $net = $script:Net
    if ($net.Server) { return $true }
    if (-not (Test-NotifierNetworkSetup -Port $net.Network.port)) {
        $answer = [System.Windows.Forms.MessageBox]::Show($Owner,
            "Чтобы телефон и Mac могли подключаться к этому ПК, Windows один раз спросит права администратора.`n`n" +
            "Будет разрешён вход на порт $($net.Network.port) только из вашей локальной сети. Отменить можно кнопкой «Выключить» и при удалении программы.",
            'Доступ из сети', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return $false }
        $result = Invoke-NotifierNetworkSetup -Port $net.Network.port -DataRoot $net.DataRoot
        if ($result -ne 'ok') {
            if ($result -eq 'failed') {
                [void][System.Windows.Forms.MessageBox]::Show($Owner, "Настройка Windows не удалась. Подробности: $(Join-Path $net.DataRoot 'setup-network.log')", 'Доступ из сети',
                    [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
            return $false
        }
    }
    $net.Network.enabled = $true
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
    $ok = Start-NotifierNetServer
    if (-not $ok) {
        [void][System.Windows.Forms.MessageBox]::Show($Owner, "Сервер не запустился: $($net.Error)", 'Доступ из сети',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    return $ok
}

function Disable-NotifierNetworkAccess {
    $net = $script:Net
    Stop-NotifierNetServer
    $net.Network.enabled = $false
    $net.Error = ''
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
}

function Remove-NotifierDeviceAndSessions {
    <# .SYNOPSIS Отключает устройство: удаляет его из network.json и его сеансы из sessions.json. #>
    param([Parameter(Mandatory = $true)][string]$Id)
    $net = $script:Net
    if (-not (Remove-NotifierDevice -Network $net.Network -Id $Id)) { return $false }
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
    $rest = @(Get-NotifierSessions -DataRoot $net.DataRoot | Where-Object { -not ($_.PSObject.Properties['device'] -and [string]$_.device -eq $Id) })
    Save-NotifierSessions -Sessions $rest -DataRoot $net.DataRoot
    $script:SessionsDirty = $true
    return $true
}

function Invoke-NotifierDeviceAction {
    <# .SYNOPSIS Кнопки вкладки «Устройства»: rename | notify | remove над выделенным устройством. #>
    param([Parameter(Mandatory = $true)][ValidateSet('rename', 'notify', 'remove')][string]$Action)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $list = $form.Tag.Net.Devices
    if ($list.SelectedItems.Count -eq 0) {
        [void][System.Windows.Forms.MessageBox]::Show($form, 'Выберите устройство в списке.', 'Устройства')
        return
    }
    $d = $list.SelectedItems[0].Tag
    switch ($Action) {
        'rename' {
            Add-Type -AssemblyName Microsoft.VisualBasic
            $name = [Microsoft.VisualBasic.Interaction]::InputBox('Новое имя устройства:', 'Переименовать', [string]$d.name)
            $name = ($name -replace '[\x00-\x1f]', '').Trim()
            if ($name -eq '') { return }
            if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
            $d.name = $name
        }
        'notify' { $d.notify = -not [bool]$d.notify }
        'remove' {
            $extra = ''
            if ($d.hooks) { $extra = "`n`nНа самом Mac хуки останутся, но события больше не принимаются. Удалить их: ~/.claude-notifier/uninstall.sh" }
            $answer = [System.Windows.Forms.MessageBox]::Show($form, "Отключить «$($d.name)»? Устройство потеряет доступ к этому ПК.$extra",
                'Отключить устройство', [System.Windows.Forms.MessageBoxButtons]::OKCancel, [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::OK) { return }
            [void](Remove-NotifierDeviceAndSessions -Id ([string]$d.id))
        }
    }
    $script:Net.NetworkDirty = $true
    Save-NotifierNet -Force
    [void](Invoke-NotifierSessionsRefresh)
}

function New-NotifierDevicesTab {
    <# .SYNOPSIS Вкладка «Устройства». Возвращает @{ Page; NetLabel; NetButton; Devices; Empty }. #>
    $page = New-Object System.Windows.Forms.TabPage 'Устройства'
    $page.Padding = New-Object System.Windows.Forms.Padding(8)

    $top = New-Object System.Windows.Forms.TableLayoutPanel
    $top.Dock = [System.Windows.Forms.DockStyle]::Top
    $top.AutoSize = $true
    $top.ColumnCount = 2
    [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$top.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $netLabel = New-Object System.Windows.Forms.Label
    $netLabel.AutoSize = $true
    $netLabel.Anchor = [System.Windows.Forms.AnchorStyles]::Left
    $netLabel.Margin = New-Object System.Windows.Forms.Padding(0, 6, 0, 8)
    $netButton = New-Object System.Windows.Forms.Button
    $netButton.AutoSize = $true
    $netButton.Text = 'Включить'
    $netButton.add_Click({
            $form = $script:SessionsForm
            if ($script:Net.Server) { Disable-NotifierNetworkAccess } else { [void](Enable-NotifierNetworkAccess -Owner $form) }
            [void](Invoke-NotifierSessionsRefresh)
        })
    $top.Controls.Add($netLabel, 0, 0)
    $top.Controls.Add($netButton, 1, 0)

    $list = New-Object System.Windows.Forms.ListView
    $list.View = [System.Windows.Forms.View]::Details
    $list.FullRowSelect = $true
    $list.MultiSelect = $false
    $list.HideSelection = $false
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.HeaderStyle = [System.Windows.Forms.ColumnHeaderStyle]::Nonclickable
    foreach ($col in @(@('Устройство', 170), @('Тип', 220), @('Связь', 110), @('Сеансов', 70), @('Уведомления на ПК', 140))) {
        [void]$list.Columns.Add($col[0], $col[1])
    }
    $list.add_DoubleClick({ Invoke-NotifierDeviceAction -Action rename })
    $list.add_KeyDown({
            param($sender, $e)
            if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Delete) { Invoke-NotifierDeviceAction -Action remove; $e.Handled = $true }
            elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::F2) { Invoke-NotifierDeviceAction -Action rename; $e.Handled = $true }
        })

    $empty = New-Object System.Windows.Forms.Label
    $empty.Text = "Подключённых устройств нет.`nНажмите «Подключить устройство», чтобы видеть здесь сеансы Mac и смотреть сеансы с телефона."
    $empty.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $empty.ForeColor = [System.Drawing.SystemColors]::GrayText
    $empty.BackColor = [System.Drawing.SystemColors]::Window
    $empty.Dock = [System.Windows.Forms.DockStyle]::Fill

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttons.AutoSize = $true
    $buttons.Padding = New-Object System.Windows.Forms.Padding(0, 8, 0, 0)
    $connect = New-Object System.Windows.Forms.Button
    $connect.Text = 'Подключить устройство…'
    $connect.AutoSize = $true
    $connect.Font = New-Object System.Drawing.Font($connect.Font, [System.Drawing.FontStyle]::Bold)
    $connect.add_Click({ Show-NotifierConnectDialog })
    [void]$buttons.Controls.Add($connect)
    foreach ($b in @(@('Переименовать', 'rename'), @('Уведомления на ПК вкл/выкл', 'notify'), @('Отключить', 'remove'))) {
        $btn = New-Object System.Windows.Forms.Button
        $btn.Text = $b[0]
        $btn.Tag = $b[1]
        $btn.AutoSize = $true
        $btn.add_Click({ Invoke-NotifierDeviceAction -Action $this.Tag })
        [void]$buttons.Controls.Add($btn)
    }

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.Controls.Add($list)
    $panel.Controls.Add($empty)
    $empty.BringToFront()

    $page.Controls.Add($panel)
    $page.Controls.Add($buttons)
    $page.Controls.Add($top)
    return @{ Page = $page; NetLabel = $netLabel; NetButton = $netButton; Devices = $list; Empty = $empty }
}

function Update-NotifierConnectStatus {
    <# .SYNOPSIS В открытом окне «Подключить устройство» показывает, что устройство подключилось. #>
    param($Device)
    $f = $script:ConnectForm
    if ($null -eq $f -or $f.IsDisposed -or $null -eq $Device) { return }
    $text = "✓ Подключено: $($Device.name)"
    if ($Device.hooks) { $text = "✓ $($Device.name): хуки установлены, сеансы этого Mac появятся во вкладке «Сеансы»" }
    $f.Tag.Status.Text = $text
    $f.Tag.Status.ForeColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
}

function New-NotifierPin {
    <# .SYNOPSIS Новый PIN для окна подключения; старый перестаёт действовать. #>
    $script:Net.Pairing = New-NotifierPairing
    $pin = $script:Net.Pairing.Pin
    return ($pin.Substring(0, 3) + ' ' + $pin.Substring(3))
}

function Show-NotifierConnectDialog {
    <#
    .SYNOPSIS
    Окно «Подключить устройство»: адрес ПК и одноразовый PIN. Если доступ из сети выключен — сначала включает его.
    #>
    $owner = $script:SessionsForm
    if ($script:ConnectForm -and -not $script:ConnectForm.IsDisposed) { $script:ConnectForm.Activate(); return }
    if (-not (Enable-NotifierNetworkAccess -Owner $owner)) { [void](Invoke-NotifierSessionsRefresh); return }
    [void](Invoke-NotifierSessionsRefresh)
    $net = $script:Net
    if ([string]::IsNullOrEmpty($net.Address)) {
        [void][System.Windows.Forms.MessageBox]::Show($owner, 'Этот ПК не подключён к локальной сети: адрес не найден.', 'Подключить устройство')
        return
    }
    $url = Get-NotifierServerBaseUrl $net

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'Подключить устройство'
    $f.Font = New-Object System.Drawing.Font('Segoe UI', 10)
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $f.AutoSize = $true
    $f.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $f.Padding = New-Object System.Windows.Forms.Padding(20, 16, 20, 16)
    if ($owner -and $owner.Icon) { $f.Icon = $owner.Icon }

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $flow.AutoSize = $true
    $flow.WrapContents = $false
    $flow.MaximumSize = New-Object System.Drawing.Size(460, 0)

    function Add-Text([string]$Text, [float]$Size = 10, [System.Drawing.FontStyle]$Style = 'Regular', [int]$Top = 0) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $Text
        $l.AutoSize = $true
        $l.MaximumSize = New-Object System.Drawing.Size(460, 0)
        $l.Font = New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
        $l.Margin = New-Object System.Windows.Forms.Padding(0, $Top, 0, 2)
        [void]$flow.Controls.Add($l)
        return $l
    }

    [void](Add-Text '1. На телефоне или Mac (в той же сети Wi-Fi) откройте в браузере:')
    $urlRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $urlRow.AutoSize = $true
    $urlRow.WrapContents = $false
    $urlRow.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    $urlLabel = New-Object System.Windows.Forms.Label
    $urlLabel.Text = $url
    $urlLabel.AutoSize = $true
    $urlLabel.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
    $urlLabel.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
    $copy = New-Object System.Windows.Forms.Button
    $copy.Text = 'Копировать'
    $copy.AutoSize = $true
    $copy.Tag = $url
    $copy.Margin = New-Object System.Windows.Forms.Padding(12, 4, 0, 0)
    $copy.add_Click({ [System.Windows.Forms.Clipboard]::SetText([string]$this.Tag); $this.Text = 'Скопировано' })
    [void]$urlRow.Controls.Add($urlLabel)
    [void]$urlRow.Controls.Add($copy)
    [void]$flow.Controls.Add($urlRow)

    [void](Add-Text '2. Введите код:' 10 'Regular' 14)
    $pinLabel = Add-Text (New-NotifierPin) 30 'Bold' 0
    [void](Add-Text 'Код одноразовый и действует 10 минут. Устройство запоминается — вводить код снова не нужно.' 9 'Regular' 2)
    [void](Add-Text 'На Mac после входа нажмите «Получить команду установки» и вставьте её в Терминал — тогда здесь появятся сеансы Claude этого Mac.' 9 'Regular' 10)
    $status = Add-Text 'Ожидаю подключения…' 10 'Regular' 14
    $status.ForeColor = [System.Drawing.SystemColors]::GrayText

    $btns = New-Object System.Windows.Forms.FlowLayoutPanel
    $btns.AutoSize = $true
    $btns.Margin = New-Object System.Windows.Forms.Padding(0, 14, 0, 0)
    $newPin = New-Object System.Windows.Forms.Button
    $newPin.Text = 'Новый код'
    $newPin.AutoSize = $true
    $newPin.Tag = $pinLabel
    $newPin.add_Click({ $this.Tag.Text = New-NotifierPin; $script:ConnectForm.Tag.Status.Text = 'Ожидаю подключения…'; $script:ConnectForm.Tag.Status.ForeColor = [System.Drawing.SystemColors]::GrayText })
    $close = New-Object System.Windows.Forms.Button
    $close.Text = 'Готово'
    $close.AutoSize = $true
    $close.DialogResult = [System.Windows.Forms.DialogResult]::OK
    [void]$btns.Controls.Add($close)
    [void]$btns.Controls.Add($newPin)
    [void]$flow.Controls.Add($btns)

    $f.Controls.Add($flow)
    $f.AcceptButton = $close
    $f.CancelButton = $close
    $f.Tag = @{ Status = $status; Pin = $pinLabel }
    $f.add_FormClosed({
            if ($script:Net) { $script:Net.Pairing = $null }   # закрыли окно — код больше не действует
            $script:ConnectForm = $null
        })
    $script:ConnectForm = $f
    if ($owner -and -not $owner.IsDisposed) { $f.Show($owner) } else { $f.Show() }
    $f.Activate()
}
