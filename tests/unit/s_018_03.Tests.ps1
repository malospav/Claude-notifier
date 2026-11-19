BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
    # Анимации проверяются при включённых эффектах — и на машинах, где они в Windows выключены (GitHub Actions).
    [ClaudeNotifier.Ui.Motion]::Force($true)

    function New-It([string]$Id, [string]$State) { $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = $Id; $it.Title = $Id; $it.State = $State; return $it }
    function Invoke-Draw($Form) {
        $sz = $Form.SizeFor(); $Form.ClientSize = $sz
        $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
        try { $Form.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))) } finally { $bmp.Dispose() }
    }
    function Get-Frame([string]$Kind, $Mood) {
        $b = New-Object System.Drawing.Bitmap 120, 100
        $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::Black)
        [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(20, 20, 80, 64)), $Kind, 'waiting', 0, 1, $false, $Mood)
        $g.Dispose(); return $b
    }
}

AfterAll { [ClaudeNotifier.Ui.Motion]::Force($null) }

Describe 's_018_03 · пружины, сжатие, запаздывание' {
    It 'пружина: перелетает цель и успокаивается; по реальному времени одинаково при 10 и 60 кадрах' {
        $a = New-Object ClaudeNotifier.Ui.Spring 1; $a.Kick(-3)
        $min = 1.0
        for ($i = 0; $i -lt 60; $i++) { $a.Step(1 / 60, 1, 220, 0.3); $min = [Math]::Min($min, $a.X) }
        ($min -lt 0.95) | Should -Be $true            # присел
        $b = New-Object ClaudeNotifier.Ui.Spring 1; $b.Kick(-3)
        for ($i = 0; $i -lt 10; $i++) { $b.Step(1 / 10, 1, 220, 0.3) }
        [Math]::Abs($a.X - $b.X) | Should -BeLessThan 0.01
        for ($i = 0; $i -lt 120; $i++) { $a.Step(1 / 60, 1, 220, 0.3) }
        $a.Settled(1) | Should -Be $true
        [ClaudeNotifier.Ui.MascotMotion]::EaseOutBack(1) | Should -Be 1
        ([ClaudeNotifier.Ui.MascotMotion]::EaseOutBack(0.7) -gt 1) | Should -Be $true   # перелёт
    }

    It 'сжатие, запаздывание верха, наклон, подъём и брови меняют кадр; без них — как без настроения' {
        $plain = Get-Frame 'flatsphynx' (New-Object ClaudeNotifier.Ui.CatMood)
        try {
            $none = Get-Frame 'flatsphynx' $null
            try { (Compare-NotifierBitmap -A $plain -B $none) | Should -Be 0 } finally { $none.Dispose() }
            foreach ($set in @({ param($m) $m.SquashY = 0.8 }, { param($m) $m.Shear = 0.2 }, { param($m) $m.Lean = 12 }, { param($m) $m.Lift = 0.15 }, { param($m) $m.Brow = 1 })) {
                $m = New-Object ClaudeNotifier.Ui.CatMood; & $set $m
                $f = Get-Frame 'flatsphynx' $m
                try { (Compare-NotifierBitmap -A $f -B $plain -Threshold 20) | Should -BeGreaterThan 0 } finally { $f.Dispose() }
            }
        }
        finally { $plain.Dispose() }
    }

    It 'моргание живое: разные промежутки, иногда двойное; без анимации не моргает' {
        $starts = New-Object System.Collections.ArrayList
        $prev = $false; $doubles = 0; $lastEnd = -10.0
        for ($i = 0; $i -lt 6000; $i++) {
            $t = $i / 100.0
            $b = [ClaudeNotifier.Ui.FlatFxProbe]::Blink($t, 9)
            if ($b -and -not $prev) { if ($t - $lastEnd -lt 0.3) { $doubles++ } else { [void]$starts.Add($t) } }
            if (-not $b -and $prev) { $lastEnd = $t }
            $prev = $b
        }
        ($starts.Count -ge 8 -and $starts.Count -le 18) | Should -Be $true -Because "морганий за минуту: $($starts.Count)"
        $gaps = @(for ($i = 1; $i -lt $starts.Count; $i++) { [Math]::Round($starts[$i] - $starts[$i - 1], 1) })
        (@($gaps | Sort-Object -Unique).Count -gt 2) | Should -Be $true   # промежутки разные
        ($doubles -ge 1) | Should -Be $true
        [ClaudeNotifier.Ui.FlatFxProbe]::BlinkStill(1.0, 5) | Should -Be $false
    }
}

Describe 's_018_03 · детали: моргание, тень, глаза' {
    It 'моргание: веки сначала прищурены, потом закрыты, потом снова прищур' {
        $seen = @()
        for ($i = 0; $i -lt 3000; $i++) { $e = [ClaudeNotifier.Ui.FlatFxProbe]::BlinkEye($i / 200.0, 9); if ($e -and ($seen.Count -eq 0 -or $seen[-1] -ne $e)) { $seen += $e } }
        ($seen -join ',') | Should -Match '^squint,closed,squint'
    }

    It 'тень остаётся на земле, когда маскот поднимается (и становится меньше)' {
        function Get-ShadowRow($Lift) {
            $b = New-Object System.Drawing.Bitmap 140, 140
            $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::FromArgb(120, 120, 120))
            $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Lift = $Lift
            [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(20, 40, 100, 80)), 'penguin', 'waiting', 0, 1, $false, $m)
            $g.Dispose()
            # Ряд земли: тёмные пиксели тени на сером фоне.
            $y = [int](120 - 80 * 0.07); $dark = 0
            for ($x = 0; $x -lt 140; $x++) { $c = $b.GetPixel($x, $y); if ($c.R -lt 116 -and $c.R -gt 30 -and [Math]::Abs($c.R - $c.G) -lt 5 -and [Math]::Abs($c.R - $c.B) -lt 5) { $dark++ } }   # серые — тень (тело синее, лапки оранжевые)
            $b.Dispose(); return $dark
        }
        $low = Get-ShadowRow 0.2    # оба — в воздухе: лапки не закрывают тень
        $high = Get-ShadowRow 0.5
        ($low -gt 10) | Should -Be $true
        ($high -gt 3) | Should -Be $true -Because 'тень осталась на земле'
        ($high -lt $low) | Should -Be $true -Because 'в воздухе тень меньше'
    }

    It 'новые глаза «улыбка» и «широкие» рисуются у всех маскотов' {
        $b = New-Object System.Drawing.Bitmap 120, 100
        $g = [System.Drawing.Graphics]::FromImage($b)
        try {
            foreach ($k in [ClaudeNotifier.Ui.Mascot]::Kinds) {
                foreach ($e in @('smile', 'wide')) {
                    $m = New-Object ClaudeNotifier.Ui.CatMood; $m.EyesOverride = $e
                    [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(10, 10, 100, 80)), $k, 'waiting', 0, 1, $false, $m)
                }
            }
        }
        finally { $g.Dispose(); $b.Dispose() }
    }
}

Describe 's_018_03 · маскоты в шторке: переход, появление, уход, соседи, перелёт' {
    It 'смена статуса — плавный переход; новый — выпрыгивает, соседи удивляются; ушедшему машут' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'working'), (New-It 'b' 'waiting')))
            Invoke-Draw $f
            $v.MotionCount | Should -Be 2
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting'), (New-It 'b' 'waiting'), (New-It 'c' 'working')))
            $v.ReactionOf('a') | Should -Be 'notice'
            $v.ReactionOf('c') | Should -Be $null
            Invoke-Draw $f   # во время перехода (два кадра смешиваются) и выпрыгивания — рисуется
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting'), (New-It 'c' 'working')))
            $v.ReactionOf('a') | Should -Be 'wave'
            $v.LeavingCount | Should -Be 1
            Invoke-Draw $f
            [ClaudeNotifier.Ui.NotchView]::LeaveSeconds = 0
            Start-Sleep -Milliseconds 30
            [void]$v.GetType().GetMethod('StepMotions', [Reflection.BindingFlags]'NonPublic,Instance').Invoke($v, @())
            $v.LeavingCount | Should -Be 0
        }
        finally { [ClaudeNotifier.Ui.NotchView]::LeaveSeconds = 0.6; $f.Dispose() }
    }

    It 'раскрытие: главный маскот перелетает из свёрнутой; пружины успокаиваются — 60 кадров только пока движется' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting')))
            $f.SetExpanded($false, $null); Invoke-Draw $f
            $f.SetExpanded($true, 'home'); $v.Page = 'home'; Invoke-Draw $f
            $v.FlyActive | Should -Be $true
            $step = $v.GetType().GetMethod('StepMotions', [Reflection.BindingFlags]'NonPublic,Instance')
            [ClaudeNotifier.Ui.NotchView]::FlySeconds = 0
            $busy = $true
            for ($i = 0; $i -lt 100 -and $busy; $i++) { Start-Sleep -Milliseconds 20; $busy = [bool]$step.Invoke($v, @()) }
            $busy | Should -Be $false
        }
        finally { [ClaudeNotifier.Ui.NotchView]::FlySeconds = 0.45; $f.Dispose() }
    }

    It 'сценки в простое: долго ждёт — потягивается, чешет ухо, дремлет или прыгает к соседу (кадры рисуются)' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            [ClaudeNotifier.Ui.NotchView]::IdleSceneAfter = 0
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting'), (New-It 'b' 'waiting')))
            for ($i = 0; $i -lt 5; $i++) { Invoke-Draw $f; Start-Sleep -Milliseconds 40 }
        }
        finally { [ClaudeNotifier.Ui.NotchView]::IdleSceneAfter = 40; $f.Dispose() }
    }
}

Describe 's_018_03 · украшения держатся на голове' {
    BeforeAll {
        # Середина синих пикселей ночного колпака (по высоте) — где колпак на картинке.
        function Get-CapY([string]$Kind, [double]$Lift, [double]$Lean) {
            $b = New-Object System.Drawing.Bitmap 160, 160
            $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::Black)
            $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Play = $true; $m.Outfit = 'night'; $m.Lift = $Lift; $m.Lean = $Lean
            [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(30, 70, 100, 80)), $Kind, 'waiting', 0, 1, $false, $m)
            $g.Dispose()
            $sum = 0.0; $n = 0
            for ($y = 0; $y -lt 160; $y += 2) { for ($x = 0; $x -lt 160; $x += 2) { $c = $b.GetPixel($x, $y); if ($c.B -gt 150 -and $c.R -lt 110 -and $c.G -lt 150) { $sum += $y; $n++ } } }
            $b.Dispose()
            if ($n -eq 0) { return -1 }
            return $sum / $n
        }
    }

    It 'колпак у <Kind> поднимается вместе с головой' -TestCases @(@{ Kind = 'penguin' }, @{ Kind = 'kitty' }, @{ Kind = 'bee' }, @{ Kind = 'mochi' }, @{ Kind = 'dino' }) {
        param($Kind)
        $y0 = Get-CapY $Kind 0 0
        $y1 = Get-CapY $Kind 0.25 0
        ($y0 -gt 0) | Should -Be $true -Because 'колпак нарисован'
        # Подъём на 0,25 высоты (80 px) — колпак выше примерно на 20 px.
        ($y0 - $y1) | Should -BeGreaterThan 12
    }
}

Describe 's_018_03 · отклик интерфейса шторки' {
    It 'ответ кнопкой — сразу «✓»; смена страницы — переход 0 → 1; тумблер едет, а не перескакивает' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'a'; $it.State = 'permission'; $it.Actions = [string[]]@('allow|Разрешить|primary')
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $v.ClickArea('act:allow', [System.Drawing.Point]::Empty)
            $v.Sent('allow') | Should -Be $true
            $v.Sent('deny') | Should -Be $false
            $tick = $v.GetType().GetMethod('UiTick', [Reflection.BindingFlags]'NonPublic,Instance')
            $f.SetExpanded($true, 'home'); $v.Page = 'home'; Invoke-Draw $f
            $v.SetPage('settings')
            $v.SetRows('settings', [ClaudeNotifier.Ui.NotchRow[]]@((New-NotifierNotchRow header -Title 'Шторка'), (New-NotifierNotchRow switch 'notch.stats' 'Загрузка ПК' 'x' -On $false)))
            Invoke-Draw $f
            if ([ClaudeNotifier.Ui.Motion]::Enabled) {
                ($v.PageProgress -lt 0.5) | Should -Be $true -Because 'переход только начался'
                for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 15; [void]$tick.Invoke($v, @()) }
                Invoke-Draw $f
                ($v.PageProgress -gt 0.95) | Should -Be $true
                $v.SwitchPos('notch.stats') | Should -Be 0
                $v.ClickArea('set:notch.stats', [System.Drawing.Point]::Empty)   # тумблер переключается сразу
                Invoke-Draw $f
                Start-Sleep -Milliseconds 30; [void]$tick.Invoke($v, @())
                $mid = $v.SwitchPos('notch.stats')
                ($mid -gt 0 -and $mid -lt 1) | Should -Be $true -Because "ползунок в пути: $mid"
            }
        }
        finally { $f.Dispose() }
    }
}

Describe 's_018_03 · кнопки не выходят за шторку' {
    It 'пока шторка растягивается под новую страницу, кнопки и строки — внутри её формы (<Page>)' -TestCases @(@{ Page = 'settings' }, @{ Page = 'home' }, @{ Page = 'answer' }) {
        param($Page)
        $script:TrayDataRoot = Join-Path $TestDrive ('w-' + $Page)
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'a'; $it.Title = 'shop'; $it.State = 'permission'
            $it.Actions = [string[]]@('allow|Разрешить|primary', 'always|Всегда|secondary', 'deny|Запретить|destructive')
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $v.SetRows('settings', [ClaudeNotifier.Ui.NotchRow[]]@(Get-NotifierNotchSettingsRows))
            $f.SetExpanded($true, $Page); $v.Page = $Page
            $f.ClientSize = $f.ClientSize
            # Шторка ещё узкая (760), а раскладка новой страницы — шире: середина пружины.
            $full = $v.LayoutExpanded
            $w = [Math]::Min($full.Width, 700)
            $v.Shape = New-Object System.Drawing.RectangleF((($f.ClientSize.Width - $w) / 2), 0, $w, [Math]::Min($full.Height, 300))
            $v.Morphing = $false
            $bmp = New-Object System.Drawing.Bitmap $f.ClientSize.Width, $f.ClientSize.Height
            try { $v.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $bmp.Width, $bmp.Height))) } finally { $bmp.Dispose() }
            $shape = [System.Drawing.Rectangle]::Round($v.Shape); $shape.Inflate(1, 1)
            $out = @($v.HitList() | Where-Object { $_.Value -match '^(act|row|set|page|open|close|sound|section):' -or $_.Value -in @('open', 'close', 'sound') } |
                Where-Object { $r = $_.Key; $r.Width -gt 0 -and ($r.Right -gt $shape.Right -or $r.X -lt $shape.X) })
            ($out | ForEach-Object { $_.Value }) -join ', ' | Should -Be '' -Because 'кнопки по ширине — внутри шторки'
        }
        finally { $f.Dispose() }
    }
}

Describe 's_018_03 · окно «Анимации»' {
    It 'все сценки строятся и рисуются у каждого маскота; окно открывается и листается' {
        $n = [ClaudeNotifier.Ui.MascotPreview]::Scenes.Length
        ($n -ge 20) | Should -Be $true
        $bmp = New-Object System.Drawing.Bitmap 140, 120
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            foreach ($k in [ClaudeNotifier.Ui.Mascot]::Kinds) {
                for ($s = 0; $s -lt $n; $s++) {
                    foreach ($a in @(0.1, 0.9, 2.0)) {
                        $m = New-Object ClaudeNotifier.Ui.CatMood
                        $st = [ClaudeNotifier.Ui.MascotPreview]::Build($s, $a, 1.0, $m)
                        [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(20, 30, 100, 76)), $k, $st, 1.0, 3, $true, $m)
                    }
                }
            }
        }
        finally { $g.Dispose(); $bmp.Dispose() }
        $script:TrayDataRoot = Join-Path $TestDrive 'pv'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $w = Show-NotifierMascotPreview
        try {
            $w.Visible | Should -Be $true
            $w.Text | Should -Match '^Анимации · '
            (Show-NotifierMascotPreview) | Should -Be $w   # второе окно не открывается
            $w.Go(1); $w.Scene | Should -Be 1
            $w.Go(-2); $w.Scene | Should -Be ($n - 1)
            $b2 = New-Object System.Drawing.Bitmap $w.ClientSize.Width, $w.ClientSize.Height
            try { $w.DrawToBitmap($b2, (New-Object System.Drawing.Rectangle(0, 0, $b2.Width, $b2.Height))) } finally { $b2.Dispose() }
        }
        finally { $w.Close(); $w.Dispose() }
        @(Get-NotifierNotchSettingsRows | Where-Object { $_.Key -eq 'mascotPreview' }).Count | Should -Be 1
    }
}
