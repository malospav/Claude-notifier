BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Config.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Sound.psm1') -Force

    $media = Join-Path $env:SystemRoot 'Media'
}

Describe 's_002_02 · Resolve-NotifierSoundPath' {
    It 'по умолчанию <Type> → <File> (файл есть на ПК)' -TestCases @(
        @{ Type = 'done'; File = 'Windows Notify System Generic.wav' },
        @{ Type = 'permission'; File = 'Windows Notify Messaging.wav' },
        @{ Type = 'error'; File = 'Windows Critical Stop.wav' },
        @{ Type = 'limit'; File = 'Windows Battery Low.wav' }
    ) {
        param($Type, $File)
        $path = Resolve-NotifierSoundPath -Type $Type -Config (Get-NotifierDefaultConfig) -DataRoot $TestDrive
        $path | Should -Be (Join-Path $media $File)
        Test-Path $path | Should -Be $true
    }

    It '4 типа → 4 разных файла' {
        $cfg = Get-NotifierDefaultConfig
        $paths = @('done', 'permission', 'error', 'limit') | ForEach-Object { Resolve-NotifierSoundPath -Type $_ -Config $cfg -DataRoot $TestDrive }
        @($paths | Sort-Object -Unique).Count | Should -Be 4
    }

    It 'свой существующий WAV из конфига используется' {
        $wav = Join-Path $TestDrive 'mine.wav'
        Copy-Item (Join-Path $media 'chimes.wav') $wav
        $cfg = Get-NotifierDefaultConfig
        $cfg.events['error'].sound = $wav
        Resolve-NotifierSoundPath -Type error -Config $cfg -DataRoot $TestDrive | Should -Be $wav
    }

    It 'свой WAV не существует → звук по умолчанию + WARN' {
        $root = Join-Path $TestDrive 'missing'
        $cfg = Get-NotifierDefaultConfig
        $cfg.events['done'].sound = 'C:\nope\Звук.wav'
        Resolve-NotifierSoundPath -Type done -Config $cfg -DataRoot $root | Should -Be (Join-Path $media 'Windows Notify System Generic.wav')
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] sound: .*Звук\.wav'
    }

    It 'пустой путь → звук по умолчанию без WARN (пусто = системный)' {
        $root = Join-Path $TestDrive 'empty'
        Resolve-NotifierSoundPath -Type limit -Config (Get-NotifierDefaultConfig) -DataRoot $root | Should -Be (Join-Path $media 'Windows Battery Low.wav')
        Test-Path (Join-Path $root 'log.txt') | Should -Be $false
    }
}

Describe 's_002_02 · Invoke-NotifierSound' {
    It 'включённый тип → асинхронный Play выбранного файла' {
        Mock -ModuleName Sound Invoke-SoundPlay { }
        Invoke-NotifierSound -Type permission -Config (Get-NotifierDefaultConfig) -DataRoot $TestDrive | Should -Be (Join-Path $media 'Windows Notify Messaging.wav')
        Assert-MockCalled -ModuleName Sound Invoke-SoundPlay -Scope It -Times 1 -Exactly -ParameterFilter { $Path -like '*Windows Notify Messaging.wav' }
    }

    It 'выключенный тип → звук не играет' {
        Mock -ModuleName Sound Invoke-SoundPlay { }
        $cfg = Get-NotifierDefaultConfig
        $cfg.events['done'].enabled = $false
        Invoke-NotifierSound -Type done -Config $cfg -DataRoot $TestDrive | Should -Be $null
        Assert-MockCalled -ModuleName Sound Invoke-SoundPlay -Scope It -Times 0
    }

    It 'свой файл не воспроизводится (битый WAV) → WARN и звук по умолчанию' {
        $root = Join-Path $TestDrive 'corrupt'
        $bad = Join-Path $TestDrive 'bad.wav'
        Set-Content $bad 'not a wav'
        $cfg = Get-NotifierDefaultConfig
        $cfg.events['error'].sound = $bad
        Mock -ModuleName Sound Invoke-SoundPlay { if ($Path -like '*\bad.wav') { throw 'The wave header is corrupt.' } }
        Invoke-NotifierSound -Type error -Config $cfg -DataRoot $root | Should -Be (Join-Path $media 'Windows Critical Stop.wav')
        Assert-MockCalled -ModuleName Sound Invoke-SoundPlay -Scope It -Times 2 -Exactly
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[WARN\] sound: .*bad\.wav'
    }

    It 'не воспроизводится даже звук по умолчанию → $null и ERROR, без исключения' {
        $root = Join-Path $TestDrive 'allfail'
        Mock -ModuleName Sound Invoke-SoundPlay { throw 'no audio device' }
        { Invoke-NotifierSound -Type done -Config (Get-NotifierDefaultConfig) -DataRoot $root } | Should -Not -Throw
        Invoke-NotifierSound -Type done -Config (Get-NotifierDefaultConfig) -DataRoot $root | Should -Be $null
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should -Match '\[ERROR\] sound: .*no audio device'
    }

    It 'без -Config читает настройки из DataRoot' {
        $root = Join-Path $TestDrive 'cfg'
        New-Item -ItemType Directory -Path $root | Out-Null
        '{ "events": { "limit": { "enabled": false } } }' | Set-Content (Join-Path $root 'config.json') -Encoding UTF8
        Mock -ModuleName Sound Invoke-SoundPlay { }
        Invoke-NotifierSound -Type limit -DataRoot $root | Should -Be $null
        Assert-MockCalled -ModuleName Sound Invoke-SoundPlay -Scope It -Times 0
    }

    It 'реальный SoundPlayer: битый файл → исключение при загрузке, корректный — без ошибок (беззвучно: только Load)' {
        $bad = Join-Path $TestDrive 'bad2.wav'
        Set-Content $bad 'garbage'
        { & (Get-Module Sound) { param($p) New-SoundPlayer $p } $bad } | Should -Throw
        { & (Get-Module Sound) { param($p) New-SoundPlayer $p } (Join-Path $media 'chimes.wav') } | Should -Not -Throw
    }
}
