$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
Import-Module (Join-Path $repoRoot 'src\lib\Toast.psm1') -Force
Import-Module (Join-Path $repoRoot 'src\lib\Registration.psm1') -Force
$install = Join-Path $repoRoot 'install.ps1'
$uninstall = Join-Path $repoRoot 'uninstall.ps1'
$classesBase = 'HKCU:\Software\claude-notifier-tests-' + [guid]::NewGuid().ToString('N')

function New-TestEvent([string]$Title = 'Готово · proj', [string]$Preview = 'Тесты проходят') {
    return [pscustomobject]@{ v = 1; id = '11111111-2222-3333-4444-555555555555'; type = 'done'; title = $Title; preview = $Preview }
}

Describe 's_002_01 · New-NotifierToastXml' {
    It 'строит ToastGeneric: title, preview, без launch (ADR-006), тихий звук' {
        [xml]$x = New-NotifierToastXml -Event (New-TestEvent)
        $x.toast.HasAttribute('launch') | Should Be $false
        $x.toast.HasAttribute('activationType') | Should Be $false
        $x.toast.visual.binding.template | Should Be 'ToastGeneric'
        $texts = @($x.toast.visual.binding.text)
        $texts.Count | Should Be 2
        $texts[0] | Should Be 'Готово · proj'
        $texts[1] | Should Be 'Тесты проходят'
        $x.toast.audio.silent | Should Be 'true'
    }

    It 'экранирует <, >, &, кавычки в тексте' {
        $xmlText = New-NotifierToastXml -Event (New-TestEvent -Title 'a "b" ''c''' -Preview '<script>alert(1)</script> & co')
        $xmlText | Should Not Match '<script>'
        [xml]$x = $xmlText
        $texts = @($x.toast.visual.binding.text)
        $texts[0] | Should Be 'a "b" ''c'''
        $texts[1] | Should Be '<script>alert(1)</script> & co'
    }

    It 'пустое превью → только строка заголовка' {
        [xml]$x = New-NotifierToastXml -Event (New-TestEvent -Preview '')
        @($x.toast.visual.binding.text).Count | Should Be 1
    }

    It 'id события не попадает в XML (никаких атрибутов из данных события)' {
        $e = New-TestEvent; $e.id = 'x" onload="evil'
        $xmlText = New-NotifierToastXml -Event $e
        $xmlText | Should Not Match 'onload'
        [xml]$x = $xmlText
        $x.toast.Attributes.Count | Should Be 0
    }
}

Describe 's_002_01 · Show-NotifierToast' {
    It 'передаёт XML и AppId в WinRT и возвращает $true' {
        Mock -ModuleName Toast Invoke-ToastShow { }
        Show-NotifierToast -Event (New-TestEvent) -AppId 'Test.App' -DataRoot $TestDrive | Should Be $true
        Assert-MockCalled -ModuleName Toast Invoke-ToastShow -Scope It -Times 1 -Exactly -ParameterFilter {
            $AppId -eq 'Test.App' -and $Xml -like '*Тесты проходят*'
        }
    }

    It 'AppId: есть ярлык в «Пуске» → ClaudeNotifier.App; нет → Windows PowerShell' {
        $dir = Join-Path $TestDrive 'programs'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        Get-NotifierToastAppId -StartMenuDir $dir | Should Be '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        [IO.File]::WriteAllText((Join-Path $dir 'Claude Notifier.lnk'), 'x')
        Get-NotifierToastAppId -StartMenuDir $dir | Should Be 'ClaudeNotifier.App'
    }

    It 'ошибка WinRT → $false и ERROR в логе, без исключения' {
        $root = Join-Path $TestDrive 'err'
        Mock -ModuleName Toast Invoke-ToastShow { throw 'WinRT failure' }
        { Show-NotifierToast -Event (New-TestEvent) -DataRoot $root } | Should Not Throw
        Show-NotifierToast -Event (New-TestEvent) -DataRoot $root | Should Be $false
        (Get-Content (Join-Path $root 'log.txt') -Raw -Encoding UTF8) | Should Match '\[ERROR\] toast: .*WinRT failure'
    }

    It 'реальный WinRT: XML загружается в Windows.Data.Xml.Dom.XmlDocument' {
        $doc = & (Get-Module Toast) { param($x) ConvertTo-WinRtXml $x } (New-NotifierToastXml -Event (New-TestEvent))
        $doc.GetXml() | Should Match 'ToastGeneric'
    }
}

Describe 's_002_01 · AUMID' {
    It 'Register-NotifierAumid пишет DisplayName и IconUri, Unregister удаляет' {
        $classes = Join-Path $classesBase 'aumid'
        try {
            Register-NotifierAumid -AppRoot 'C:\x\claude-notifier\app' -ClassesRoot $classes
            $p = Get-ItemProperty (Join-Path $classes 'AppUserModelId\ClaudeNotifier')
            $p.DisplayName | Should Be 'Claude Notifier'
            $p.IconUri | Should Be 'C:\x\claude-notifier\app\assets\icon.ico'
            Unregister-NotifierAumid -ClassesRoot $classes | Should Be $true
            Test-Path (Join-Path $classes 'AppUserModelId\ClaudeNotifier') | Should Be $false
            Unregister-NotifierAumid -ClassesRoot $classes | Should Be $false
        }
        finally { Remove-Item $classes -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'install не регистрирует AUMID и удаляет ключ от прежних версий (ADR-006)' {
        $id = [guid]::NewGuid().ToString('N')
        $classes = Join-Path $classesBase $id
        $settings = Join-Path $TestDrive "home-$id\.claude\settings.json"
        $data = Join-Path $TestDrive "data-$id\claude-notifier"
        try {
            Register-NotifierAumid -AppRoot 'C:\old' -ClassesRoot $classes
            & $install -SettingsPath $settings -DataRoot $data -ClassesRoot $classes -StartMenuDir (Join-Path $TestDrive 'startmenu') -DesktopDir (Join-Path $TestDrive 'desktop') | Out-Null
            $LASTEXITCODE | Should Be 0
            Test-Path (Join-Path $classes 'AppUserModelId\ClaudeNotifier') | Should Be $false
            Test-Path (Join-Path $data 'app\assets\icon.ico') | Should Be $true
        }
        finally { Remove-Item $classes -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'icon.ico читается декодером Windows: кадры от 16 до 256 px' {
        Add-Type -AssemblyName PresentationCore
        $fs = [IO.File]::OpenRead((Join-Path $repoRoot 'src\assets\icon.ico'))
        try {
            $dec = New-Object System.Windows.Media.Imaging.IconBitmapDecoder $fs, ([System.Windows.Media.Imaging.BitmapCreateOptions]::None), ([System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
            (($dec.Frames | ForEach-Object { $_.PixelWidth }) -join ',') | Should Be '16,20,24,32,40,48,64,128,256'
        }
        finally { $fs.Close() }
    }
}

Describe 's_002_01 · уборка' {
    It 'тестовые ключи реестра удалены' {
        if (Test-Path $classesBase) { Remove-Item $classesBase -Recurse -Force }
        Test-Path $classesBase | Should Be $false
    }
}
