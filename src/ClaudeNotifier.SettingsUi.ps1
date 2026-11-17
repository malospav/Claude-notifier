<#
.SYNOPSIS
Вкладка «Настройки»: уведомления по типам и их звуки, ответы из приложения, автозапуск, папка данных.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Каждое изменение сразу записывается в config.json
(Set-NotifierConfigValue) или в ярлык «Автозагрузки»; трей читает config.json при каждом событии.
Оформление — группы строк в стиле Настроек iOS: заголовок, подпись, тумблер или кнопка справа.
#>

$script:SettingRowHeight = 60

function Get-NotifierEventLabel([string]$Type) {
    switch ($Type) {
        'done' { return @('Готово', 'Claude закончил ответ') }
        'permission' { return @('Нужно разрешение', 'Claude ждёт разрешения или ответа на вопрос') }
        'error' { return @('Ошибка', 'Ответ прервался ошибкой') }
        'limit' { return @('Лимит', 'Использовано 80 % и 90 % лимита Claude') }
    }
    return @($Type, '')
}

function Format-NotifierSoundName([string]$Sound) {
    if ([string]::IsNullOrEmpty($Sound)) { return 'Системный звук' }
    return [IO.Path]::GetFileNameWithoutExtension($Sound)
}

function Save-NotifierEventsConfig {
    <# .SYNOPSIS Записывает раздел events целиком (включение и звук каждого типа). #>
    param([Parameter(Mandatory = $true)][hashtable]$Events, [string]$DataRoot = $script:TrayDataRoot)
    $obj = [ordered]@{}
    foreach ($t in @('done', 'permission', 'error', 'limit')) {
        $obj[$t] = [ordered]@{ enabled = [bool]$Events[$t].enabled; sound = [string]$Events[$t].sound }
    }
    Set-NotifierConfigValue -Name events -Value ([pscustomobject]$obj) -DataRoot $DataRoot
}

function Set-NotifierEventOption {
    <# .SYNOPSIS Меняет включение или звук одного типа событий и сохраняет config.json. #>
    param(
        [Parameter(Mandatory = $true)][string]$Type,
        [Nullable[bool]]$Enabled = $null,
        [AllowNull()][string]$Sound = $null,
        [string]$DataRoot = $script:TrayDataRoot
    )
    $config = Get-NotifierConfig -DataRoot $DataRoot
    if ($null -ne $Enabled) { $config.events[$Type].enabled = [bool]$Enabled }
    if ($PSBoundParameters.ContainsKey('Sound')) { $config.events[$Type].sound = [string]$Sound }
    Save-NotifierEventsConfig -Events $config.events -DataRoot $DataRoot
}

function Set-NotifierOptionValue {
    <# .SYNOPSIS Меняет поле раздела approvals / quickReplies или showPrompt и сохраняет config.json. #>
    param(
        [Parameter(Mandatory = $true)][ValidateSet('approvals', 'quickReplies', 'showPrompt', 'context', 'hotkey')][string]$Name,
        [string]$Field = 'enabled',
        [Parameter(Mandatory = $true)]$Value,
        [string]$DataRoot = $script:TrayDataRoot
    )
    $config = Get-NotifierConfig -DataRoot $DataRoot
    if ($Name -eq 'showPrompt') { Set-NotifierConfigValue -Name showPrompt -Value ([bool]$Value) -DataRoot $DataRoot; return }
    $section = $config[$Name]
    $section[$Field] = $Value
    Set-NotifierConfigValue -Name $Name -Value ([pscustomobject]$section) -DataRoot $DataRoot
}

function New-NotifierSettingsGroup {
    <#
    .SYNOPSIS
    Группа строк настроек: скруглённая плашка с разделителями между строками.
    Rows: массив @{ Title; Subtitle; Control } — Control (тумблер или кнопка) прижимается вправо.
    Возвращает панель группы; у каждой строки Tag = @{ Title; Subtitle; Control }.
    #>
    param([Parameter(Mandatory = $true)]$Theme, [Parameter(Mandatory = $true)][object[]]$Rows, [int]$Width = 480)
    $t = $Theme
    $rowH = $t.S($script:SettingRowHeight)
    $group = New-NotifierGroupPanel -Theme $t -Height ($script:SettingRowHeight * $Rows.Count)
    $group.Width = $Width
    $group.Anchor = 'Top, Left, Right'
    $group.add_Paint({
            param($sender, $e)
            $th = $sender.Tag
            $h = $th.S($script:SettingRowHeight)
            $pen = New-Object System.Drawing.Pen $th.Border
            for ($i = 1; $i -lt $sender.Controls.Count; $i++) {
                $y = $i * $h
                $e.Graphics.DrawLine($pen, $th.S(16), ($y - 1), $sender.ClientSize.Width, ($y - 1))
            }
            $pen.Dispose()
        })
    $i = 0
    foreach ($r in $Rows) {
        $row = New-Object System.Windows.Forms.Panel
        $row.BackColor = $t.Surface
        $row.SetBounds($t.S(4), ($i * $rowH + $t.S(3)), ($Width - $t.S(8)), ($rowH - $t.S(6)))
        $row.Anchor = 'Top, Left, Right'
        $title = New-NotifierLabel -Theme $t -Text $r.Title -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(10.5)) -Width $t.S(300)
        $title.BackColor = $t.Surface
        $title.Location = New-Object System.Drawing.Point($t.S(12), $t.S(6))
        $sub = New-NotifierLabel -Theme $t -Text ([string]$r.Subtitle) -Muted -Width $t.S(300)
        $sub.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
        $sub.BackColor = $t.Surface
        $sub.Location = New-Object System.Drawing.Point($t.S(12), $title.Bottom)
        $row.Controls.Add($title)
        $row.Controls.Add($sub)
        $ctl = $r.Control
        if ($ctl) {
            $ctl.BackColor = $t.Surface
            $row.Controls.Add($ctl)
            $ctl.BringToFront()
        }
        $row.Tag = @{ Title = $title; Subtitle = $sub; Control = $ctl; Theme = $t }
        $row.add_Layout({
                $tg = $this.Tag
                $right = $this.ClientSize.Width - $tg.Theme.S(12)
                if ($tg.Control) {
                    $tg.Control.Left = $right - $tg.Control.Width
                    $tg.Control.Top = [int](($this.ClientSize.Height - $tg.Control.Height) / 2)
                    $right = $tg.Control.Left - $tg.Theme.S(10)
                }
                foreach ($l in @($tg.Title, $tg.Subtitle)) { $l.Width = [Math]::Max($tg.Theme.S(40), $right - $l.Left) }
            })
        $group.Controls.Add($row)
        $i++
    }
    return $group
}

function Format-NotifierHotKeySubtitle {
    # Подпись строки «Горячая клавиша»: действующее сочетание или почему его нет.
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    if (-not $config.hotkey.enabled) { return 'Win+Shift+C открывает мини-окно (выключено)' }
    if ($script:HotKeyText) { return "$($script:HotKeyText) $([char]0x2014) мини-окно с сеансами" }
    return 'Win+Shift+C и Ctrl+Alt+C заняты другой программой'
}

function New-NotifierSwitchControl {
    param([Parameter(Mandatory = $true)]$Theme, [bool]$Checked, [Parameter(Mandatory = $true)][scriptblock]$OnChange)
    $sw = New-Object ClaudeNotifier.Ui.Switch
    $sw.ApplyTheme($Theme)
    $sw.SetChecked($Checked)
    $sw.add_CheckedChanged($OnChange)
    return $sw
}

function Show-NotifierSoundMenu {
    <# .SYNOPSIS Меню звука для типа события: выбрать WAV, системный звук, прослушать. #>
    param([Parameter(Mandatory = $true)]$Button)
    $type = [string]$Button.Tag
    $form = $script:SessionsForm
    $menu = New-NotifierMenu -Theme $form.Tag.Theme -Items @(
        @('Выбрать WAV…', {
                $dlg = New-Object System.Windows.Forms.OpenFileDialog
                $dlg.Filter = 'Звук WAV (*.wav)|*.wav'
                $dlg.Title = 'Звук уведомления'
                if ($dlg.ShowDialog($script:SessionsForm) -eq [System.Windows.Forms.DialogResult]::OK) {
                    Set-NotifierEventOption -Type $script:SoundMenuType -Sound $dlg.FileName
                    Update-NotifierSettingsView
                }
                $dlg.Dispose()
            }),
        @('Системный звук', { Set-NotifierEventOption -Type $script:SoundMenuType -Sound ''; Update-NotifierSettingsView }),
        '-',
        @('Прослушать', { [void](Invoke-NotifierSound -Type $script:SoundMenuType -Config (Get-NotifierConfig -DataRoot $script:TrayDataRoot) -DataRoot $script:TrayDataRoot) })
    )
    $script:SoundMenuType = $type
    $menu.Show($Button, (New-Object System.Drawing.Point(0, $Button.Height)))
}

function New-NotifierSettingsPage {
    <#
    .SYNOPSIS
    Вкладка «Настройки». Возвращает @{ Page; Switches; SoundButtons; Autostart; DataLabel }.
    #>
    param([Parameter(Mandatory = $true)]$Theme)
    $t = $Theme
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $t.Window
    $page.AutoScroll = $true
    $page.add_HandleCreated({ [ClaudeNotifier.Ui.Native]::DarkScrollbars($this.Handle, $this.BackColor.GetBrightness() -lt 0.5) })
    $width = $t.S(500)
    $y = 0
    $ui = @{ Page = $page; Switches = @{}; SoundButtons = @{}; Theme = $t }

    function Add-Header([string]$Text) {
        $h = New-NotifierLabel -Theme $t -Text $Text -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(9)) -Muted -Width $t.S(400)
        $h.Location = New-Object System.Drawing.Point($t.S(16), $script:settingsY)
        $page.Controls.Add($h)
        $script:settingsY = $h.Bottom + $t.S(6)
    }
    function Add-Group($Group, [string]$Footer = '') {
        $Group.Location = New-Object System.Drawing.Point(0, $script:settingsY)
        $page.Controls.Add($Group)
        $script:settingsY = $Group.Bottom + $t.S(8)
        if ($Footer) {
            $f = New-NotifierLabel -Theme $t -Text $Footer -Muted -Wrap -Width ($width - $t.S(32))
            $f.Font = [ClaudeNotifier.Ui.Fonts]::Text(9)
            $f.Height = $f.GetPreferredSize((New-Object System.Drawing.Size($f.Width, 0))).Height + 2
            $f.Location = New-Object System.Drawing.Point($t.S(16), $script:settingsY)
            $f.Anchor = 'Top, Left, Right'
            $page.Controls.Add($f)
            $script:settingsY = $f.Bottom
        }
        $script:settingsY += $t.S(22)
    }
    $script:settingsY = $y

    # Уведомления: тумблер на тип и кнопка звука.
    Add-Header 'Уведомления'
    $rows = @()
    foreach ($type in @('done', 'permission', 'error', 'limit')) {
        $label = Get-NotifierEventLabel $type
        $sw = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.events[$type].enabled) -OnChange { Set-NotifierEventOption -Type ([string]$this.Tag) -Enabled $this.Checked }
        $sw.Tag = $type
        $sound = New-NotifierButton -Theme $t -Text (Format-NotifierSoundName ([string]$config.events[$type].sound)) -Plain -OnClick { Show-NotifierSoundMenu -Button $this }
        $sound.Tag = $type
        # Кнопка звука и тумблер в одной ячейке справа.
        $cell = New-Object System.Windows.Forms.Panel
        $cell.Size = New-Object System.Drawing.Size(($t.S(150) + $sw.Width), $sw.Height)
        $cell.BackColor = $t.Surface
        $sound.BackColor = $t.Surface
        $sound.Width = $t.S(140)
        $sound.Location = New-Object System.Drawing.Point(0, [int](($cell.Height - $sound.Height) / 2))
        $sw.Location = New-Object System.Drawing.Point(($cell.Width - $sw.Width), 0)
        $cell.Controls.Add($sound); $cell.Controls.Add($sw)
        $rows += @{ Title = $label[0]; Subtitle = $label[1]; Control = $cell }
        $ui.Switches["event.$type"] = $sw
        $ui.SoundButtons[$type] = $sound
    }
    Add-Group (New-NotifierSettingsGroup -Theme $t -Rows $rows -Width $width) 'Звук играет вместе с уведомлением. Свой звук — файл WAV.'

    # Ответы из приложения.
    Add-Header 'Ответы из приложения'
    $swApprove = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.approvals.enabled) -OnChange { Set-NotifierOptionValue -Name approvals -Value $this.Checked }
    $swReply = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.quickReplies.enabled) -OnChange { Set-NotifierOptionValue -Name quickReplies -Value $this.Checked }
    $swPrompt = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.showPrompt) -OnChange { Set-NotifierOptionValue -Name showPrompt -Value $this.Checked }
    $ui.Switches['approvals'] = $swApprove; $ui.Switches['quickReplies'] = $swReply; $ui.Switches['showPrompt'] = $swPrompt
    Add-Group (New-NotifierSettingsGroup -Theme $t -Width $width -Rows @(
            @{ Title = 'Запросы разрешения'; Subtitle = 'Разрешать и отвечать на вопросы Claude из окна, трея и с телефона'; Control = $swApprove },
            @{ Title = 'Быстрые ответы'; Subtitle = 'Отвечать Claude после «Готово», не переключаясь в его окно'; Control = $swReply },
            @{ Title = 'Показывать мой запрос'; Subtitle = 'Начало последнего запроса в подробностях сеанса'; Control = $swPrompt }
        )) 'Работает для сеансов этого ПК. Если вы ответили прямо в Claude, запрос в приложении исчезнет сам.'

    # Внимание: контекст, напоминания, горячая клавиша.
    Add-Header 'Внимание'
    $swContext = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.context.enabled) -OnChange { Set-NotifierOptionValue -Name context -Value $this.Checked }
    $swRemind = New-NotifierSwitchControl -Theme $t -Checked ([int]$config.approvals.remindMinutes -gt 0) -OnChange {
        $m = 0
        if ($this.Checked) { $m = 3 }
        Set-NotifierOptionValue -Name approvals -Field remindMinutes -Value $m
    }
    $swHotkey = New-NotifierSwitchControl -Theme $t -Checked ([bool]$config.hotkey.enabled) -OnChange {
        Set-NotifierOptionValue -Name hotkey -Value $this.Checked
        try { [void](Register-NotifierHotKey) } catch { }
        Update-NotifierSettingsView
    }
    $ui.Switches['context'] = $swContext; $ui.Switches['remind'] = $swRemind; $ui.Switches['hotkey'] = $swHotkey
    $attention = New-NotifierSettingsGroup -Theme $t -Width $width -Rows @(
        @{ Title = 'Контекст почти заполнен'; Subtitle = "Уведомить на $([int]$config.context.warnPercent) % $([char]0x2014) до автосжатия истории"; Control = $swContext },
        @{ Title = 'Напоминать о запросах'; Subtitle = 'Повторить через 3 мин, если запрос ждёт; точка в трее мигает'; Control = $swRemind },
        @{ Title = 'Горячая клавиша'; Subtitle = (Format-NotifierHotKeySubtitle); Control = $swHotkey }
    )
    $ui.HotkeyRow = @($attention.Controls)[2]
    Add-Group $attention 'Мини-окно по горячей клавише открывается у трея, повторное нажатие закрывает его.'

    # Система.
    Add-Header 'Система'
    $swAuto = New-NotifierSwitchControl -Theme $t -Checked (Test-NotifierAutostart) -OnChange {
        try { Set-NotifierAutostart -Enabled $this.Checked -AppRoot $PSScriptRoot }
        catch { $this.SetChecked(-not $this.Checked); Write-NotifierLog -Level ERROR -Message "settings: автозапуск: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    }
    $ui.Autostart = $swAuto
    $open = New-NotifierButton -Theme $t -Text 'Открыть' -Plain -OnClick { Start-Process explorer.exe $script:TrayDataRoot }
    Add-Group (New-NotifierSettingsGroup -Theme $t -Width $width -Rows @(
            @{ Title = 'Запускать при входе в Windows'; Subtitle = 'Точка статуса в трее сразу после включения ПК'; Control = $swAuto },
            @{ Title = 'Папка данных'; Subtitle = $script:TrayDataRoot; Control = $open }
        ))
    $ui.DataLabel = $script:TrayDataRoot
    # Группы тянутся по ширине страницы.
    $page.add_Resize({
            $w = $this.ClientSize.Width
            foreach ($c in $this.Controls) { if ($c -is [System.Windows.Forms.Panel]) { $c.Width = $w } }
        })
    return $ui
}

function Update-NotifierSettingsView {
    <# .SYNOPSIS Синхронизирует вкладку «Настройки» с config.json и ярлыком автозапуска. #>
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed -or $null -eq $form.Tag.Settings) { return }
    $ui = $form.Tag.Settings
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    foreach ($type in @('done', 'permission', 'error', 'limit')) {
        $ui.Switches["event.$type"].SetChecked([bool]$config.events[$type].enabled)
        $ui.SoundButtons[$type].Text = Format-NotifierSoundName ([string]$config.events[$type].sound)
    }
    $ui.Switches['approvals'].SetChecked([bool]$config.approvals.enabled)
    $ui.Switches['quickReplies'].SetChecked([bool]$config.quickReplies.enabled)
    $ui.Switches['showPrompt'].SetChecked([bool]$config.showPrompt)
    if ($ui.Switches.ContainsKey('context')) {
        $ui.Switches['context'].SetChecked([bool]$config.context.enabled)
        $ui.Switches['remind'].SetChecked([int]$config.approvals.remindMinutes -gt 0)
        $ui.Switches['hotkey'].SetChecked([bool]$config.hotkey.enabled)
        if ($ui.HotkeyRow) { $ui.HotkeyRow.Tag.Subtitle.Text = Format-NotifierHotKeySubtitle }
    }
    $ui.Autostart.SetChecked((Test-NotifierAutostart))
}
