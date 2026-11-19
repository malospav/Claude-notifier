BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)

    function New-Item2([string]$Id, [string]$State, [string[]]$Actions = @()) {
        $it = New-Object ClaudeNotifier.Ui.NotchItem
        $it.Id = $Id; $it.Title = $Id; $it.State = $State; $it.Actions = [string[]]$Actions
        return $it
    }
    function Invoke-Draw($Form) {
        $sz = $Form.SizeFor()
        $Form.ClientSize = $sz
        $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
        try { $Form.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))) } finally { $bmp.Dispose() }
    }
}

Describe 's_018_01 · взаимодействие с главным маскотом шторки' {
    AfterEach {
        [ClaudeNotifier.Ui.NotchView]::Affection = 0
        [ClaudeNotifier.Ui.NotchView]::LastPetTicks = 0
        [ClaudeNotifier.Ui.NotchView]::SadAfterHours = 24
    }

    It 'подсказка: статус и сколько длится, последнее действие, контекст; у запроса — как ответить' {
        $now = [DateTimeOffset]::Parse('2026-11-19T10:00:00Z', [Globalization.CultureInfo]::InvariantCulture)
        $s = [pscustomobject]@{ since = '2026-11-19T09:48:00.000Z'; stats = [pscustomobject]@{ lastTool = 'Edit: Notch.cs'; window = 200000; percent = 41 } }
        $h = Get-NotifierNotchHint -Session $s -State 'working' -Title 'shop' -Now $now
        $h | Should -Be "shop: работает 12 мин`nСейчас: Edit: Notch.cs`nКонтекст: 41 %"
        $s.since = '2026-11-19T07:55:00.000Z'
        (Get-NotifierNotchHint -Session $s -State 'waiting' -Now $now) | Should -Be "ждёт ответа 2 ч 5 мин`nКонтекст: 41 %"
        $p = Get-NotifierNotchHint -Session ([pscustomobject]@{ since = '2026-11-19T09:59:40.000Z' }) -State 'permission' -Now $now
        $p | Should -Be "ждёт разрешения меньше минуты`nЩёлкните по маскоту — кнопки ответа прямо здесь"
    }

    It 'дружба: сохраняется в friendship.json и восстанавливается при запуске; мусор не пишется' {
        $root = Join-Path $TestDrive 'fr'
        New-Item -ItemType Directory $root -Force | Out-Null
        Save-NotifierFriendship -Value '42.5|638000000000000000' -DataRoot $root
        $j = Get-Content -LiteralPath (Join-Path $root 'friendship.json') -Raw | ConvertFrom-Json
        $j.affection | Should -Be 42.5
        $j.lastPet | Should -Be 638000000000000000
        Save-NotifierFriendship -Value 'abc' -DataRoot $root
        Save-NotifierFriendship -Value '500|1' -DataRoot $root   # выше 100 — до 100
        (Get-Content -LiteralPath (Join-Path $root 'friendship.json') -Raw | ConvertFrom-Json).affection | Should -Be 100
        Restore-NotifierFriendship -DataRoot $root
        [ClaudeNotifier.Ui.NotchView]::Affection | Should -Be 100
        [ClaudeNotifier.Ui.NotchView]::LastPetTicks | Should -Be 1
    }

    It 'решение у маскота: щелчок по запросу — кнопки ответа в свёрнутой шторке; ответ уходит его сеансу' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-Item2 'w' 'working'), (New-Item2 'p' 'permission' @('allow|Разрешить|primary', 'always|Всегда|secondary', 'deny|Запретить|destructive'))))
            $f.SetExpanded($false, $null)
            $w0 = $f.SizeFor().Width
            Invoke-Draw $f
            ($v.HitIds() -contains 'mascot') | Should -Be $true
            $script:got = @()
            $v.add_Command({ param($s, $e) $script:got += "$($e.Kind)|$($e.Id)|$($e.Action)" })
            $v.ClickArea('mascot', [System.Drawing.Point]::Empty)
            $v.QuickActive | Should -Be $true
            $v.Expanded | Should -Be $false   # шторка не раскрылась
            ($f.SizeFor().Width -ge $w0) | Should -Be $true
            Invoke-Draw $f
            ($v.HitIds() -contains 'qact:allow') | Should -Be $true
            ($v.HitIds() -contains 'qact:deny') | Should -Be $true
            $v.ClickArea('qact:always', [System.Drawing.Point]::Empty)
            $v.QuickActive | Should -Be $false
            $script:got -join ';' | Should -Be 'action|p|always'
        }
        finally { $f.Dispose() }
    }

    It 'тык и разбудить: щелчок по работающему — фирменный номер; по спящему — просыпается' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-Item2 'w' 'working')))
            Invoke-Draw $f
            $v.ClickArea('mascot', [System.Drawing.Point]::Empty)
            $v.Poked | Should -Be $true
            $v.Woken | Should -Be $false
            Invoke-Draw $f
        }
        finally { $f.Dispose() }
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@())
            Invoke-Draw $f
            $v.ClickArea('mascot', [System.Drawing.Point]::Empty)
            $v.Woken | Should -Be $true
            $v.Poked | Should -Be $false
            Invoke-Draw $f
        }
        finally { $f.Dispose() }
    }

    It 'скучает: давно не гладили — тучка; ни разу не гладили — нет' {
        $v = New-Object ClaudeNotifier.Ui.NotchView
        try {
            $v.Missing | Should -Be $false
            [ClaudeNotifier.Ui.NotchView]::LastPetTicks = [DateTime]::UtcNow.AddHours(-30).Ticks
            $v.Missing | Should -Be $true
            [ClaudeNotifier.Ui.NotchView]::SadAfterHours = 48
            $v.Missing | Should -Be $false
        }
        finally { $v.Dispose() }
    }

    It 'реакции рисуются у каждого маскота: гладят, тык, проснулся, злится, скучает, машет' {
        $bmp = New-Object System.Drawing.Bitmap 120, 100
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $r = New-Object System.Drawing.RectangleF(10, 10, 100, 80)
            foreach ($kind in [ClaudeNotifier.Ui.Mascot]::Kinds) {
                foreach ($state in @('working', 'waiting', 'permission', 'none')) {
                    $m = New-Object ClaudeNotifier.Ui.CatMood
                    $m.Play = $true; $m.Pet = 1; $m.PokeAge = 0.5; $m.Startle = 0.7; $m.Grumpy = $true; $m.Sad = $true; $m.Wave = 0.8; $m.Yawn = $true
                    [ClaudeNotifier.Ui.Mascot]::PaintKind($g, $r, $kind, $state, 3.3, 5, $true, $m)
                    $m.Grumpy = $false; $m.Sad = $false; $m.Pet = 0.5
                    [ClaudeNotifier.Ui.Mascot]::PaintKind($g, $r, $kind, $state, 1.1, 5, $true, $m)
                }
            }
        }
        finally { $g.Dispose(); $bmp.Dispose() }
    }
}
