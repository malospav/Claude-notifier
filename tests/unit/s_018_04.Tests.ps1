BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)

    function New-It([string]$Id, [string]$State, [string[]]$Actions = @()) {
        $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = $Id; $it.Title = $Id; $it.State = $State; $it.Actions = [string[]]$Actions
        return $it
    }
    function Invoke-Draw($Form) {
        $sz = $Form.SizeFor(); $Form.ClientSize = $sz
        $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
        try { $Form.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))) } finally { $bmp.Dispose() }
    }
    function Get-ItemIds($View) {
        $f = $View.GetType().GetField('items', [Reflection.BindingFlags]'NonPublic,Instance')
        return @($f.GetValue($View) | ForEach-Object { $_.Id })
    }
    function New-Root([string]$Name) { $d = Join-Path $TestDrive $Name; New-Item -ItemType Directory $d -Force | Out-Null; return $d }
}

Describe 's_018_04 · скорость шторки' {
    It 'свёрнутая и раскрытая шторка с 5 сеансами рисуются быстро' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $items = for ($i = 0; $i -lt 5; $i++) {
                $it = New-It "s$i" (@('working', 'waiting', 'permission', 'working', 'error')[$i]) @('allow|Разрешить|primary', 'deny|Запретить|destructive')
                $it.Device = "pc$i"; $it   # у каждого устройства свой маскот
            }
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]$items)
            Invoke-Draw $f   # прогрев
            $sw = [Diagnostics.Stopwatch]::StartNew()
            for ($i = 0; $i -lt 10; $i++) { Invoke-Draw $f }
            $collapsed = $sw.ElapsedMilliseconds / 10
            $f.SetExpanded($true, 'home'); $v.Page = 'home'; $v.Morphing = $false
            Invoke-Draw $f
            $sw.Restart()
            for ($i = 0; $i -lt 10; $i++) { Invoke-Draw $f }
            $expanded = $sw.ElapsedMilliseconds / 10
            Write-Host "      notch paint ms: collapsed $collapsed, expanded $expanded"
            $k = if ($env:GITHUB_ACTIONS -eq 'true') { 4 } else { 1 }
            $collapsed | Should -BeLessThan (25 * $k)
            $expanded | Should -BeLessThan (50 * $k)
        }
        finally { $f.Dispose() }
    }
}

Describe 's_018_04 · клавиатура в раскрытой шторке' {
    BeforeEach {
        $script:f = New-Object ClaudeNotifier.Ui.NotchForm
        $script:v = $script:f.View
        $script:got = New-Object System.Collections.ArrayList
        $script:v.add_Command({ param($s, $e) [void]$script:got.Add("$($e.Kind)|$($e.Id)|$($e.Action)") })
        $script:v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@(
                (New-It 'alpha' 'permission' @('allow|Разрешить|primary', 'deny|Запретить|destructive')),
                (New-It 'beta' 'waiting' @('reply-custom|Ответить…|secondary')),
                (New-It 'gamma' 'working')))
        $script:f.SetExpanded($true, 'home'); $script:v.Page = 'home'
        $script:v.SelectedId = 'alpha'
    }
    AfterEach { $script:f.Dispose() }

    It 'стрелки выбирают соседний сеанс по кругу' {
        $v.HandleKey([System.Windows.Forms.Keys]::Right, $false, $false) | Should -Be $true
        $v.SelectedId | Should -Be 'beta'
        $v.HandleKey([System.Windows.Forms.Keys]::Left, $false, $false) | Out-Null
        $v.HandleKey([System.Windows.Forms.Keys]::Left, $false, $false) | Out-Null
        $v.SelectedId | Should -Be 'gamma'
    }

    It 'цифра — кнопка ответа выбранного сеанса' {
        $v.HandleKey([System.Windows.Forms.Keys]::D2, $false, $false) | Should -Be $true
        ($got -join ';') | Should -Match 'alpha\|deny'
    }

    It 'печать на главной — поиск; список и стрелки — по найденному; Esc очищает, затем сворачивает' {
        foreach ($c in 'gam'.ToCharArray()) { $v.HandleChar($c) | Should -Be $true }
        $v.SearchText | Should -Be 'gam'
        $v.Matches((New-It 'gamma' 'working')) | Should -Be $true
        $v.Matches((New-It 'alpha' 'working')) | Should -Be $false
        $v.HandleKey([System.Windows.Forms.Keys]::Right, $false, $false) | Out-Null
        $v.SelectedId | Should -Be 'gamma'
        Invoke-Draw $f
        $v.HandleKey([System.Windows.Forms.Keys]::Back, $false, $false) | Should -Be $true
        $v.SearchText | Should -Be 'ga'
        $v.HandleKey([System.Windows.Forms.Keys]::Escape, $false, $false) | Out-Null
        $v.SearchText | Should -Be ''
        $v.SearchActive | Should -Be $false
        $v.HandleKey([System.Windows.Forms.Keys]::Escape, $false, $false) | Should -Be $true
    }

    It 'Ctrl+F открывает поиск даже без текста' {
        $v.HandleKey([System.Windows.Forms.Keys]::F, $true, $false) | Should -Be $true
        $v.SearchActive | Should -Be $true
        Invoke-Draw $f
    }

    It 'ответ текстом: печать на странице ответа и Enter — команда text с текстом' {
        $v.SelectedId = 'beta'; $v.Page = 'answer'
        foreach ($c in 'да, 2'.ToCharArray()) { [void]$v.HandleChar($c) }
        $v.ReplyText | Should -Be 'да, 2'
        Invoke-Draw $f
        $v.HandleKey([System.Windows.Forms.Keys]::Enter, $false, $false) | Should -Be $true
        ($got -join ';') | Should -Match 'text\|beta\|да, 2'
        $v.ReplyText | Should -Be ''
    }

    It 'свёрнутая шторка клавиши не берёт' {
        $f.SetExpanded($false, 'home')
        $v.HandleChar('x') | Should -Be $false
        $v.HandleKey([System.Windows.Forms.Keys]::Right, $false, $false) | Should -Be $false
    }
}

Describe 's_018_04 · перетаскивание плашек и порядок' {
    It 'MoveItem: плашка встаёт перед другой или в конец' {
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $v = $f.View
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'working'), (New-It 'b' 'working'), (New-It 'c' 'working')))
            $m = $v.GetType().GetMethod('MoveItem', [Reflection.BindingFlags]'NonPublic,Instance')
            [void]$m.Invoke($v, @('c', 'a'))
            (Get-ItemIds $v) -join ',' | Should -Be 'c,a,b'
            [void]$m.Invoke($v, @('c', $null))
            (Get-ItemIds $v) -join ',' | Should -Be 'a,b,c'
        }
        finally { $f.Dispose() }
    }

    It 'порядок сохраняется в notch-order.json и читается снова' {
        $root = New-Root 'order'
        $script:NotchOrder = $null
        (Save-NotifierNotchOrder -Id 'c' -Before 'a' -Current @('a', 'b', 'c') -DataRoot $root) -join ',' | Should -Be 'c,a,b'
        Test-Path (Join-Path $root 'notch-order.json') | Should -Be $true
        $script:NotchOrder = $null
        (Get-NotifierNotchOrder -DataRoot $root) -join ',' | Should -Be 'c,a,b'
        (Save-NotifierNotchOrder -Id 'a' -Before '' -Current @('c', 'a', 'b') -DataRoot $root) -join ',' | Should -Be 'c,b,a'
        $script:NotchOrder = $null
    }
}

Describe 's_018_04 · история за сегодня' {
    It 'события сегодня — строки-ссылки новые сверху; вчерашние не попадают' {
        $root = New-Root 'hist'
        $now = [DateTime]::Now
        $mk = { param($sid, $type, [datetime]$at) [pscustomobject]@{ v = 1; id = [guid]::NewGuid().ToString(); ts = $at.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"); type = $type; session_id = $sid; title = "T $sid"; preview = 'текст' } }
        [void](Add-NotifierHistory -Event (& $mk 'old' 'done' $now.AddDays(-1)) -DataRoot $root)
        [void](Add-NotifierHistory -Event (& $mk 's1' 'done' $now.Date.AddMinutes(1)) -DataRoot $root)
        [void](Add-NotifierHistory -Event (& $mk 's2' 'permission' $now.Date.AddMinutes(2)) -DataRoot $root)
        $rows = @(Get-NotifierNotchHistoryRows -Now $now -DataRoot $root)
        $rows[0].Kind | Should -Be 'header'
        @($rows | Where-Object Kind -eq 'link' | ForEach-Object Key) -join ',' | Should -Be 'hist:s2,hist:s1'
        $rows[1].Dot | Should -Be 'permission'
        $rows[1].Subtitle | Should -Match '^Запрос'
    }

    It 'событий нет — пояснение' {
        $rows = @(Get-NotifierNotchHistoryRows -DataRoot (New-Root 'hist-empty'))
        $rows.Count | Should -Be 1
        $rows[0].Kind | Should -Be 'note'
    }
}

Describe 's_018_04 · вид: светлая тема, размер, звуки' {
    It 'светлая палитра: серые инвертируются, цветные акценты остаются' {
        $pal = [ClaudeNotifier.Ui.NotchView].GetMethod('Pal', [Reflection.BindingFlags]'NonPublic,Static')
        try {
            [ClaudeNotifier.Ui.NotchView]::Light = $false
            $pal.Invoke($null, @(0x1C1C1E)).R | Should -BeLessThan 60
            [ClaudeNotifier.Ui.NotchView]::Light = $true
            $pal.Invoke($null, @(0x1C1C1E)).R | Should -BeGreaterThan 200
            $green = $pal.Invoke($null, @(0x30D158))
            "$($green.R),$($green.G),$($green.B)" | Should -Be '48,209,88'
            $f = New-Object ClaudeNotifier.Ui.NotchForm
            try { $f.View.SetItems([ClaudeNotifier.Ui.NotchItem[]]@((New-It 'a' 'waiting'))); $f.SetExpanded($true, 'home'); Invoke-Draw $f } finally { $f.Dispose() }
        }
        finally { [ClaudeNotifier.Ui.NotchView]::Light = $false }
    }

    It 'настройки: тема и размер проверяются, по умолчанию — тёмная, обычный, уведомления в шторке' {
        $root = New-Root 'cfg'
        $c = Get-NotifierConfig -DataRoot $root
        $c.notch.theme | Should -Be 'dark'
        $c.notch.size | Should -Be 'normal'
        $c.notch.inline | Should -Be $true
        '{ "notch": { "theme": "light", "size": "large", "inline": false } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $c = Get-NotifierConfig -DataRoot $root
        "$($c.notch.theme) $($c.notch.size) $($c.notch.inline)" | Should -Be 'light large False'
        '{ "notch": { "theme": "purple", "size": 7 } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $c = Get-NotifierConfig -DataRoot $root
        "$($c.notch.theme) $($c.notch.size)" | Should -Be 'dark normal'
        Test-NotifierNotchLight -Config @{ notch = @{ theme = 'light' } } | Should -Be $true
        Test-NotifierNotchLight -Config @{ notch = @{ theme = 'dark' } } | Should -Be $false
    }

    It 'звуки «Маскот»: четыре разных WAV, сохраняются один раз' {
        $w = @{}
        foreach ($t in 'done', 'permission', 'error', 'limit') {
            $b = [ClaudeNotifier.Ui.MascotSound]::EventWave($t)
            [Text.Encoding]::ASCII.GetString($b, 0, 4) | Should -Be 'RIFF'
            $b.Length | Should -BeGreaterThan 10000
            $w[$t] = [Convert]::ToBase64String($b)
        }
        @($w.Values | Sort-Object -Unique).Count | Should -Be 4
        $root = New-Root 'snd'
        $files = Install-NotifierMascotSounds -DataRoot $root
        $files.Count | Should -Be 4
        Test-Path $files['permission'] | Should -Be $true
        $t0 = (Get-Item $files['done']).LastWriteTimeUtc
        Start-Sleep -Milliseconds 20
        [void](Install-NotifierMascotSounds -DataRoot $root)
        (Get-Item $files['done']).LastWriteTimeUtc | Should -Be $t0
    }
}

Describe 's_018_04 · уведомления в шторке' {
    It 'только когда включено, шторка работает, вы за ПК и это важное событие' {
        Mock Test-NotifierNotchActive { $true }
        $cfg = @{ notch = @{ enabled = $true; inline = $true } }
        Test-NotifierNotchInline -Event @{ type = 'done' } -Config $cfg -IdleSeconds 5 | Should -Be $true
        Test-NotifierNotchInline -Event @{ type = 'done' } -Config $cfg -IdleSeconds 120 | Should -Be $false
        Test-NotifierNotchInline -Event @{ type = 'session' } -Config $cfg | Should -Be $false
        Test-NotifierNotchInline -Event @{ type = 'done' } -Config @{ notch = @{ enabled = $true; inline = $false } } | Should -Be $false
        Mock Test-NotifierNotchActive { $false }
        Test-NotifierNotchInline -Event @{ type = 'done' } -Config $cfg | Should -Be $false
    }

    It 'команды шторки будят трей сразу; повторные — одним вызовом' {
        $w = New-Object ClaudeNotifier.Ui.TrayWaker
        try {
            $w.CreateControl()
            $script:woke = 0
            $w.add_Woke({ $script:woke++ })
            $w.Wake(); $w.Wake(); $w.Wake()
            [System.Windows.Forms.Application]::DoEvents()
            $script:woke | Should -Be 1
            $w.Wake(); [System.Windows.Forms.Application]::DoEvents()
            $w.Wakes | Should -Be 2
        }
        finally { $w.Dispose() }
    }
}

Describe 's_018_04 · экспорт настроек с дружбой и порядком' {
    It 'дружба с маскотом и порядок плашек переносятся на другой ПК' {
        $a = New-Root 'exp-a'; $b = New-Root 'exp-b'
        '{ "previewLength": 300 }' | Set-Content (Join-Path $a 'config.json') -Encoding UTF8
        '{"affection":42.5,"lastPet":123}' | Set-Content (Join-Path $a 'friendship.json') -Encoding UTF8
        '["s2","s1"]' | Set-Content (Join-Path $a 'notch-order.json') -Encoding UTF8
        $file = Join-Path $TestDrive 'export.json'
        Export-NotifierSettings -Path $file -DataRoot $a
        Import-NotifierSettings -Path $file -DataRoot $b | Should -Be ''
        $fr = Get-Content (Join-Path $b 'friendship.json') -Raw | ConvertFrom-Json
        $fr.affection | Should -Be 42.5
        $fr.lastPet | Should -Be 123
        $ord = Get-Content (Join-Path $b 'notch-order.json') -Raw | ConvertFrom-Json
        (@($ord) -join ',') | Should -Be 's2,s1'
        $cfg = Get-Content (Join-Path $b 'config.json') -Raw | ConvertFrom-Json
        $cfg.PSObject.Properties['$extras'] | Should -BeNullOrEmpty
        $cfg.previewLength | Should -Be 300
        $script:NotchOrder = $null
    }
}

Describe 's_018_04 · быстрый JSON моста' {
    It 'разбор совпадает с ConvertFrom-Json: <Json>' -TestCases @(
        @{ Json = '{ "a": 1, "b": "x\"y\\z\n", "c": [1, 2.5, true, false, null], "d": { "e": -3 } }' },
        @{ Json = '{"big": 5000000000, "f": 1e3, "u": "\u041f\u0440\u0438", "empty": {}, "arr": []}' },
        @{ Json = '{"list": [1, "two", {"three": 3}, [4, 5]]}' },
        @{ Json = '{"session_id":"s1","cwd":"C:\\dev\\proj","last_assistant_message":"ok"}' }
    ) {
        param($Json)
        $fast = [ClaudeNotifier.JsonLite]::Parse($Json)
        $std = ConvertFrom-Json -InputObject $Json
        (ConvertTo-Json -InputObject $fast -Depth 6 -Compress) | Should -Be (ConvertTo-Json -InputObject $std -Depth 6 -Compress)
    }

    It 'неверный JSON — исключение, как у ConvertFrom-Json' {
        { ConvertFrom-NotifierJson -InputObject '{ "a": ' } | Should -Throw
        { ConvertFrom-NotifierJson -InputObject '{ "a": 1 } x' } | Should -Throw
    }

    It 'запись: событие → JSON, который читается обратно так же' {
        $e = [pscustomobject][ordered]@{ v = 1; type = 'done'; title = "Готово $([char]0x00B7) proj"; window = @{ hwnd = [long]123 }; stats = [pscustomobject]@{ tokens = 10; cost = 0.25 }; helper = $true; none = $null }
        $j = ConvertTo-NotifierJson -InputObject $e
        $back = ConvertFrom-Json -InputObject $j
        (ConvertTo-Json $back -Depth 5 -Compress) | Should -Be (ConvertTo-Json (ConvertFrom-Json (ConvertTo-Json $e -Depth 5 -Compress)) -Depth 5 -Compress)
    }
}
