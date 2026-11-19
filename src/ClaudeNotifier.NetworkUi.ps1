<#
.SYNOPSIS
Интерфейс доступа из сети: вкладка «Устройства», окно «Подключить устройство», включение и выключение доступа.

.DESCRIPTION
Подключается к ClaudeNotifier.Network.ps1 через dot-source; использует элементы и диалоги из ClaudeNotifier.Ui.ps1.
Стиль Apple: сгруппированный список с заголовком и подписью, тумблер, строка-действие «Подключить устройство».
#>

$script:ConnectActionId = '__connect'

function Get-NotifierDeviceOsLabel($Device) {
    # Система устройства с хуками: Mac (и прежние установки без поля os), Linux или WSL.
    $os = ''
    if ($Device -and $Device.PSObject.Properties['os']) { $os = [string]$Device.os }
    switch ($os) { 'linux' { return 'Linux' } 'wsl' { return 'WSL' } default { return 'Mac' } }
}

function Get-NotifierDeviceKindText {
    param([Parameter(Mandatory = $true)]$Device)
    if ($Device.hooks) { return "$(Get-NotifierDeviceOsLabel $Device) $([char]0x00B7) сеансы видны здесь" }
    if ($Device.name -eq 'Mac') { return 'Браузер · хуки не установлены' }
    return 'Браузер · только просмотр'
}

function Format-NotifierSessionCount([int]$N) {
    if ($N -eq 0) { return 'нет сеансов' }
    $word = 'сеансов'
    if ($N % 10 -eq 1 -and $N % 100 -ne 11) { $word = 'сеанс' }
    elseif ($N % 10 -ge 2 -and $N % 10 -le 4 -and ($N % 100 -lt 12 -or $N % 100 -gt 14)) { $word = 'сеанса' }
    return "$N $word"
}

function ConvertTo-NotifierDeviceCard {
    <# .SYNOPSIS Устройство → строка списка: имя, связь (точка), тип, число сеансов, уведомления. #>
    param([Parameter(Mandatory = $true)]$Device, [int]$Sessions = 0, [datetime]$Now = [DateTime]::UtcNow)
    $card = New-Object ClaudeNotifier.Ui.CardItem
    $card.Id = [string]$Device.id
    $card.Section = 'Устройства'
    $card.Title = [string]$Device.name
    $seen = Format-NotifierLastSeen -Ts ([string]$Device.last_seen) -Now $Now
    if ($seen -eq 'в сети') { $card.State = 'online'; $card.StateText = 'В сети' }
    else { $card.State = 'none'; $card.HollowDot = $true; $card.StateText = "Был $seen" }
    if ($seen -eq '—') { $card.StateText = 'Ещё не на связи' }
    $meta = @((Get-NotifierDeviceKindText $Device), (Format-NotifierSessionCount $Sessions))
    if ($Device.notify) { $meta += 'уведомления на ПК' }
    # ПК обновился, а на Mac старые хуки: подсказка и команда в меню устройства («Получить команду установки»).
    if (Test-NotifierMacHooksOutdated -Device $Device) { $meta += 'обновите хуки: «Получить команду установки»' }
    $card.Meta = $meta -join " $([char]0x00B7) "
    $card.Tag = $Device
    return $card
}

function New-NotifierConnectRow {
    $row = New-Object ClaudeNotifier.Ui.CardItem
    $row.Id = $script:ConnectActionId
    $row.Section = 'Устройства'
    $row.Title = 'Подключить устройство…'
    $row.IsAction = $true
    return $row
}

function Update-NotifierDevicesView {
    <# .SYNOPSIS Вкладка «Устройства»: группа «Доступ из сети» с тумблером и список устройств. #>
    param([Parameter(Mandatory = $true)][hashtable]$Ui, [AllowEmptyCollection()][object[]]$Sessions = @())
    $net = $script:Net
    if ($null -eq $net) { return }
    $Ui.NetSub.ForeColorOverride = [System.Drawing.Color]::Empty
    if ($net.Server) {
        $Ui.NetSub.Text = "Включён $([char]0x00B7) $(Get-NotifierServerBaseUrl $net)"
        $Ui.NetSwitch.SetChecked($true)
    }
    elseif ($net.Network.enabled -and $net.Error) {
        $Ui.NetSub.Text = "Сервер не запустился: $($net.Error)"
        $Ui.NetSub.ForeColorOverride = $Ui.Theme.Danger
        $Ui.NetSwitch.SetChecked($true)
    }
    else {
        $Ui.NetSub.Text = 'Выключен — Mac и телефон не видят этот ПК'
        $Ui.NetSwitch.SetChecked($false)
    }
    $Ui.NetSub.Invalidate()

    $counts = @{}
    foreach ($s in $Sessions) {
        $id = ''
        if ($s.PSObject.Properties['device']) { $id = [string]$s.device }
        $counts[$id] = 1 + [int]$counts[$id]
    }
    $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
    foreach ($d in $net.Network.devices) { $list.Add((ConvertTo-NotifierDeviceCard -Device $d -Sessions ([int]$counts[[string]$d.id]))) }
    $list.Add((New-NotifierConnectRow))
    $Ui.Devices.SetItems($list)
}

function Format-NotifierDevicesSubtitle {
    <# .SYNOPSIS Подзаголовок вкладки «Устройства»: число устройств и состояние доступа из сети. #>
    $net = $script:Net
    if ($null -eq $net) { return '' }
    $n = $net.Network.devices.Count
    $text = 'Нет подключённых устройств'
    if ($n -gt 0) {
        $word = 'устройств'
        if ($n % 10 -eq 1 -and $n % 100 -ne 11) { $word = 'устройство' }
        elseif ($n % 10 -ge 2 -and $n % 10 -le 4 -and ($n % 100 -lt 12 -or $n % 100 -gt 14)) { $word = 'устройства' }
        $text = "$n $word"
    }
    if ($net.Server) { return "$text $([char]0x00B7) доступ из сети включён" }
    return "$text $([char]0x00B7) доступ из сети выключен"
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
        $answer = Show-NotifierDialog -Owner $Owner -Title 'Разрешить доступ из сети?' -Primary 'Продолжить' -Message (
            "Windows один раз попросит права администратора, чтобы Mac и телефон могли подключаться к этому ПК. " +
            "Вход на порт $($net.Network.port) будет открыт только для вашей локальной сети.")
        if (-not $answer.Ok) { return $false }
        $result = Invoke-NotifierNetworkSetup -Port $net.Network.port -DataRoot $net.DataRoot
        if ($result -ne 'ok') {
            if ($result -eq 'failed') {
                [void](Show-NotifierDialog -Owner $Owner -Title 'Не получилось' -Secondary '' -Message "Настройка Windows не удалась. Подробности: $(Join-Path $net.DataRoot 'setup-network.log')")
            }
            return $false
        }
    }
    $net.Network.enabled = $true
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
    $ok = Start-NotifierNetServer
    if (-not $ok) { [void](Show-NotifierDialog -Owner $Owner -Title 'Сервер не запустился' -Secondary '' -Message $net.Error) }
    return $ok
}

function Enable-NotifierNetworkTls {
    <#
    .SYNOPSIS
    «Шифрование» → «Включить»: та же разовая настройка Windows (UAC) — сертификат и https на порту <port + 1>;
    затем сервер перезапускается. Хуки устройств перейдут на https после «Получить команду установки».
    #>
    param([System.Windows.Forms.IWin32Window]$Owner)
    $net = $script:Net
    if ($net.Tls) { return $true }
    $answer = Show-NotifierDialog -Owner $Owner -Title 'Включить шифрование?' -Primary 'Продолжить' -Message (
        "Windows один раз попросит права администратора: этот ПК создаст свой сертификат, и хуки Mac, Linux и WSL " +
        "будут ходить по https $([char]0x2014) токены не пойдут по Wi-Fi открытым текстом. Потом переустановите хуки на устройствах.")
    if (-not $answer.Ok) { return $false }
    $result = Invoke-NotifierNetworkSetup -Port $net.Network.port -DataRoot $net.DataRoot
    if ($result -eq 'failed') { [void](Show-NotifierDialog -Owner $Owner -Title 'Не получилось' -Secondary '' -Message "Подробности: $(Join-Path $net.DataRoot 'setup-network.log')") }
    if ($result -ne 'ok') { return $false }
    if ($net.Server) { Stop-NotifierNetServer }
    [void](Start-NotifierNetServer)
    if (-not $net.Tls) { [void](Show-NotifierDialog -Owner $Owner -Title 'Шифрование не включилось' -Secondary '' -Message "Сервер работает без https. Подробности: $(Join-Path $net.DataRoot 'setup-network.log')") }
    return [bool]$net.Tls
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
    $d = Find-NotifierDevice -Network $net.Network -Id $Id
    $name = ''
    if ($d) { $name = [string]$d.name }
    if (-not (Remove-NotifierDevice -Network $net.Network -Id $Id)) { return $false }
    $net.NetworkDirty = $true
    Save-NotifierNet -Force
    $all = @(Get-NotifierSessions -DataRoot $net.DataRoot)
    $mine = @($all | Where-Object { $_.PSObject.Properties['device'] -and [string]$_.device -eq $Id })
    # Отключили, чтобы подключить заново (переустановка хуков): сеансы вернутся, когда тот же Mac снова подключится.
    try { Save-NotifierRemovedSessions -Name $name -Sessions $mine -DataRoot $net.DataRoot } catch { }
    $rest = @($all | Where-Object { -not ($_.PSObject.Properties['device'] -and [string]$_.device -eq $Id) })
    Save-NotifierSessions -Sessions $rest -DataRoot $net.DataRoot
    $script:SessionsDirty = $true
    return $true
}

function Invoke-NotifierDeviceAction {
    <# .SYNOPSIS Действия с выделенным устройством: rename | notify | remove. #>
    param([Parameter(Mandatory = $true)][ValidateSet('rename', 'notify', 'remove')][string]$Action)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $item = $form.Tag.Net.Devices.SelectedItem
    if ($null -eq $item -or $item.IsAction) { return }
    $d = $item.Tag
    switch ($Action) {
        'rename' {
            $r = Show-NotifierDialog -Owner $form -Title 'Переименовать устройство' -Primary 'Сохранить' -InputValue ([string]$d.name)
            if (-not $r.Ok) { return }
            $name = ([string]$r.Value -replace '[\x00-\x1f]', '').Trim()
            if ($name -eq '') { return }
            if ($name.Length -gt 60) { $name = $name.Substring(0, 60) }
            $d.name = $name
        }
        'notify' { $d.notify = -not [bool]$d.notify }
        'remove' {
            $msg = 'Устройство потеряет доступ к этому ПК.'
            if ($d.hooks) { $msg += " Хуки на самом Mac останутся — удалить их: ~/.claude-notifier/uninstall.sh" }
            $r = Show-NotifierDialog -Owner $form -Title "Отключить «$($d.name)»?" -Primary 'Отключить' -Destructive -Message $msg
            if (-not $r.Ok) { return }
            [void](Remove-NotifierDeviceAndSessions -Id ([string]$d.id))
        }
    }
    $script:Net.NetworkDirty = $true
    Save-NotifierNet -Force
    [void](Invoke-NotifierSessionsRefresh)
}

function New-NotifierGroupPanel {
    <# .SYNOPSIS Скруглённая группа цвета строки (как ячейка в Настройках iOS) для своих элементов. #>
    param([Parameter(Mandatory = $true)]$Theme, [int]$Height = 64)
    $p = New-Object System.Windows.Forms.Panel
    $p.Height = $Theme.S($Height)
    $p.BackColor = $Theme.Window
    $p.Tag = $Theme
    $p.add_Paint({
            param($sender, $e)
            $th = $sender.Tag
            $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            [ClaudeNotifier.Ui.Draw]::Fill($e.Graphics, (New-Object System.Drawing.RectangleF(0, 0, $sender.ClientSize.Width, $sender.ClientSize.Height)), $th.S(12), $th.Surface)
        })
    $p.add_Resize({ $this.Invalidate() })
    return $p
}

function New-NotifierDevicesPage {
    <#
    .SYNOPSIS
    Вкладка «Устройства». Возвращает @{ Page; Theme; NetCard; NetTitle; NetSub; NetSwitch; Devices; Menu }.
    #>
    param([Parameter(Mandatory = $true)]$Theme)
    $t = $Theme
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $t.Window

    # Группа «Доступ из сети»: заголовок и состояние слева, тумблер справа.
    $card = New-NotifierGroupPanel -Theme $t -Height 62
    $card.Dock = [System.Windows.Forms.DockStyle]::Top
    $netTitle = New-NotifierLabel -Theme $t -Text 'Доступ из сети' -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(10.5)) -Width $t.S(340)
    $netTitle.Location = New-Object System.Drawing.Point($t.S(16), $t.S(10))
    $netSub = New-NotifierLabel -Theme $t -Text '' -Muted -Width $t.S(360)
    $netSub.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
    $netSub.Location = New-Object System.Drawing.Point($t.S(16), ($netTitle.Bottom))
    $netSub.Anchor = 'Top, Left'
    $switch = New-Object ClaudeNotifier.Ui.Switch
    $switch.ApplyTheme($t)
    $switch.Anchor = 'Top, Right'
    $switch.Top = [int](($card.Height - $switch.Height) / 2)
    $switch.add_CheckedChanged({
            $form = $script:SessionsForm
            if ($this.Checked) {
                if (-not (Enable-NotifierNetworkAccess -Owner $form)) { $this.SetChecked($false) }
            }
            else { Disable-NotifierNetworkAccess }
            [void](Invoke-NotifierSessionsRefresh)
        })
    # Тумблер прижат к правому краю; подписи занимают место только до него (иначе подпись перекрывает тумблер).
    $card.add_Layout({
            $th = $this.Tag
            $sw = @($this.Controls | Where-Object { $_ -is [ClaudeNotifier.Ui.Switch] })[0]
            if ($null -eq $sw) { return }
            $sw.Left = $this.ClientSize.Width - $sw.Width - $th.S(16)
            $sw.Top = [int](($this.ClientSize.Height - $sw.Height) / 2)
            foreach ($l in @($this.Controls | Where-Object { $_ -is [ClaudeNotifier.Ui.Label2] })) {
                $l.Width = [Math]::Max($th.S(40), $sw.Left - $l.Left - $th.S(12))
            }
        })
    foreach ($c in @($netTitle, $netSub, $switch)) { $c.BackColor = $t.Surface; $card.Controls.Add($c) }
    $switch.BringToFront()

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = [System.Windows.Forms.DockStyle]::Top
    $spacer.Height = $t.S(22)
    $spacer.BackColor = $t.Window

    $devices = New-Object ClaudeNotifier.Ui.CardList
    $devices.ApplyTheme($t)
    $devices.Dock = [System.Windows.Forms.DockStyle]::Fill
    $devices.Footer = 'Mac и телефон должны быть в той же сети Wi-Fi. Сеансы Mac появятся в списке сеансов, а с телефона их можно смотреть в браузере.'
    $devices.EmptyTitle = 'Устройств пока нет'
    $menu = New-NotifierMenu -Theme $t -Items @(
        @('Переименовать', { Invoke-NotifierDeviceAction -Action rename }),
        @('Уведомления на ПК', { Invoke-NotifierDeviceAction -Action notify }),
        '-',
        @('Отключить', { Invoke-NotifierDeviceAction -Action remove })
    )
    $menu.ShowCheckMargin = $true
    $menu.add_Opening({
            $item = $script:SessionsForm.Tag.Net.Devices.SelectedItem
            if ($null -eq $item -or $item.IsAction) { $_.Cancel = $true; return }
            $this.Items[1].Checked = [bool]$item.Tag.notify
        })
    $devices.add_ItemAction({
            param($sender, $e)
            if ($e.Item.IsAction) { if ($e.Action -eq 'open') { Show-NotifierConnectDialog }; return }
            switch ($e.Action) {
                'open' { Invoke-NotifierDeviceAction -Action rename }
                'delete' { Invoke-NotifierDeviceAction -Action remove }
                'context' { $script:SessionsForm.Tag.Net.Menu.Show($sender, $e.Location) }
            }
        })

    $page.Controls.Add($devices)
    $page.Controls.Add($spacer)
    $page.Controls.Add($card)
    return @{ Page = $page; Theme = $t; NetCard = $card; NetTitle = $netTitle; NetSub = $netSub; NetSwitch = $switch; Devices = $devices; Menu = $menu }
}

function Update-NotifierConnectStatus {
    <# .SYNOPSIS В открытом окне «Подключить устройство» показывает, что устройство подключилось. #>
    param($Device)
    $f = $script:ConnectForm
    if ($null -eq $f -or $f.IsDisposed -or $null -eq $Device) { return }
    $text = "Подключено: $($Device.name)"
    if ($Device.hooks) { $text = "$($Device.name): хуки установлены — сеансы появятся во вкладке «Сеансы»" }
    $f.Tag.Status.Text = $text
    $f.Tag.Status.DotState = 'online'
    $f.Tag.Status.MutedText = $false
    $f.Tag.Status.Invalidate()
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
    Окно «Подключить устройство»: адрес ПК и одноразовый код в ячейках. Если доступ из сети выключен — сначала включает его.
    #>
    $owner = $script:SessionsForm
    if ($script:ConnectForm -and -not $script:ConnectForm.IsDisposed) { $script:ConnectForm.Activate(); return }
    if (-not (Enable-NotifierNetworkAccess -Owner $owner)) { [void](Invoke-NotifierSessionsRefresh); return }
    [void](Invoke-NotifierSessionsRefresh)
    $net = $script:Net
    if ([string]::IsNullOrEmpty($net.Address)) {
        [void](Show-NotifierDialog -Owner $owner -Title 'Нет сети' -Secondary '' -Message 'Этот ПК не подключён к локальной сети: адрес не найден.')
        return
    }
    $url = Get-NotifierServerBaseUrl $net
    $t = Get-NotifierTheme
    $w = 400
    $f = New-NotifierSheet -Theme $t -Width $w -Height 520 -Badge device
    $f.ShowInTaskbar = $true   # окно немодальное: пока ждёт устройство, его можно найти на панели задач
    $f.Text = 'Подключить устройство'
    $f.TopMost = $false
    $pad = $t.S(28); $inner = $t.S($w) - 2 * $pad
    $script:connectY = $f.ContentTop
    function Add-Line($Control, [int]$After = 0, [switch]$Indent) {
        $x = $pad
        if ($Indent) { $x += $t.S(16) }
        $Control.Location = New-Object System.Drawing.Point($x, $script:connectY)
        $f.Controls.Add($Control)
        $script:connectY = $Control.Bottom + $After
    }
    function New-Centered([string]$Text, $Font, [switch]$Muted, [switch]$Wrap) {
        $l = New-NotifierLabel -Theme $t -Text $Text -Font $Font -Width $inner -Muted:$Muted -Wrap:$Wrap
        $l.Center = $true
        return $l
    }

    Add-Line (New-Centered 'Подключить устройство' ([ClaudeNotifier.Ui.Fonts]::Display(15))) $t.S(4)
    Add-Line (New-Centered 'Mac или телефон должен быть в той же сети Wi-Fi.' ([ClaudeNotifier.Ui.Fonts]::Text(10)) -Muted -Wrap) $t.S(22)

    Add-Line (New-NotifierLabel -Theme $t -Text '1. Откройте в браузере' -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(9)) -Muted -Width ($inner - $t.S(16))) $t.S(6) -Indent
    $urlCard = New-NotifierGroupPanel -Theme $t -Height 48
    $urlCard.Width = $inner
    $urlLabel = New-NotifierLabel -Theme $t -Text $url -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(11)) -Width ($inner - $t.S(130))
    $urlLabel.ForeColorOverride = $t.Text
    $urlLabel.BackColor = $t.Surface
    $urlLabel.Location = New-Object System.Drawing.Point($t.S(16), [int](($urlCard.Height - $urlLabel.Height) / 2))
    $copy = New-NotifierButton -Theme $t -Text 'Копировать' -Plain -OnClick { [System.Windows.Forms.Clipboard]::SetText([string]$this.Tag); $this.Text = 'Скопировано'; $this.FitWidth(); $this.Left = $this.Parent.ClientSize.Width - $this.Width - $this.Parent.Tag.S(8) }
    $copy.Tag = $url
    $copy.BackColor = $t.Surface
    $copy.Location = New-Object System.Drawing.Point(($inner - $copy.Width - $t.S(8)), [int](($urlCard.Height - $copy.Height) / 2))
    $urlCard.Controls.Add($urlLabel)
    $urlCard.Controls.Add($copy)
    Add-Line $urlCard $t.S(22)

    Add-Line (New-NotifierLabel -Theme $t -Text '2. Введите код' -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(9)) -Muted -Width ($inner - $t.S(16))) $t.S(8) -Indent
    $pin = New-Object ClaudeNotifier.Ui.PinView
    $pin.ApplyTheme($t)
    $pin.Width = $inner
    $pin.BackColor = $t.Window
    $pin.Text = New-NotifierPin
    Add-Line $pin $t.S(12)
    Add-Line (New-Centered 'Код одноразовый и действует 10 минут. Устройство запоминается — вводить код снова не придётся.' ([ClaudeNotifier.Ui.Fonts]::Text(9)) -Muted -Wrap) $t.S(8)
    Add-Line (New-Centered 'На Mac после входа нажмите «Получить команду установки» и вставьте её в Терминал.' ([ClaudeNotifier.Ui.Fonts]::Text(9)) -Muted -Wrap) $t.S(20)

    $status = New-NotifierLabel -Theme $t -Text 'Ожидаю подключения…' -Muted -Width $inner -Dot 'none'
    $status.Center = $true
    Add-Line $status $t.S(20)

    $done = New-NotifierButton -Theme $t -Text 'Готово' -Primary -Width $inner
    $done.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $done.add_Click({ $this.FindForm().Close() })
    Add-Line $done $t.S(6)
    $newPin = New-NotifierButton -Theme $t -Text 'Новый код' -Plain -OnClick {
        $tag = $script:ConnectForm.Tag
        $tag.Pin.Text = New-NotifierPin
        $tag.Status.Text = 'Ожидаю подключения…'; $tag.Status.DotState = 'none'; $tag.Status.MutedText = $true; $tag.Status.Invalidate()
    }
    $newPin.Location = New-Object System.Drawing.Point(($pad + [int](($inner - $newPin.Width) / 2)), $script:connectY)
    $f.Controls.Add($newPin)
    $f.ClientSize = New-Object System.Drawing.Size($t.S($w), ($newPin.Bottom + $t.S(16)))
    $f.AcceptButton = $done
    $f.CancelButton = $done
    $f.Tag.Status = $status; $f.Tag.Pin = $pin; $f.Tag.NewPin = $newPin; $f.Tag.Url = $urlLabel
    $f.add_FormClosed({
            if ($script:Net) { $script:Net.Pairing = $null }   # закрыли окно — код больше не действует
            $script:ConnectForm = $null
        })
    $script:ConnectForm = $f
    if ($owner -and -not $owner.IsDisposed) { $f.Show($owner) } else { $f.Show() }
    $f.Activate()
}
