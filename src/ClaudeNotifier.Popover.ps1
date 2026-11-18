<#
.SYNOPSIS
Мини-окно у трея (как меню в строке меню macOS): одиночный щелчок по точке — компактный список сеансов
с кнопками запросов; щелчок мимо закрывает. Двойной щелчок — полное окно «Сеансы».

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Использует CardList и обработчик кнопок из Replies.ps1.
#>

$script:Popover = $null
$script:PopoverClosedAt = [datetime]::MinValue
$script:PopoverNoticeUntil = [datetime]::MinValue
$script:DialogOpen = $false
$script:TrayClickTimer = $null

function Get-NotifierPopoverBounds {
    <#
    .SYNOPSIS
    Место мини-окна: у края рабочей области со стороны панели задач, рядом с курсором (точкой в трее).
    #>
    param([Parameter(Mandatory = $true)][System.Drawing.Size]$Size, [System.Drawing.Point]$Cursor = [System.Windows.Forms.Cursor]::Position, $Theme)
    $screen = [System.Windows.Forms.Screen]::FromPoint($Cursor)
    $wa = $screen.WorkingArea
    $b = $screen.Bounds
    $gap = 12
    if ($Theme) { $gap = $Theme.S(12) }
    $x = [Math]::Min([Math]::Max($wa.Left + $gap, $Cursor.X - [int]($Size.Width / 2)), $wa.Right - $Size.Width - $gap)
    $y = $wa.Bottom - $Size.Height - $gap                                   # панель задач снизу (обычно)
    if ($wa.Top -gt $b.Top) { $y = $wa.Top + $gap }                         # сверху
    elseif ($wa.Left -gt $b.Left) { $x = $wa.Left + $gap; $y = [Math]::Min($Cursor.Y, $wa.Bottom - $Size.Height - $gap) }   # слева
    elseif ($wa.Right -lt $b.Right) { $x = $wa.Right - $Size.Width - $gap; $y = [Math]::Min($Cursor.Y, $wa.Bottom - $Size.Height - $gap) }   # справа
    return New-Object System.Drawing.Rectangle($x, $y, $Size.Width, $Size.Height)
}

function New-NotifierPopover {
    <# .SYNOPSIS Мини-окно: заголовок с итогом, список сеансов, внизу «Открыть окно» и «Настройки». #>
    $t = Get-NotifierTheme
    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $f.ShowInTaskbar = $false
    $f.TopMost = $true
    $f.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $f.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $f.BackColor = $t.Window
    $f.Padding = New-Object System.Windows.Forms.Padding($t.S(12), $t.S(12), $t.S(12), $t.S(10))
    $f.Size = New-Object System.Drawing.Size($t.S(380), $t.S(460))
    $f.Tag = @{ Theme = $t }
    $f.add_HandleCreated({ [ClaudeNotifier.Ui.Native]::StyleWindow($this.Handle, $this.Tag.Theme) })
    [ClaudeNotifier.Ui.Native]::FadeIn($f, 140)

    $head = New-Object System.Windows.Forms.Panel
    $head.Dock = [System.Windows.Forms.DockStyle]::Top
    $head.Height = $t.S(48)
    $head.BackColor = $t.Window
    $title = New-NotifierLabel -Theme $t -Text 'Claude' -Font ([ClaudeNotifier.Ui.Fonts]::Display(14)) -Width $t.S(340)
    $title.Location = New-Object System.Drawing.Point($t.S(4), 0)
    $sub = New-NotifierLabel -Theme $t -Text '' -Muted -Width $t.S(340)
    $sub.Location = New-Object System.Drawing.Point($t.S(4), $title.Bottom)
    $head.Controls.Add($title); $head.Controls.Add($sub)

    $cards = New-Object ClaudeNotifier.Ui.CardList
    $cards.ApplyTheme($t)
    $cards.Dock = [System.Windows.Forms.DockStyle]::Fill
    $cards.EmptyTitle = 'Сеансов нет'
    $cards.EmptyHint = 'Начните работу в Claude Code — сеанс появится здесь.'
    $cards.add_ItemAction({
            param($sender, $e)
            if ($e.Action -like 'act:*' -and (Invoke-NotifierExtraCardAction -Item $e.Item -ActionId $e.Action.Substring(4) -Control $sender -Location $e.Location -Source popover)) {
                [void](Invoke-NotifierSessionsRefresh)
            }
            elseif ($e.Action -like 'act:*') {
                $script:DialogOpen = $true
                try { $notice = Invoke-NotifierCardAction -Item $e.Item -ActionId $e.Action.Substring(4) }
                finally { $script:DialogOpen = $false }
                if ($notice -and $script:Popover -and -not $script:Popover.IsDisposed) { $script:Popover.Tag.Sub.Text = $notice; $script:PopoverNoticeUntil = [datetime]::UtcNow.AddSeconds(4) }
                [void](Invoke-NotifierSessionsRefresh)
            }
            elseif ($e.Action -eq 'open' -and $e.Item.IsGroup) { Switch-NotifierSessionGroup -Item $e.Item; [void](Invoke-NotifierSessionsRefresh) }
            elseif ($e.Action -eq 'open') { Close-NotifierPopover; Show-NotifierSessionsWindow -Tab 0 }
            elseif ($e.Action -eq 'context' -and $e.Item.IsGroup) { }
            elseif ($e.Action -eq 'context') { Show-NotifierSessionMenu -Menu $script:Popover.Tag.Menu -Cards $sender -Item $e.Item -Location $e.Location -Source popover }
        })

    $foot = New-Object System.Windows.Forms.Panel
    $foot.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $foot.Height = $t.S(40)
    $foot.BackColor = $t.Window
    $open = New-NotifierButton -Theme $t -Text 'Открыть окно' -Plain -OnClick { Close-NotifierPopover; Show-NotifierSessionsWindow -Tab 0 }
    $settings = New-NotifierButton -Theme $t -Text 'Настройки' -Plain -OnClick { Close-NotifierPopover; Show-NotifierSessionsWindow -Tab 2 }
    $open.Location = New-Object System.Drawing.Point(0, $t.S(6))
    $settings.Top = $t.S(6)
    $foot.Controls.Add($open); $foot.Controls.Add($settings)
    $foot.add_Layout({ $b = @($this.Controls)[1]; $b.Left = $this.ClientSize.Width - $b.Width })

    $spacer = New-Object System.Windows.Forms.Panel
    $spacer.Dock = [System.Windows.Forms.DockStyle]::Top
    $spacer.Height = $t.S(8)
    $spacer.BackColor = $t.Window

    $usage = New-NotifierUsagePanel -Theme $t
    $f.Controls.Add($cards)
    $f.Controls.Add($usage.Panel)
    $f.Controls.Add($spacer)
    $f.Controls.Add($head)
    $f.Controls.Add($foot)
    $f.Tag = @{ Theme = $t; Cards = $cards; Title = $title; Sub = $sub; Usage = $usage; Menu = (New-NotifierSessionMenu -Theme $t) }
    # Щелчок мимо закрывает (кроме времени, пока открыт диалог ответа).
    $f.add_Deactivate({ if (-not $script:DialogOpen) { Close-NotifierPopover } })
    $f.KeyPreview = $true
    $f.add_KeyDown({ param($s, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { Close-NotifierPopover } })
    return $f
}

function Update-NotifierPopover {
    <# .SYNOPSIS Обновляет список и итог открытого мини-окна. #>
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $p = $script:Popover
    if ($null -eq $p -or $p.IsDisposed) { return }
    $subtitle = Update-NotifierSessionsView -Cards $p.Tag.Cards -Sessions $Sessions
    if ([datetime]::UtcNow -ge $script:PopoverNoticeUntil) { $p.Tag.Sub.Text = $subtitle }
}

function Show-NotifierPopover {
    <# .SYNOPSIS Открывает мини-окно у трея; повторный щелчок по точке закрывает его. -AtTray — у угла панели задач (горячая клавиша). #>
    param([switch]$AtTray)
    if (Test-NotifierNotchActive) { Switch-NotifierNotch; return }   # шторка — главное окно: щелчок по точке раскрывает её
    if ($script:Popover -and -not $script:Popover.IsDisposed) { Close-NotifierPopover; return }
    # Щелчок по точке сначала закрывает окно (Deactivate) — не открывать его тут же снова.
    if (([datetime]::UtcNow - $script:PopoverClosedAt).TotalMilliseconds -lt 300) { return }
    try {
        $script:PopoverNoticeUntil = [datetime]::MinValue
        $script:Popover = New-NotifierPopover
        $live = Invoke-NotifierSessionsRefresh
        $t = $script:Popover.Tag.Theme
        # Высота — по содержимому, в пределах экрана.
        $h = [Math]::Min($t.S(640), [Math]::Max($t.S(360), $t.S(240) + @($live).Count * $t.S(100)))
        $anchor = [System.Windows.Forms.Cursor]::Position
        if ($AtTray) {
            # Курсор может быть где угодно — мини-окно открывается у области уведомлений основного экрана.
            $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
            $anchor = New-Object System.Drawing.Point(($wa.Right - 1), ($wa.Bottom - 1))
        }
        $script:Popover.Bounds = Get-NotifierPopoverBounds -Size (New-Object System.Drawing.Size($t.S(380), $h)) -Cursor $anchor -Theme $t
        [void][ClaudeNotifier.Ui.Native]::AllowForeground()
        $script:Popover.Show()
        Update-NotifierPopover -Sessions $live
        $script:Popover.Activate()
    }
    catch { Write-NotifierLog -Level ERROR -Message "tray: мини-окно: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
}

function Close-NotifierPopover {
    $p = $script:Popover
    $script:Popover = $null
    if ($p -and -not $p.IsDisposed) { $p.Close(); $p.Dispose() }
    $script:PopoverClosedAt = [datetime]::UtcNow
}

function Register-NotifierTrayClicks {
    <#
    .SYNOPSIS
    Одиночный щелчок по точке — мини-окно (после паузы двойного щелчка), двойной — полное окно.
    #>
    param([Parameter(Mandatory = $true)]$Icon)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = [Math]::Max(150, [System.Windows.Forms.SystemInformation]::DoubleClickTime)
    $timer.add_Tick({ $this.Stop(); Show-NotifierPopover })
    $script:TrayClickTimer = $timer
    $Icon.add_MouseClick({
            param($s, $e)
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { $script:TrayClickTimer.Stop(); $script:TrayClickTimer.Start() }
        })
    $Icon.add_MouseDoubleClick({
            param($s, $e)
            $script:TrayClickTimer.Stop()
            if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Close-NotifierPopover; Show-NotifierSessionsWindow -Tab 0 }
        })
}
