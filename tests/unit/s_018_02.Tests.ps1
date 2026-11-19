BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    . (Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1')
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [void](Import-NotifierUi)
    $script:GoldenDir = Join-Path $repoRoot 'tests\golden'
    function Iso([datetime]$T) { return $T.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture) }
}

Describe 's_018_02 · эталонные картинки маскотов' {
    BeforeDiscovery {
        Import-Module (Join-Path $PSScriptRoot '..\..\src\lib\Ui.psm1')
        [void](Import-NotifierUi)
        $script:Frames = @(foreach ($k in [ClaudeNotifier.Ui.Mascot]::Kinds) { foreach ($s in (Get-NotifierGoldenStates)) { @{ Kind = $k; State = $s } } })
    }

    It 'маскот <Kind> в статусе <State> совпадает с эталоном' -TestCases $script:Frames {
        param($Kind, $State)
        $path = Join-Path $script:GoldenDir "$Kind-$State.png"
        Test-Path -LiteralPath $path | Should -Be $true -Because 'эталоны создаёт tools\Update-MascotGoldens.ps1'
        $gold = New-Object System.Drawing.Bitmap $path
        $now = New-NotifierMascotFrame -Kind $Kind -State $State
        try {
            $diff = Join-Path $TestDrive "$Kind-$State.diff.png"
            $share = Compare-NotifierBitmap -A $now -B $gold -Diff $diff
            # До 1 % пикселей — сглаживание на другой машине; больше — у маскота что-то сдвинулось или пропало.
            $share | Should -BeLessOrEqual 0.01 -Because "отличается $([Math]::Round($share * 100, 1)) % пикселей (картинка отличий: $diff); если рисунок изменён намеренно — tools\Update-MascotGoldens.ps1"
        }
        finally { $gold.Dispose(); $now.Dispose() }
    }

    It 'сравнение замечает поломку: без маскота кадр отличается от эталона' {
        $gold = New-Object System.Drawing.Bitmap (Join-Path $script:GoldenDir 'fox-waiting.png')
        $empty = New-Object System.Drawing.Bitmap $gold.Width, $gold.Height
        $g = [System.Drawing.Graphics]::FromImage($empty); $g.Clear([System.Drawing.Color]::Black); $g.Dispose()
        try { (Compare-NotifierBitmap -A $empty -B $gold) | Should -BeGreaterThan 0.05 }
        finally { $gold.Dispose(); $empty.Dispose() }
    }
}

Describe 's_018_02 · звуки, реакции и наряды маскота' {
    AfterEach {
        [ClaudeNotifier.Ui.MascotSound]::Silent = $false
        [ClaudeNotifier.Ui.MascotSound]::Enabled = $true
        [ClaudeNotifier.Ui.MascotSound]::Muted = $false
        [ClaudeNotifier.Ui.MascotPlay]::FixedNow = $null
    }

    It 'звуки синтезируются корректным WAV; молчат, если выключены или «Без звука»' {
        foreach ($n in @('purr', 'boop', 'boing', 'grr', 'yawn')) {
            $w = [ClaudeNotifier.Ui.MascotSound]::Wave($n, 1.0)
            [Text.Encoding]::ASCII.GetString($w, 0, 4) | Should -Be 'RIFF'
            [Text.Encoding]::ASCII.GetString($w, 8, 4) | Should -Be 'WAVE'
            ($w.Length -gt 2000) | Should -Be $true
        }
        [ClaudeNotifier.Ui.MascotSound]::Pitch('dino') | Should -BeLessThan ([ClaudeNotifier.Ui.MascotSound]::Pitch('bee'))
        [ClaudeNotifier.Ui.MascotSound]::Silent = $true
        [ClaudeNotifier.Ui.MascotSound]::Reset()
        [ClaudeNotifier.Ui.MascotSound]::Play('boop', 'fox') | Should -Be $true
        [ClaudeNotifier.Ui.MascotSound]::Play('boop', 'fox') | Should -Be $false   # не чаще раза в 0,6 с
        [ClaudeNotifier.Ui.MascotSound]::LastPlayed | Should -Be 'boop:fox'
        [ClaudeNotifier.Ui.MascotSound]::Reset()
        [ClaudeNotifier.Ui.MascotSound]::Muted = $true
        [ClaudeNotifier.Ui.MascotSound]::Play('yawn', 'fox') | Should -Be $false
        [ClaudeNotifier.Ui.MascotSound]::Muted = $false; [ClaudeNotifier.Ui.MascotSound]::Enabled = $false
        [ClaudeNotifier.Ui.MascotSound]::Play('yawn', 'fox') | Should -Be $false
    }

    It 'щелчок по маскоту: тык — «буп», по спящему — зевок; настройки звука и нарядов передаются в шторку' {
        [ClaudeNotifier.Ui.MascotSound]::Silent = $true
        [ClaudeNotifier.Ui.MascotSound]::Reset()
        $v = New-Object ClaudeNotifier.Ui.NotchView
        try {
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'w'; $it.State = 'working'
            $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $v.ClickArea('mascot', [System.Drawing.Point]::Empty)
            [ClaudeNotifier.Ui.MascotSound]::LastPlayed | Should -Match '^boop:'
        }
        finally { $v.Dispose() }
        $v = New-Object ClaudeNotifier.Ui.NotchView
        try { $v.SetItems([ClaudeNotifier.Ui.NotchItem[]]@()); $v.ClickArea('mascot', [System.Drawing.Point]::Empty); [ClaudeNotifier.Ui.MascotSound]::LastPlayed | Should -Match '^yawn:' }
        finally { $v.Dispose() }
        $script:TrayDataRoot = Join-Path $TestDrive 'flags'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"notch":{"sounds":false,"seasonal":false},"quiet":{"enabled":true}}')
        Update-NotifierMascotFlags
        [ClaudeNotifier.Ui.MascotSound]::Enabled | Should -Be $false
        [ClaudeNotifier.Ui.MascotSound]::Muted | Should -Be $true
        [ClaudeNotifier.Ui.MascotPlay]::Seasonal | Should -Be $false
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{}')
        Update-NotifierMascotFlags
        [ClaudeNotifier.Ui.MascotPlay]::Seasonal | Should -Be $true
    }

    It 'реакции: готово — радость, ошибка — паника, лимит — нервничает; напоминание — без реакции' {
        Get-NotifierEventReaction ([pscustomobject]@{ type = 'done' }) | Should -Be 'joy'
        Get-NotifierEventReaction ([pscustomobject]@{ type = 'error' }) | Should -Be 'panic'
        Get-NotifierEventReaction ([pscustomobject]@{ type = 'limit' }) | Should -Be 'nervous'
        Get-NotifierEventReaction ([pscustomobject]@{ type = 'permission' }) | Should -Be ''
        Get-NotifierEventReaction ([pscustomobject]@{ type = 'done'; reminder = $true }) | Should -Be ''
        $f = New-Object ClaudeNotifier.Ui.NotchForm
        try {
            $it = New-Object ClaudeNotifier.Ui.NotchItem; $it.Id = 'a'; $it.State = 'waiting'
            $f.View.SetItems([ClaudeNotifier.Ui.NotchItem[]]@($it))
            $f.View.React('a', 'joy'); $f.View.ReactionOf('a') | Should -Be 'joy'
            $f.View.React('нет-такого', 'nervous'); $f.View.ReactionOf('') | Should -Be 'nervous'   # без сеанса — главный маскот
            $f.View.React('a', 'dance'); $f.View.ReactionOf('a') | Should -Be 'joy'                  # неизвестная — не меняет
            $sz = $f.SizeFor(); $f.ClientSize = $sz
            $bmp = New-Object System.Drawing.Bitmap $sz.Width, $sz.Height
            try { $f.View.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $sz.Width, $sz.Height))) } finally { $bmp.Dispose() }
        }
        finally { $f.Dispose() }
    }

    It 'наряды: ночной колпак ночью, гирлянда на Новый год, летучая мышь на Хэллоуин, сердечко 14 февраля' {
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2026-06-01T12:00') | Should -BeNullOrEmpty
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2026-06-01T23:30') | Should -Be @('night')
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2026-12-31T02:00') | Should -Be @('newyear', 'night')
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2027-01-10T12:00') | Should -Be @('newyear')
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2026-10-31T12:00') | Should -Be @('halloween')
        [ClaudeNotifier.Ui.MascotPlay]::Outfits([datetime]'2026-02-14T12:00') | Should -Be @('valentine')
        # Наряд меняет кадр главного маскота.
        $a = New-Object System.Drawing.Bitmap 120, 100; $b = New-Object System.Drawing.Bitmap 120, 100
        try {
            foreach ($pair in @(@($a, '2026-06-01T12:00'), @($b, '2026-12-31T23:30'))) {
                [ClaudeNotifier.Ui.MascotPlay]::FixedNow = [datetime]$pair[1]
                $g = [System.Drawing.Graphics]::FromImage($pair[0]); $g.Clear([System.Drawing.Color]::Black)
                $m = New-Object ClaudeNotifier.Ui.CatMood; $m.Play = $true
                [ClaudeNotifier.Ui.Mascot]::PaintKind($g, (New-Object System.Drawing.RectangleF(10, 20, 100, 76)), 'penguin', 'waiting', 0, 1, $false, $m)
                $g.Dispose()
            }
            (Compare-NotifierBitmap -A $a -B $b) | Should -BeGreaterThan 0.01
        }
        finally { $a.Dispose(); $b.Dispose() }
    }
}

Describe 's_018_02 · сводка дня и забытые сеансы' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('d-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:DigestDay = $null
    }

    It 'текст сводки: задачи с правильным окончанием, время, расход; пустой день — без сводки' {
        Format-NotifierDigest -Tasks 1 -Seconds 3600 -Cost 0 | Should -Be 'Сегодня: 1 задача · работа 1 ч 00 мин'
        Format-NotifierDigest -Tasks 3 -Seconds 600 -Cost 4.2 | Should -Be 'Сегодня: 3 задачи · работа 10 мин · ≈ $4,20'
        Format-NotifierDigest -Tasks 11 -Seconds 0 -Cost 0 | Should -Be 'Сегодня: 11 задач'
        Format-NotifierDigest -Tasks 0 -Seconds 30 -Cost 0 | Should -Be ''
    }

    It 'задачи за сегодня — события «Готово» в истории по местной дате' {
        $now = [datetime]::Now
        $items = @(
            [pscustomobject]@{ type = 'done'; ts = (Iso $now.ToUniversalTime()) },
            [pscustomobject]@{ type = 'done'; ts = (Iso $now.ToUniversalTime().AddMinutes(-5)) },
            [pscustomobject]@{ type = 'error'; ts = (Iso $now.ToUniversalTime()) },
            [pscustomobject]@{ type = 'done'; ts = (Iso $now.ToUniversalTime().AddDays(-2)) })
        Save-NotifierHistory -Items $items -DataRoot $script:TrayDataRoot
        Get-NotifierTodayTasks -Now $now -DataRoot $script:TrayDataRoot | Should -Be 2
    }

    It 'сводка показывается раз в день после назначенного часа, когда вы за ПК; день запоминается' {
        Mock Test-NotifierNotchActive { $true }
        Mock Start-NotifierActivityScan { $true }
        $now = [datetime]'2026-11-19T19:30'
        $script:ActivitySummary = [pscustomobject]@{ Updated = $now.AddMinutes(-1); Days = @([pscustomobject]@{ date = '2026-11-19'; seconds = 5400; cost = 2.5; tokens = 1; prompts = 1 }) }
        Invoke-NotifierDigest -Now $now.Date.AddHours(17) -IdleSeconds 0 | Should -Be $false   # раньше 18:00
        Invoke-NotifierDigest -Now $now -IdleSeconds 600 | Should -Be $false                   # вас нет
        Invoke-NotifierDigest -Now $now -IdleSeconds 0 | Should -Be $true
        Invoke-NotifierDigest -Now $now.AddMinutes(30) -IdleSeconds 0 | Should -Be $false      # уже показана
        (Get-Content -LiteralPath (Join-Path $script:TrayDataRoot 'digest.txt') -Raw).Trim() | Should -Be '2026-11-19'
        $script:DigestDay = $null
        Invoke-NotifierDigest -Now $now.AddMinutes(40) -IdleSeconds 0 | Should -Be $false      # и после перезапуска
        # Статистика устарела — сначала пересчитать.
        $script:DigestDay = ''; $script:ActivitySummary.Updated = $now.AddHours(-2)
        Invoke-NotifierDigest -Now $now.AddDays(1) -IdleSeconds 0 | Should -Be $false
        Assert-MockCalled Start-NotifierActivityScan -Times 1 -Exactly -Scope It
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"notch":{"digest":false}}')
        $script:ActivitySummary.Updated = $now.AddDays(1)
        Invoke-NotifierDigest -Now $now.AddDays(1) -IdleSeconds 0 | Should -Be $false
    }

    It 'забытый сеанс: напоминание через push.remind и ещё через столько же, не больше двух; другие статусы — нет' {
        $cfg = Get-NotifierDefaultConfig
        $cfg.push.enabled = $true; $cfg.push.remind = 30
        $now = [datetime]::UtcNow
        $script:Forgotten = @{}
        $s = @(
            [pscustomobject]@{ session_id = 'w1'; state = 'waiting'; since = (Iso $now.AddMinutes(-31)); project = 'shop'; origin = 'cli' },
            [pscustomobject]@{ session_id = 'w2'; state = 'working'; since = (Iso $now.AddMinutes(-90)); project = 'x'; origin = 'cli' },
            [pscustomobject]@{ session_id = 'w3'; state = 'waiting'; since = (Iso $now.AddMinutes(-10)); project = 'y'; origin = 'cli' })
        $e = @(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now)
        $e.Count | Should -Be 1
        $e[0].session_id | Should -Be 'w1'
        $e[0].title | Should -Match '^Всё ещё ждёт ответа'
        @(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now.AddMinutes(5)).Count | Should -Be 0   # второе — через 60 мин
        # +30 мин: второе для w1 (ждёт 61 мин) и первое для w3 (ждёт 40 мин).
        (@(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now.AddMinutes(30)) | ForEach-Object { $_.session_id }) -join ',' | Should -Be 'w1,w3'
        (@(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now.AddMinutes(300)) | ForEach-Object { $_.session_id }) -join ',' | Should -Be 'w3'   # у w1 — уже два
        @(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now.AddMinutes(600)).Count | Should -Be 0
        $cfg.push.remind = 0
        $script:Forgotten = @{}
        @(Get-NotifierForgottenReminders -Sessions $s -Config $cfg -Now $now).Count | Should -Be 0
    }
}

Describe 's_018_02 · проверка работы и выпуски' {
    It 'шторка не запущена — ошибка; отчёт для копирования — итоги, версия, журнал' {
        if (-not [ClaudeNotifier.Ui.NotchHost]::Running) { (Get-NotifierDiagNotch).Level | Should -Be 'error' }
        $script:TrayDataRoot = Join-Path $TestDrive 'diag'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $script:TrayDataRoot 'log.txt') -Value '2026-11-19T10:00:00.000Z [WARN] notch: что-то' -Encoding UTF8
        $items = @((New-NotifierDiagItem ok 'Хуки' 'Все'), (New-NotifierDiagItem warn 'Шторка' 'Сбоев: 1'))
        $r = Get-NotifierDiagReport -Items $items
        $r | Should -Match 'проверка работы'
        $r | Should -Match 'Версия: '
        $r | Should -Match 'notch: что-то'
        (Get-Command Show-NotifierDialog).Parameters.ContainsKey('Extra') | Should -Be $true
    }

    It 'выпуск: коммит из описания, архив и SHA-256 только с загрузок этого репозитория' {
        $sha = 'c' * 40
        $json = @{ tag_name = 'v1.2.0'; name = 'Claude Notifier v1.2.0'; body = "commit: $sha`n`nИзменения"
            assets = @(@{ browser_download_url = 'https://github.com/o/r/releases/download/v1.2.0/claude-notifier-v1.2.0.zip' },
                @{ browser_download_url = 'https://github.com/o/r/releases/download/v1.2.0/claude-notifier-v1.2.0.zip.sha256' }) } | ConvertTo-Json -Depth 4
        $rel = ConvertFrom-NotifierRelease -Json $json -Repo 'o/r'
        $rel.Tag | Should -Be 'v1.2.0'
        $rel.Sha | Should -Be $sha
        $rel.ZipUrl | Should -Match 'claude-notifier-v1\.2\.0\.zip$'
        $rel.HashUrl | Should -Match '\.zip\.sha256$'
        ConvertFrom-NotifierRelease -Json ($json -replace 'github.com/o/r', 'evil.com/o/r') -Repo 'o/r' | Should -Be $null
        ConvertFrom-NotifierRelease -Json ($json -replace 'commit: c+', 'нет коммита') -Repo 'o/r' | Should -Be $null
        $s = Get-NotifierUpdateScript -Repo 'o/r' -Sha $sha -DataRoot 'x' -ZipUrl $rel.ZipUrl -HashUrl $rel.HashUrl
        $s | Should -Match 'Get-FileHash'
        $s | Should -Match ([regex]::Escape($rel.ZipUrl))
        [void][scriptblock]::Create($s)
        { Get-NotifierUpdateScript -Repo 'o/r' -Sha $sha -DataRoot 'x' -ZipUrl 'https://evil.com/a.zip' -HashUrl $rel.HashUrl } | Should -Throw
    }

    It 'трей, канал «Выпуски»: выпуск новее — обновление из архива выпуска; выпусков нет — как ветка main' {
        $script:TrayDataRoot = Join-Path $TestDrive 'rel'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        $script:AppVersion = @{ Commit = 'a' * 40; Repo = 'o/r'; Installed = '' }
        $new = 'd' * 40
        $relJson = @{ tag_name = 'v2.0.0'; name = 'v2.0.0'; body = "commit: $new"
            assets = @(@{ browser_download_url = 'https://github.com/o/r/releases/download/v2.0.0/claude-notifier-v2.0.0.zip' },
                @{ browser_download_url = 'https://github.com/o/r/releases/download/v2.0.0/claude-notifier-v2.0.0.zip.sha256' }) } | ConvertTo-Json -Depth 4
        $script:relTask = [System.Threading.Tasks.Task]::FromResult($relJson)
        $script:cmpTask = [System.Threading.Tasks.Task]::FromResult("{`"status`":`"ahead`",`"ahead_by`":5,`"commits`":[{`"sha`":`"$new`",`"commit`":{`"message`":`"x`"}}]}")
        Mock Start-NotifierReleaseCheck { $script:relTask }
        Mock Start-NotifierUpdateCheck { $script:cmpTask }
        Mock Show-NotifierToast { $true }
        $script:TrayNoOutput = $true
        $script:UpdateTask = $null; $script:UpdateInfo = $null; $script:UpdateNotifiedSha = ''; $script:UpdateNextCheck = [datetime]::MinValue
        Invoke-NotifierUpdateTick   # запрос выпуска
        Invoke-NotifierUpdateTick   # выпуск получен → сравнение коммитов
        Invoke-NotifierUpdateTick   # результат
        Assert-MockCalled Start-NotifierUpdateCheck -Times 1 -Exactly -Scope It -ParameterFilter { $Branch -eq $new }
        $script:UpdateInfo.Sha | Should -Be $new
        $script:UpdateInfo.Tag | Should -Be 'v2.0.0'
        $script:UpdateInfo.ZipUrl | Should -Match 'v2\.0\.0\.zip$'
        # Выпусков нет (404) — сравнение с веткой main.
        Add-Type -AssemblyName System.Net.Http
        $tcs = New-Object 'System.Threading.Tasks.TaskCompletionSource[string]'
        $tcs.SetException((New-Object System.Net.Http.HttpRequestException 'Response status code does not indicate success: 404 (Not Found).'))
        $script:relTask = $tcs.Task
        $script:UpdateTask = $null; $script:UpdateInfo = $null; $script:UpdateNextCheck = [datetime]::MinValue
        Invoke-NotifierUpdateTick; Invoke-NotifierUpdateTick; Invoke-NotifierUpdateTick
        Assert-MockCalled Start-NotifierUpdateCheck -Times 1 -Exactly -Scope It -ParameterFilter { $Branch -eq 'main' }
        $script:UpdateInfo.ContainsKey('ZipUrl') | Should -Be $false
        $script:AppVersion = $null; $script:UpdateInfo = $null; $script:UpdateTask = $null
    }

    It 'выпадающий список: щелчок вне него закрывает (открыт — следит за мышью, внутри — не закрывает)' {
        $m = New-NotifierMenu -Theme ([ClaudeNotifier.Ui.Theme]::Create($true)) -Items @(@('Один', $null), @('Два', $null))
        try {
            $m.Show((New-Object System.Drawing.Point 200, 200))
            $m.Visible | Should -Be $true
            $inside = New-Object System.Drawing.Point ($m.Bounds.X + 5), ($m.Bounds.Y + 5)
            [ClaudeNotifier.Ui.Native]::InsideMenu($m, $inside) | Should -Be $true
            [ClaudeNotifier.Ui.Native]::InsideMenu($m, (New-Object System.Drawing.Point ($m.Bounds.Right + 50), ($m.Bounds.Bottom + 50))) | Should -Be $false
            $m.Close()
            [ClaudeNotifier.Ui.Native]::InsideMenu($m, $inside) | Should -Be $false   # закрытое — не мешает
        }
        finally { $m.Dispose() }
        (Get-Content -LiteralPath (Join-Path $repoRoot 'src\ClaudeNotifier.Ui.ps1') -Raw) | Should -Match 'CloseOnOutsideClick'
    }

    It 'картинка уведомления: маскот с эмоцией события, рисуется один раз и берётся из кэша' {
        $root = Join-Path $TestDrive 'logo'
        New-Item -ItemType Directory $root -Force | Out-Null
        $p1 = Get-NotifierToastLogo -Event ([pscustomobject]@{ type = 'error' }) -DataRoot $root
        Test-Path -LiteralPath $p1 | Should -Be $true
        $p1 | Should -Match '-error-v\d+\.png$'
        $img = [System.Drawing.Image]::FromFile($p1); try { $img.Width | Should -Be 96 } finally { $img.Dispose() }
        $t1 = (Get-Item $p1).LastWriteTimeUtc
        Start-Sleep -Milliseconds 30
        (Get-NotifierToastLogo -Event ([pscustomobject]@{ type = 'error' }) -DataRoot $root) | Should -Be $p1
        (Get-Item $p1).LastWriteTimeUtc | Should -Be $t1   # из кэша
        (Get-NotifierToastLogo -Event ([pscustomobject]@{ type = 'что-то' }) -DataRoot $root) | Should -Match '-done-v\d+\.png$'
    }

    It 'настройки: новые строки и значения по умолчанию' {
        $c = Get-NotifierDefaultConfig
        $c.notch.sounds | Should -Be $true
        $c.notch.seasonal | Should -Be $true
        $c.notch.digest | Should -Be $true
        $c.notch.digestHour | Should -Be 18
        $c.push.remind | Should -Be 30
        $c.update.channel | Should -Be 'release'
        $script:TrayDataRoot = Join-Path $TestDrive 'rows'
        New-Item -ItemType Directory $script:TrayDataRoot -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:TrayDataRoot 'config.json'), '{"notch":{"digestHour":21,"sounds":"да"},"update":{"channel":"main"},"push":{"remind":60}}')
        $c = Get-NotifierConfig -DataRoot $script:TrayDataRoot
        $c.notch.digestHour | Should -Be 21
        $c.notch.sounds | Should -Be $true   # не true/false — по умолчанию
        $c.update.channel | Should -Be 'main'
        $c.push.remind | Should -Be 60
        $keys = @(Get-NotifierNotchSettingsRows | ForEach-Object { $_.Key })
        foreach ($k in @('notch.sounds', 'notch.seasonal', 'notch.digest', 'push.remind', 'update.channel')) { $keys -contains $k | Should -Be $true -Because $k }
        Get-NotifierSelectLabel 'notch.digest' | Should -Be 'В 21:00'
        Get-NotifierSelectLabel 'update.channel' | Should -Be 'Ветка main'
        Set-NotifierSelectValue -Key 'notch.digest' -Value 'off'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).notch.digest | Should -Be $false
        Set-NotifierSelectValue -Key 'push.remind' -Value '120'
        (Get-NotifierConfig -DataRoot $script:TrayDataRoot).push.remind | Should -Be 120
    }
}
