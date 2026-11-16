<#
.SYNOPSIS
Интерфейс трея claude-notifier: окно «Сеансы» (карточки, вкладки), точка статуса в трее, диалоги.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source и работает в его области видимости ($script:…).
Отрисовка — элементы ClaudeNotifier.Ui.* из lib\Ui.cs: тема как в Windows (светлая/тёмная), Segoe UI Variable.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Ui.psm1')

$script:NoticeUntil = [datetime]::MinValue
$script:DotIcons = @{}
$script:TrayStateShown = $null

function Get-NotifierTheme {
    <# .SYNOPSIS Тема по настройке Windows и масштаб экрана (DPI / 96). #>
    [void](Import-NotifierUi)
    $theme = [ClaudeNotifier.Ui.Theme]::Current()
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $theme.Scale = [float]($g.DpiX / 96) } finally { $g.Dispose() }
    return $theme
}

# --- Точка статуса в трее ---

function Get-NotifierDotIcon {
    <# .SYNOPSIS Иконка-точка для статуса (кэшируется на время работы трея). #>
    param([Parameter(Mandatory = $true)][string]$State)
    if (-not $script:DotIcons.ContainsKey($State)) {
        [void](Import-NotifierUi)
        $size = [System.Windows.Forms.SystemInformation]::SmallIconSize.Width
        $script:DotIcons[$State] = [ClaudeNotifier.Ui.TrayDot]::Create($State, $size)
    }
    return $script:DotIcons[$State]
}

function Update-NotifierTrayStatus {
    <# .SYNOPSIS Меняет точку в трее и подсказку по списку живых сеансов. Возвращает показанный статус. #>
    param([AllowEmptyCollection()][object[]]$Sessions = @(), $Icon = $script:TrayState.Icon)
    $state = Get-NotifierTrayState -Sessions $Sessions
    if ($Icon) {
        if ($state -ne $script:TrayStateShown) { $Icon.Icon = Get-NotifierDotIcon $state }
        $Icon.Text = Format-NotifierTrayTooltip -Sessions $Sessions
    }
    $script:TrayStateShown = $state
    return $state
}

# --- Карточки сеансов ---

function ConvertTo-NotifierSessionCard {
    <# .SYNOPSIS Сеанс → карточка: проект, статус цветом, где идёт, сколько, превью ответа. #>
    param([Parameter(Mandatory = $true)]$Session, [datetime]$Now = [DateTime]::UtcNow)
    $card = New-Object ClaudeNotifier.Ui.CardItem
    $card.Id = [string]$Session.session_id
    $card.Title = [string]$Session.project
    if ($card.Title -eq '') { $card.Title = 'Без проекта' }
    $card.State = [string]$Session.state
    $card.StateText = Get-NotifierSessionStateText ([string]$Session.state)
    $card.Meta = 'Терминал'
    if ([string]$Session.origin -eq 'desktop') { $card.Meta = 'Приложение' }
    $deviceId = ''
    if ($Session.PSObject.Properties['device']) { $deviceId = [string]$Session.device }
    $card.Section = Get-NotifierDeviceName $deviceId   # группа списка — устройство, как в Настройках iOS
    $card.Right = Format-NotifierElapsed -Ts ([string]$Session.since) -Now $Now
    $card.Preview = [string]$Session.preview
    $card.Tag = $Session
    return $card
}

function Update-NotifierSessionsView {
    <#
    .SYNOPSIS
    Заполняет список карточек сеансов (порядок: ждут вас → работают). Возвращает подзаголовок окна.
    #>
    param(
        [Parameter(Mandatory = $true)]$Cards,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Sessions,
        [datetime]$Now = [DateTime]::UtcNow
    )
    # Группы по устройствам: сначала группа, где самый «срочный» сеанс; внутри группы — порядок срочности.
    # foreach, а не конвейер: Get-NotifierSortedSessions возвращает массив одним объектом.
    $cardsSorted = @(foreach ($x in (Get-NotifierSortedSessions -Sessions $Sessions)) { ConvertTo-NotifierSessionCard -Session $x -Now $Now })
    $order = New-Object System.Collections.ArrayList
    foreach ($c in $cardsSorted) { if (-not $order.Contains($c.Section)) { [void]$order.Add($c.Section) } }
    $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
    foreach ($section in $order) { foreach ($c in $cardsSorted) { if ($c.Section -eq $section) { $list.Add($c) } } }
    $Cards.SetItems($list)
    return (Format-NotifierSessionsSubtitle -Sessions $Sessions)
}

function Format-NotifierSessionsSubtitle {
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $n = @($Sessions).Count
    if ($n -eq 0) { return 'Нет активных сеансов' }
    $need = @($Sessions | Where-Object { $_.state -eq 'permission' -or $_.state -eq 'error' }).Count
    $word = 'активных'
    if ($n % 10 -eq 1 -and $n % 100 -ne 11) { $word = 'активный' }
    $text = "$n $word"
    if ($need -gt 0) { $text += " $([char]0x00B7) требуют внимания: $need" }
    return $text
}

function Show-NotifierNotice {
    <# .SYNOPSIS Временная подсказка под заголовком окна (4 с). #>
    param([Parameter(Mandatory = $true)][string]$Text)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $form.Tag.Subtitle.Text = $Text
    $script:NoticeUntil = [datetime]::UtcNow.AddSeconds(4)
}

function Invoke-NotifierSessionsRefresh {
    <#
    .SYNOPSIS
    Перечитывает sessions.json, убирает завершившиеся сеансы, обновляет точку в трее и открытое окно.
    Возвращает список живых сеансов.
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $all = @(Get-NotifierSessions -DataRoot $DataRoot)
    $live = Select-NotifierLiveSessions -Sessions $all   # уже массив; @() вложил бы его в ещё один
    if ($live.Count -ne $all.Count) { Save-NotifierSessions -Sessions $live -DataRoot $DataRoot }
    $script:SessionsDirty = $false
    $script:SessionsRefreshedAt = [datetime]::UtcNow
    try { [void](Update-NotifierTrayStatus -Sessions $live) } catch { }
    $form = $script:SessionsForm
    if ($form -and -not $form.IsDisposed) {
        $subtitle = Update-NotifierSessionsView -Cards $form.Tag.Cards -Sessions $live
        if ($form.Tag.Net) {
            Update-NotifierDevicesView -Ui $form.Tag.Net -Sessions $live
            if ($form.Tag.Tabs.SelectedIndex -eq 1) { $subtitle = Format-NotifierDevicesSubtitle }
        }
        if ([datetime]::UtcNow -ge $script:NoticeUntil) { $form.Tag.Subtitle.Text = $subtitle }
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
    # Действие над выделенной карточкой: focus | remove.
    param([Parameter(Mandatory = $true)][ValidateSet('focus', 'remove')][string]$Action)
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed) { return }
    $item = $form.Tag.Cards.SelectedItem
    if ($null -eq $item) { return }
    $session = $item.Tag
    if ($Action -eq 'remove') { Remove-NotifierSession -SessionId ([string]$session.session_id) }
    elseif ($session.PSObject.Properties['device'] -and [string]$session.device -ne '') {
        Show-NotifierNotice "Этот сеанс идёт на устройстве «$(Get-NotifierDeviceName ([string]$session.device))»"
        return
    }
    else {
        $result = Invoke-NotifierSessionFocus -Session $session
        if ($result -eq 'unknown') { Show-NotifierNotice 'Окно этого сеанса не определено'; return }
        if ($result -eq 'closed') { Show-NotifierNotice 'Окно сеанса закрыто — сеанс убран из списка' }
    }
    [void](Invoke-NotifierSessionsRefresh)
}

# --- Общие элементы окна ---

function New-NotifierMenu {
    <# .SYNOPSIS Контекстное меню в цветах темы. Items: @(@('Текст', { действие }), '-', …). #>
    param([Parameter(Mandatory = $true)]$Theme, [object[]]$Items = @())
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.Renderer = New-Object ClaudeNotifier.Ui.MenuRenderer($Theme)
    $menu.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
    $menu.ShowImageMargin = $false
    $menu.Padding = New-Object System.Windows.Forms.Padding(0, $Theme.S(4), 0, $Theme.S(4))
    $menu.add_Opened({ [ClaudeNotifier.Ui.Native]::RoundPopup($this.Handle) })
    foreach ($i in $Items) {
        if ($i -is [string] -and $i -eq '-') { [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)); continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem $i[0]
        $mi.Padding = New-Object System.Windows.Forms.Padding($Theme.S(8), $Theme.S(5), $Theme.S(8), $Theme.S(5))
        if ($i[1]) { $mi.add_Click($i[1]) }
        [void]$menu.Items.Add($mi)
    }
    return $menu
}

function New-NotifierLabel {
    <# .SYNOPSIS Подпись в цветах темы фиксированной ширины; высота — по тексту. #>
    param(
        [Parameter(Mandatory = $true)]$Theme,
        [AllowEmptyString()][string]$Text = '',
        [System.Drawing.Font]$Font,
        [int]$Width = 0,
        [switch]$Muted,
        [switch]$Wrap,
        [string]$Dot
    )
    $l = New-Object ClaudeNotifier.Ui.Label2
    $l.ApplyTheme($Theme)
    if ($Font) { $l.Font = $Font }
    $l.MutedText = [bool]$Muted
    $l.Wrap = [bool]$Wrap
    if ($Dot) { $l.DotState = $Dot }
    $l.Text = $Text
    if ($Width -le 0) { $Width = $l.GetPreferredSize([System.Drawing.Size]::Empty).Width + 2 }
    $l.Size = New-Object System.Drawing.Size($Width, ($l.GetPreferredSize((New-Object System.Drawing.Size($Width, 0))).Height + 2))
    return $l
}

function New-NotifierButton {
    <# .SYNOPSIS Кнопка-капсула: -Primary (акцент), -Plain (текст акцента), -Destructive (красный текст) или обычная. #>
    param([Parameter(Mandatory = $true)]$Theme, [Parameter(Mandatory = $true)][string]$Text, [switch]$Primary, [switch]$Plain, [switch]$Destructive, [scriptblock]$OnClick, [int]$Width = 0)
    $b = New-Object ClaudeNotifier.Ui.Button2
    $style = 'secondary'
    if ($Primary) { $style = 'primary' } elseif ($Plain) { $style = 'plain' } elseif ($Destructive) { $style = 'destructive' }
    $b.Style = $style
    $b.ApplyTheme($Theme)
    $b.Text = $Text
    $b.FitWidth()
    if ($Width -gt 0) { $b.Width = $Width }
    if ($OnClick) { $b.add_Click($OnClick) }
    return $b
}

function New-NotifierForm {
    <# .SYNOPSIS Окно в цветах темы: фон, заголовок Windows 11 в тон, иконка-точка. #>
    param([Parameter(Mandatory = $true)]$Theme, [AllowEmptyString()][string]$Title = '', [int]$Width = 520, [int]$Height = 600)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.BackColor = $Theme.Window
    $f.ForeColor = $Theme.Text
    $f.Font = [ClaudeNotifier.Ui.Fonts]::Text(9.5)
    $f.ClientSize = New-Object System.Drawing.Size($Theme.S($Width), $Theme.S($Height))
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    try { $f.Icon = Get-NotifierDotIcon 'working' } catch { }
    $f.Tag = @{ Theme = $Theme }
    $f.add_HandleCreated({ [ClaudeNotifier.Ui.Native]::StyleWindow($this.Handle, $this.Tag.Theme) })
    [ClaudeNotifier.Ui.Native]::FadeIn($f, 180)   # окно открывают редко — плавное появление уместно
    return $f
}

function Show-NotifierDialog {
    <#
    .SYNOPSIS
    Диалог в стиле алерта Apple: заголовок и текст по центру, необязательное поле ввода,
    кнопки одинаковой ширины (отмена слева, действие справа). -Destructive — действие красным.
    Возвращает @{ Ok = $true/$false; Value = <текст поля> }.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [AllowEmptyString()][string]$Message = '',
        [string]$Primary = 'OK',
        [string]$Secondary = 'Отмена',
        $InputValue = $null,   # без типа: [string] превратил бы $null в '' и показал бы поле ввода
        [switch]$Destructive,
        [System.Windows.Forms.IWin32Window]$Owner
    )
    $t = Get-NotifierTheme
    $w = 360
    $f = New-NotifierForm -Theme $t -Title '' -Width $w -Height 200
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $f.MaximizeBox = $false; $f.MinimizeBox = $false; $f.ShowInTaskbar = $false; $f.ShowIcon = $false
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $pad = $t.S(24); $inner = $t.S($w) - 2 * $pad
    $y = $t.S(8)
    $head = New-NotifierLabel -Theme $t -Text $Title -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(12)) -Width $inner -Wrap
    $head.Center = $true
    $head.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($head); $y += $head.Height + $t.S(6)
    if ($Message) {
        $msg = New-NotifierLabel -Theme $t -Text $Message -Width $inner -Wrap -Muted
        $msg.Center = $true
        $msg.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($msg); $y += $msg.Height + $t.S(4)
    }
    $box = $null
    if ($null -ne $InputValue) {
        $y += $t.S(10)
        $box = New-Object System.Windows.Forms.TextBox
        $box.Text = [string]$InputValue
        $box.Font = [ClaudeNotifier.Ui.Fonts]::Text(11)
        $box.BorderStyle = [System.Windows.Forms.BorderStyle]::None
        $box.BackColor = $t.Surface; $box.ForeColor = $t.Text
        # Поле в скруглённой «капсуле»: TextBox без рамки внутри панели, которая рисует фон.
        $field = New-Object System.Windows.Forms.Panel
        $field.Size = New-Object System.Drawing.Size($inner, $t.S(38))
        $field.BackColor = $t.Window
        $field.Tag = $t
        $field.add_Paint({
                param($sender, $e)
                $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
                [ClaudeNotifier.Ui.Draw]::Card($e.Graphics, (New-Object System.Drawing.RectangleF(0.5, 0.5, ($sender.Width - 1), ($sender.Height - 1))), $sender.Tag.S(9), $sender.Tag.Surface, $sender.Tag.Border)
            })
        $box.Width = $inner - $t.S(24)
        $box.Location = New-Object System.Drawing.Point($t.S(12), [int](($field.Height - $box.PreferredHeight) / 2))
        $field.Controls.Add($box)
        $field.Location = New-Object System.Drawing.Point($pad, $y); $f.Controls.Add($field); $y += $field.Height
    }
    $y += $t.S(20)
    $gap = $t.S(10)
    $btnW = $inner
    if ($Secondary) { $btnW = [int](($inner - $gap) / 2) }
    if ($Destructive) { $ok = New-NotifierButton -Theme $t -Text $Primary -Destructive -Width $btnW }
    else { $ok = New-NotifierButton -Theme $t -Text $Primary -Primary -Width $btnW }
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $ok.Location = New-Object System.Drawing.Point(($pad + $inner - $ok.Width), $y)
    $f.Controls.Add($ok)
    if ($Secondary) {
        $cancel = New-NotifierButton -Theme $t -Text $Secondary -Width $btnW
        $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $cancel.Location = New-Object System.Drawing.Point($pad, $y)
        $f.Controls.Add($cancel)
        $f.CancelButton = $cancel
    }
    $f.AcceptButton = $ok
    $f.ClientSize = New-Object System.Drawing.Size($t.S($w), ($y + $ok.Height + $t.S(20)))
    $f.Tag.Box = $box
    if ($box) { $f.add_Shown({ $this.Tag.Box.SelectAll(); [void]$this.Tag.Box.Focus() }) }
    try {
        $result = $f.ShowDialog($Owner)
        $value = $null
        if ($box) { $value = $box.Text }
        return @{ Ok = ($result -eq [System.Windows.Forms.DialogResult]::OK); Value = $value }
    }
    finally { $f.Dispose() }
}

# --- Окно «Сеансы» ---

function New-NotifierSessionsForm {
    <# .SYNOPSIS Окно: заголовок, подзаголовок, вкладки «Сеансы» / «Устройства», карточки. #>
    $t = Get-NotifierTheme
    $form = New-NotifierForm -Theme $t -Title 'Claude Notifier' -Width 560 -Height 600
    $form.MinimumSize = New-Object System.Drawing.Size($t.S(420), $t.S(380))
    $form.Padding = New-Object System.Windows.Forms.Padding($t.S(20), $t.S(10), $t.S(20), $t.S(16))

    $header = New-Object System.Windows.Forms.Panel
    $header.Dock = [System.Windows.Forms.DockStyle]::Top
    $header.Height = $t.S(82)
    $header.BackColor = $t.Window
    $header.Padding = New-Object System.Windows.Forms.Padding($t.S(4), 0, 0, 0)
    # Крупный заголовок (Large Title) и подзаголовок — иерархия весом, размером и цветом.
    $title = New-NotifierLabel -Theme $t -Text 'Сеансы' -Font ([ClaudeNotifier.Ui.Fonts]::Display(22)) -Width $t.S(480)
    $title.Location = New-Object System.Drawing.Point($t.S(4), 0)
    $subtitle = New-NotifierLabel -Theme $t -Text '' -Muted -Width $t.S(480)
    $subtitle.Location = New-Object System.Drawing.Point($t.S(4), ($title.Bottom))
    $subtitle.Anchor = 'Top, Left, Right'
    $header.Controls.Add($title)
    $header.Controls.Add($subtitle)

    $tabs = New-Object ClaudeNotifier.Ui.Tabs
    $tabs.ApplyTheme($t)
    $tabs.Dock = [System.Windows.Forms.DockStyle]::Top
    $tabs.SetTitles('Сеансы', 'Устройства')

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = [System.Windows.Forms.DockStyle]::Top
    $spacer.Height = $t.S(18)
    $spacer.BackColor = $t.Window

    $cards = New-Object ClaudeNotifier.Ui.CardList
    $cards.ApplyTheme($t)
    $cards.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cards.EmptyTitle = 'Активных сеансов нет'
    $cards.EmptyHint = 'Сеанс появится здесь, как только вы начнёте работу в Claude Code — на этом ПК или на подключённом Mac.'
    $menu = New-NotifierMenu -Theme $t -Items @(
        @('Перейти к окну', { Invoke-NotifierSelectedSession -Action focus }),
        @('Убрать из списка', { Invoke-NotifierSelectedSession -Action remove })
    )
    $menu.Items[0].Font = [ClaudeNotifier.Ui.Fonts]::Semibold(9.5)
    $cards.add_ItemAction({
            param($sender, $e)
            switch ($e.Action) {
                'open' { Invoke-NotifierSelectedSession -Action focus }
                'delete' { Invoke-NotifierSelectedSession -Action remove }
                'context' { $script:SessionsForm.Tag.Menu.Show($sender, $e.Location) }
            }
        })

    $pages = New-Object System.Windows.Forms.Panel
    $pages.Dock = [System.Windows.Forms.DockStyle]::Fill
    $pages.BackColor = $t.Window
    $pages.Controls.Add($cards)
    $netUi = $null
    if ($script:Net) {
        $netUi = New-NotifierDevicesPage -Theme $t
        $netUi.Page.Visible = $false
        $pages.Controls.Add($netUi.Page)
    }
    $tabs.add_SelectedIndexChanged({
            $tag = $script:SessionsForm.Tag
            $tag.Cards.Visible = ($this.SelectedIndex -eq 0)
            if ($tag.Net) { $tag.Net.Page.Visible = ($this.SelectedIndex -eq 1) }
            $tag.Title.Text = @('Сеансы', 'Устройства')[$this.SelectedIndex]
            [void](Invoke-NotifierSessionsRefresh)
        })

    # Порядок добавления задаёт порядок пристыковки: последний Top — самый верхний.
    $form.Controls.Add($pages)
    $form.Controls.Add($spacer)
    $form.Controls.Add($tabs)
    $form.Controls.Add($header)
    $form.Tag = @{ Theme = $t; Cards = $cards; Title = $title; Subtitle = $subtitle; Tabs = $tabs; Net = $netUi; Menu = $menu }
    $form.add_FormClosed({ $script:SessionsForm = $null })
    $form.add_Shown({ $this.Tag.Cards.Focus() })
    return $form
}

function Show-NotifierSessionsWindow {
    <# .SYNOPSIS Открывает окно «Сеансы» или выводит уже открытое на передний план. -Tab 1 — «Устройства». #>
    param([int]$Tab = -1)
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
        if ($Tab -ge 0) { $script:SessionsForm.Tag.Tabs.SelectedIndex = $Tab }
        $script:SessionsForm.Activate()
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: окно сеансов: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

function Test-SessionsRefreshDue {
    <# .SYNOPSIS Пора ли обновить сеансы (точку в трее и окно): пришли события или прошло RefreshMs. #>
    param([bool]$Dirty, [datetime]$LastRefresh, [datetime]$Now, [int]$RefreshMs = $script:SessionsRefreshMs)
    return $Dirty -or (($Now - $LastRefresh).TotalMilliseconds -ge $RefreshMs)
}
