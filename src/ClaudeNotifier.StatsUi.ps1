<#
.SYNOPSIS
Страница «Статистика»: токены и время работы с Claude за неделю — столбцы по дням и списки по проектам.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Журналы Claude Code читает lib\Activity.psm1
в фоновом runspace (первый раз — пара секунд, дальше — только новые строки); итог показывается, когда готов.
Пересчёт — при открытии страницы и раз в 10 минут, пока она открыта.
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Activity.psm1')

$script:ActivityJob = $null
$script:ActivitySummary = $null
$script:ActivityNextAt = [datetime]::MinValue
$script:ActivityIntervalMin = 10
$script:ActivityProjectsDir = $null   # журналы Claude Code; $null — ~/.claude/projects (тесты задают свою папку)

function Start-NotifierActivityScan {
    <# .SYNOPSIS Запускает пересчёт статистики в фоне (если он ещё не идёт). Возвращает $true, если запущен. #>
    param([string]$DataRoot = $script:TrayDataRoot, [datetime]$Now = [DateTime]::UtcNow)
    if ($script:ActivityJob) { return $false }
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript({
            param($Module, $StateDir, $ProjectsDir)
            Import-Module $Module
            if (-not $ProjectsDir) { $ProjectsDir = Get-NotifierProjectsDir }
            [void](Update-NotifierActivity -ProjectsDir $ProjectsDir -StateDir $StateDir)
            Get-NotifierActivitySummary -StateDir $StateDir
        }).AddArgument((Join-Path $PSScriptRoot 'lib\Activity.psm1')).AddArgument((Join-Path $DataRoot 'activity')).AddArgument($script:ActivityProjectsDir)
    $script:ActivityJob = @{ PS = $ps; Handle = $ps.BeginInvoke(); Started = $Now }
    $script:ActivityNextAt = $Now.AddMinutes($script:ActivityIntervalMin)
    return $true
}

function Complete-NotifierActivityScan {
    <# .SYNOPSIS Пересчёт закончился — забрать итог и обновить страницу. Возвращает $true, если итог получен. #>
    $job = $script:ActivityJob
    if ($null -eq $job -or -not $job.Handle.IsCompleted) { return $false }
    $script:ActivityJob = $null
    $ok = $false
    try {
        $result = @($job.PS.EndInvoke($job.Handle))
        if ($result.Count -gt 0 -and $result[-1].PSObject.Properties['Days']) { $script:ActivitySummary = $result[-1]; $ok = $true }
        foreach ($err in $job.PS.Streams.Error) { Write-NotifierLog -Level WARN -Message "stats: $($err.Exception.Message)" -DataRoot $script:TrayDataRoot }
    }
    catch { Write-NotifierLog -Level WARN -Message "stats: статистика не посчитана: $($_.Exception.Message)" -DataRoot $script:TrayDataRoot }
    finally { $job.PS.Dispose() }
    Update-NotifierStatsView
    return $ok
}

function Test-NotifierStatsVisible {
    if ((Test-NotifierNotchActive) -and $script:NotchExpanded -and $script:NotchPage -eq 'stats') { return $true }
    $form = $script:SessionsForm
    return ($form -and -not $form.IsDisposed -and $form.Visible -and $form.Tag.Stats -and $form.Tag.Tabs.SelectedIndex -eq 3)
}

function Invoke-NotifierActivityTick {
    <# .SYNOPSIS Из таймера трея: забрать готовый итог; пока страница открыта — пересчитывать раз в 10 минут. #>
    param([datetime]$Now = [DateTime]::UtcNow)
    [void](Complete-NotifierActivityScan)
    if ((Test-NotifierStatsVisible) -and $Now -ge $script:ActivityNextAt) { [void](Start-NotifierActivityScan -Now $Now) }
}

function Format-NotifierTokensShort {
    <# .SYNOPSIS Подпись над столбцом: «850», «12 тыс.», «1,4 млн». #>
    param([int64]$N)
    if ($N -lt 1000) { return [string]$N }
    $ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    if ($N -lt 1000000) { return ('{0} тыс.' -f [Math]::Round($N / 1000, [MidpointRounding]::AwayFromZero)) }
    return ('{0} млн' -f ([Math]::Round($N / 1000000, 1, [MidpointRounding]::AwayFromZero)).ToString($ru))
}

function ConvertTo-NotifierStatsChart {
    <# .SYNOPSIS Итог по дням → значения, подписи дней («Пн»… «Сегодня») и подписи над столбцами. #>
    param([Parameter(Mandatory = $true)]$Summary)
    $ru = [Globalization.CultureInfo]::GetCultureInfo('ru-RU')
    $days = @($Summary.Days)
    $values = New-Object 'double[]' $days.Count
    $labels = New-Object 'string[]' $days.Count
    $valueLabels = New-Object 'string[]' $days.Count
    for ($i = 0; $i -lt $days.Count; $i++) {
        $values[$i] = [double]$days[$i].tokens
        $date = [datetime]::ParseExact([string]$days[$i].date, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $name = $date.ToString('ddd', $ru)
        $labels[$i] = $name.Substring(0, 1).ToUpper($ru) + $name.Substring(1)
        if ($i -eq $days.Count - 1) { $labels[$i] = 'Сегодня' }
        $valueLabels[$i] = Format-NotifierTokensShort ([int64]$days[$i].tokens)
    }
    return @{ Values = $values; Labels = $labels; ValueLabels = $valueLabels; Highlight = ($days.Count - 1) }
}

function ConvertTo-NotifierStatsCards {
    <# .SYNOPSIS Списки «Сегодня» и «За 7 дней» по проектам: имя, время и запросы, токены справа. #>
    param([Parameter(Mandatory = $true)]$Summary)
    $list = New-Object 'System.Collections.Generic.List[ClaudeNotifier.Ui.CardItem]'
    foreach ($section in @(@{ Name = 'Сегодня'; Items = @($Summary.Today) }, @{ Name = 'За 7 дней'; Items = @($Summary.Week) })) {
        foreach ($p in $section.Items) {
            if ($null -eq $p) { continue }
            $c = New-Object ClaudeNotifier.Ui.CardItem
            $c.Id = "$($section.Name):$($p.project)"
            $c.Section = $section.Name
            $c.Title = [string]$p.project
            $c.State = 'stat'   # не «working»: у списка статистики точка не пульсирует
            $c.HollowDot = $true
            $c.StateText = Format-NotifierDuration ([int64]$p.seconds)
            $c.Meta = "запросов $([int]$p.prompts)"
            if ($p.PSObject.Properties['cost'] -and [double]$p.cost -gt 0) { $c.Meta += "  $([char]0x00B7)  $(Format-NotifierCost ([double]$p.cost))" }
            $c.Right = "$(Format-NotifierTokensShort ([int64]$p.tokens)) токенов"
            $list.Add($c)
        }
    }
    return , $list
}

function New-NotifierStatsPage {
    <# .SYNOPSIS Страница «Статистика». Возвращает @{ Page; Chart; Summary; SummarySub; List }. #>
    param([Parameter(Mandatory = $true)]$Theme)
    $t = $Theme
    $page = New-Object System.Windows.Forms.Panel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.BackColor = $t.Window

    $card = New-NotifierGroupPanel -Theme $t -Height 214
    $card.Dock = [System.Windows.Forms.DockStyle]::Top
    $card.Padding = New-Object System.Windows.Forms.Padding($t.S(16), $t.S(12), $t.S(16), $t.S(8))
    $summary = New-NotifierLabel -Theme $t -Text 'Считаю…' -Font ([ClaudeNotifier.Ui.Fonts]::Semibold(11)) -Width $t.S(400)
    $summary.BackColor = $t.Surface
    $summary.Dock = [System.Windows.Forms.DockStyle]::Top
    $sub = New-NotifierLabel -Theme $t -Text 'Читаю журналы Claude Code на этом ПК' -Muted -Width $t.S(400)
    $sub.BackColor = $t.Surface
    $sub.Dock = [System.Windows.Forms.DockStyle]::Top
    $gapIn = New-Object System.Windows.Forms.Panel
    $gapIn.Height = $t.S(10); $gapIn.Dock = [System.Windows.Forms.DockStyle]::Top; $gapIn.BackColor = $t.Surface
    $chart = New-Object ClaudeNotifier.Ui.BarChart
    $chart.ApplyTheme($t)
    $chart.BackColor = $t.Surface
    $chart.Dock = [System.Windows.Forms.DockStyle]::Fill
    $card.Controls.Add($chart); $card.Controls.Add($gapIn); $card.Controls.Add($sub); $card.Controls.Add($summary)

    $gap = New-Object System.Windows.Forms.Panel
    $gap.Height = $t.S(18); $gap.Dock = [System.Windows.Forms.DockStyle]::Top; $gap.BackColor = $t.Window

    $list = New-Object ClaudeNotifier.Ui.CardList
    $list.ApplyTheme($t)
    $list.Dock = [System.Windows.Forms.DockStyle]::Fill
    $list.ExpandSelected = $false
    $list.EmptyTitle = 'Пока нет данных'
    $list.EmptyHint = 'Статистика появится после первых ответов Claude на этом ПК.'
    $list.Footer = 'Из журналов Claude Code на этом ПК (CLI и приложение Claude). Токены — ответы Claude; время — пока сеанс активен, паузы дольше 5 минут не считаются. Стоимость — примерная, по ценам API Anthropic (вход, кэш и ответы); с подпиской Claude вы платите по её тарифу.'
    $page.Controls.Add($list); $page.Controls.Add($gap); $page.Controls.Add($card)
    return @{ Page = $page; Chart = $chart; Summary = $summary; SummarySub = $sub; List = $list }
}

function Format-NotifierStatsSubtitle {
    $s = $script:ActivitySummary
    if ($null -eq $s) { return 'Токены и время работы по проектам' }
    $today = @($s.Days)[-1]
    $text = "Сегодня: $(Format-NotifierTokensShort ([int64]$today.tokens)) токенов $([char]0x00B7) $(Format-NotifierDuration ([int64]$today.seconds))"
    if ($today.PSObject.Properties['cost'] -and [double]$today.cost -gt 0) { $text += " $([char]0x00B7) $([char]0x2248) $(Format-NotifierCost ([double]$today.cost))" }
    return $text
}

function Update-NotifierStatsView {
    <# .SYNOPSIS Показывает последний итог на странице «Статистика» (окна или шторки). #>
    if ((Test-NotifierNotchActive) -and $script:NotchPage -eq 'stats') { Push-NotifierNotchPage -Page stats }
    $form = $script:SessionsForm
    if ($null -eq $form -or $form.IsDisposed -or $null -eq $form.Tag.Stats) { return }
    $ui = $form.Tag.Stats
    $s = $script:ActivitySummary
    if ($null -eq $s) {
        $ui.Summary.Text = 'Считаю…'
        $ui.SummarySub.Text = 'Читаю журналы Claude Code на этом ПК'
        return
    }
    $c = ConvertTo-NotifierStatsChart -Summary $s
    $ui.Chart.SetData($c.Values, $c.Labels, $c.ValueLabels, $c.Highlight)
    $ui.Summary.Text = "За 7 дней: $(Format-NotifierTokensShort ([int64]$s.Total.tokens)) токенов $([char]0x00B7) $(Format-NotifierDuration ([int64]$s.Total.seconds))"
    if ($s.Total.PSObject.Properties['cost'] -and [double]$s.Total.cost -gt 0) { $ui.Summary.Text += " $([char]0x00B7) $([char]0x2248) $(Format-NotifierCost ([double]$s.Total.cost))" }
    $ui.SummarySub.Text = "Запросов $([int]$s.Total.prompts) $([char]0x00B7) проектов $(@($s.Week).Count) $([char]0x00B7) обновлено в $($s.Updated.ToString('HH:mm'))"
    $ui.List.SetItems((ConvertTo-NotifierStatsCards -Summary $s))
    if ($form.Tag.Tabs.SelectedIndex -eq 3 -and [datetime]::UtcNow -ge $script:NoticeUntil) { $form.Tag.Subtitle.Text = Format-NotifierStatsSubtitle }
}
