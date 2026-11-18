BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    $libDir = Join-Path $repoRoot 'src\lib'

    Import-Module (Join-Path $libDir 'Log.psm1') -Force
    Import-Module (Join-Path $libDir 'Config.psm1') -Force
}

Describe 's_001_01 · структура репозитория' {
    It 'содержит каталог <Dir>' -TestCases @(
        @{ Dir = 'src' }, @{ Dir = 'src\lib' }, @{ Dir = 'src\assets' }, @{ Dir = 'tests' }
    ) {
        param($Dir)
        Test-Path (Join-Path $repoRoot $Dir) -PathType Container | Should -Be $true
    }

    It 'все .ps1/.psm1 в src и tests сохранены в UTF-8 с BOM' {
        $files = Get-ChildItem (Join-Path $repoRoot 'src'), (Join-Path $repoRoot 'tests') -Recurse -Include *.ps1, *.psm1
        $files.Count | Should -BeGreaterThan 0
        $withoutBom = $files | Where-Object {
            $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
            -not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        }
        ($withoutBom | ForEach-Object { $_.Name }) -join ', ' | Should -Be ''
    }
}

Describe 's_001_01 · Write-NotifierLog' {
    It 'пишет строку с уровнем <Level>' -TestCases @(
        @{ Level = 'INFO' }, @{ Level = 'WARN' }, @{ Level = 'ERROR' }
    ) {
        param($Level)
        $root = Join-Path $TestDrive "log-$Level"
        Write-NotifierLog -Level $Level -Message 'привет' -DataRoot $root
        $line = Get-Content (Join-Path $root 'log.txt') -Encoding UTF8 | Select-Object -Last 1
        $line | Should -Match "^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z \[$Level\] привет$"
    }

    It 'отклоняет неизвестный уровень' {
        { Write-NotifierLog -Level 'DEBUG' -Message 'x' -DataRoot $TestDrive } | Should -Throw
    }

    It 'ротирует log.txt больше 1 МБ в log.1.txt' {
        $root = Join-Path $TestDrive 'rotate'
        New-Item -ItemType Directory -Path $root | Out-Null
        $log = Join-Path $root 'log.txt'
        [System.IO.File]::WriteAllBytes($log, (New-Object byte[] (1MB + 100)))
        Set-Content -Path (Join-Path $root 'log.1.txt') -Value 'old'

        Write-NotifierLog -Level INFO -Message 'после ротации' -DataRoot $root

        (Get-Item (Join-Path $root 'log.1.txt')).Length | Should -Be (1MB + 100)
        (Get-Content $log -Encoding UTF8).Count | Should -Be 1
    }

    It 'не ротирует файл ровно 1 МБ' {
        $root = Join-Path $TestDrive 'norotate'
        New-Item -ItemType Directory -Path $root | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $root 'log.txt'), (New-Object byte[] (1MB)))
        Write-NotifierLog -Level INFO -Message 'x' -DataRoot $root
        Test-Path (Join-Path $root 'log.1.txt') | Should -Be $false
    }

    It 'не выбрасывает исключение, если запись невозможна' {
        $root = Join-Path $TestDrive 'blocked'
        New-Item -ItemType Directory -Path $root | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'log.txt') | Out-Null  # каталог вместо файла
        { Write-NotifierLog -Level ERROR -Message 'x' -DataRoot $root } | Should -Not -Throw
    }

    It 'по умолчанию — %USERPROFILE%\.claude-notifier (AppData виртуализирует пакет Claude); CLAUDE_NOTIFIER_HOME переопределяет' {
        $old = $env:CLAUDE_NOTIFIER_HOME
        try {
            $env:CLAUDE_NOTIFIER_HOME = $null
            Get-NotifierDataRoot | Should -Be (Join-Path $env:USERPROFILE '.claude-notifier')
            $env:CLAUDE_NOTIFIER_HOME = 'C:\x\cn'
            Get-NotifierDataRoot | Should -Be 'C:\x\cn'
        }
        finally { $env:CLAUDE_NOTIFIER_HOME = $old }
    }
}

Describe 's_001_01 · Get-NotifierConfig' {
    BeforeAll {
        $types = @('done', 'permission', 'error', 'limit')
    }


    It 'без config.json возвращает значения по умолчанию' {
        $root = Join-Path $TestDrive 'empty'
        $cfg = Get-NotifierConfig -DataRoot $root
        $cfg.previewLength | Should -Be 200
        ($cfg.limitThresholds -join ',') | Should -Be '80,90'
        foreach ($t in $types) {
            $cfg.events[$t].enabled | Should -Be $true
            $cfg.events[$t].sound | Should -Be ''
        }
        Test-Path (Join-Path $root 'log.txt') | Should -Be $false
    }

    It 'config.default.json совпадает с умолчаниями модуля' {
        $file = Get-Content (Join-Path $repoRoot 'config.default.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $defaults = Get-NotifierDefaultConfig
        $file.previewLength | Should -Be $defaults.previewLength
        ($file.limitThresholds -join ',') | Should -Be ($defaults.limitThresholds -join ',')
        foreach ($t in $types) {
            $file.events.$t.enabled | Should -Be $defaults.events[$t].enabled
            $file.events.$t.sound | Should -Be $defaults.events[$t].sound
        }
    }

    It 'берёт корректные значения пользователя' {
        $root = Join-Path $TestDrive 'user'
        New-Item -ItemType Directory -Path $root | Out-Null
        @'
{ "previewLength": 120, "limitThresholds": [90, 75, 90],
  "events": { "error": { "enabled": false, "sound": "C:\\sounds\\err.wav" } } }
'@ | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $cfg = Get-NotifierConfig -DataRoot $root
        $cfg.previewLength | Should -Be 120
        ($cfg.limitThresholds -join ',') | Should -Be '75,90'
        $cfg.events['error'].enabled | Should -Be $false
        $cfg.events['error'].sound | Should -Be 'C:\sounds\err.wav'
        $cfg.events['done'].enabled | Should -Be $true
        Test-Path (Join-Path $root 'log.txt') | Should -Be $false
    }

    It 'заменяет неверное значение <Json> умолчанием и пишет WARN' -TestCases @(
        @{ Json = '{ "previewLength": "abc" }'; Key = 'previewLength' },
        @{ Json = '{ "previewLength": 5 }'; Key = 'previewLength' },
        @{ Json = '{ "limitThresholds": "abc" }'; Key = 'limitThresholds' },
        @{ Json = '{ "limitThresholds": [0, 150] }'; Key = 'limitThresholds' },
        @{ Json = '{ "limitThresholds": [] }'; Key = 'limitThresholds' },
        @{ Json = '{ "events": { "done": { "enabled": "yes" } } }'; Key = 'events.done.enabled' },
        @{ Json = '{ "events": { "limit": { "sound": 42 } } }'; Key = 'events.limit.sound' },
        @{ Json = '{ "events": "nope" }'; Key = 'events' },
        @{ Json = '{ "events": { "done": 1 } }'; Key = 'events.done' }
    ) {
        param($Json, $Key)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        $Json | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $cfg = Get-NotifierConfig -DataRoot $root
        $defaults = Get-NotifierDefaultConfig
        $cfg.previewLength | Should -Be $defaults.previewLength
        ($cfg.limitThresholds -join ',') | Should -Be '80,90'
        $cfg.events['done'].enabled | Should -Be $true
        $cfg.events['limit'].sound | Should -Be ''
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match "\[WARN\] .*$([regex]::Escape($Key))"
    }

    It 'битый JSON → умолчания и WARN' {
        $root = Join-Path $TestDrive 'broken'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ not json' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $cfg = Get-NotifierConfig -DataRoot $root
        $cfg.previewLength | Should -Be 200
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] .*config\.json'
    }

    It 'JSON не-объект (массив) → умолчания и WARN' {
        $root = Join-Path $TestDrive 'array'
        New-Item -ItemType Directory -Path $root | Out-Null
        '[1, 2]' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        $cfg = Get-NotifierConfig -DataRoot $root
        $cfg.previewLength | Should -Be 200
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] config\.json должен содержать объект'
    }

    It 'изменение результата не портит умолчания' {
        $a = Get-NotifierConfig -DataRoot (Join-Path $TestDrive 'iso')
        $a.events['done'].enabled = $false
        $a.limitThresholds += 99
        $b = Get-NotifierDefaultConfig
        $b.events['done'].enabled | Should -Be $true
        ($b.limitThresholds -join ',') | Should -Be '80,90'
    }
}

Describe 's_001_01 · словарь строк' {
    It 'заголовок для <Type> = <Title>' -TestCases @(
        @{ Type = 'done'; Title = 'Готово' },
        @{ Type = 'permission'; Title = 'Нужно разрешение' },
        @{ Type = 'error'; Title = 'Ошибка' },
        @{ Type = 'limit'; Title = 'Лимит' }
    ) {
        param($Type, $Title)
        Get-NotifierEventTitle -Type $Type | Should -Be $Title
        $NotifierStrings[$Type] | Should -Be $Title
    }

    It 'неизвестный тип → исключение' {
        { Get-NotifierEventTitle -Type 'other' } | Should -Throw
    }
}
