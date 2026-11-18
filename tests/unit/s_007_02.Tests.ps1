BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
    Import-Module (Join-Path $repoRoot 'src\lib\Devices.psm1') -Force
    Import-Module (Join-Path $repoRoot 'src\lib\Server.psm1') -Force
    $tray = Join-Path $repoRoot 'src\ClaudeNotifier.Tray.ps1'
    . $tray
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing

    function Get-FreePort {
        # Свободный порт: система выдаёт его для TcpListener на порту 0.
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
        $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
        return $port
    }
}

Describe 's_007_02 · настройка Windows (netsh подменён)' {
    It 'setup-network.ps1: резервация URL и правило брандмауэра только из локальной подсети; -Remove удаляет' {
        $global:netshCalls = New-Object System.Collections.ArrayList
        function global:netsh { [void]$global:netshCalls.Add(($args -join ' ')); $global:LASTEXITCODE = 0; 'ok' }
        # Сертификат не создаётся по-настоящему (на CI тесты идут с правами администратора).
        function global:New-SelfSignedCertificate { [pscustomobject]@{ Thumbprint = 'ABCDEF0123'; NotAfter = (Get-Date).AddYears(10) } }
        try {
            $root = Join-Path $TestDrive 'setup'
            & (Join-Path $repoRoot 'src\setup-network.ps1') -Port 47600 -User 'PC\me' -DataRoot $root
            $calls = $global:netshCalls -join "`n"
            $calls | Should -Match 'http add urlacl url=http://\+:47600/ user=PC\\me'
            $calls | Should -Match 'advfirewall firewall add rule name=claude-notifier dir=in action=allow protocol=TCP localport=47600,47601 remoteip=localsubnet profile=any'
            # Шифрование: сертификат привязан к порту 47601, резервация https.
            $calls | Should -Match 'http add sslcert ipport=0\.0\.0\.0:47601 certhash=[0-9A-Fa-f]+ appid=\{6f2b6d3e-3c1a-4b8e-9f62-5d0c4e7a9b11\} certstorename=MY'
            $calls | Should -Match 'http add urlacl url=https://\+:47601/ user=PC\\me'
            Get-Content (Join-Path $root 'setup-network.log') -Raw | Should -Match 'firewall add: exit 0'
            $global:netshCalls.Clear()
            & (Join-Path $repoRoot 'src\setup-network.ps1') -Port 47600 -DataRoot $root -Remove
            ($global:netshCalls -join "`n") | Should -Match 'http delete urlacl url=http://\+:47600/'
            ($global:netshCalls -join "`n") | Should -Match 'advfirewall firewall delete rule name=claude-notifier'
            ($global:netshCalls -join "`n") | Should -Match 'http delete sslcert ipport=0\.0\.0\.0:47601'
            ($global:netshCalls -join "`n") | Should -Match 'http delete urlacl url=https://\+:47601/'
        }
        finally { Remove-Item function:\netsh, function:\New-SelfSignedCertificate -ErrorAction SilentlyContinue; Remove-Variable -Scope Global netshCalls -ErrorAction SilentlyContinue }
    }

    It 'setup-network.ps1: ошибка netsh → код 1' {
        $p = Join-Path $repoRoot 'src\setup-network.ps1'
        $root = Join-Path $TestDrive 'setup2'
        & powershell -NoProfile -Command "function netsh { `$global:LASTEXITCODE = 1; 'denied' }; & '$p' -Port 47600 -User 'x' -DataRoot '$root'; exit `$LASTEXITCODE" | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'Test-NotifierNetworkSetup: нужны и резервация URL, и правило' {
        try {
            function global:netsh { if ($args -contains 'urlacl') { 'Reserved URL : http://+:47600/' } else { $global:LASTEXITCODE = 0 } }
            Test-NotifierNetworkSetup -Port 47600 | Should -Be $true
            function global:netsh { if ($args -contains 'urlacl') { 'nothing' } else { $global:LASTEXITCODE = 0 } }
            Test-NotifierNetworkSetup -Port 47600 | Should -Be $false
            function global:netsh { if ($args -contains 'urlacl') { 'http://+:47600/' } else { $global:LASTEXITCODE = 1 } }
            Test-NotifierNetworkSetup -Port 47600 | Should -Be $false
        }
        finally { Remove-Item function:\netsh -ErrorAction SilentlyContinue }
    }

    It 'Invoke-NotifierNetworkSetup: UAC отклонён → cancelled; код 0 → ok; иначе failed' {
        $root = Join-Path $TestDrive 'uac'
        Mock -ModuleName Server Start-Process { throw 'The operation was canceled by the user' }
        Invoke-NotifierNetworkSetup -Port 47600 -DataRoot $root | Should -Be 'cancelled'
        Mock -ModuleName Server Start-Process { [pscustomobject]@{ ExitCode = 0 } }
        Invoke-NotifierNetworkSetup -Port 47600 -Remove -DataRoot $root | Should -Be 'ok'
        Assert-MockCalled -ModuleName Server Start-Process -Scope It -ParameterFilter { $Verb -eq 'RunAs' -and ($ArgumentList -join ' ') -match 'setup-network\.ps1.*-Remove' }
        Mock -ModuleName Server Start-Process { [pscustomobject]@{ ExitCode = 1 } }
        Invoke-NotifierNetworkSetup -Port 47600 -DataRoot $root | Should -Be 'failed'
    }
}

Describe 's_007_02 · включение доступа и окно подключения' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('ui-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:Net.Network.port = (Get-FreePort)
        $script:Net.Address = '192.168.1.50'
    }

    It 'настройка уже сделана → включение без вопросов, сервер запущен, enabled сохранён; выключение останавливает' {
        Mock Test-NotifierNetworkSetup { $true }
        Mock Get-NotifierHttpPrefix { "http://localhost:$Port/" }
        Mock Get-NotifierLanAddress { '192.168.1.50' }
        Enable-NotifierNetworkAccess | Should -Be $true
        $script:Net.Server | Should -Not -Be $null
        (Get-NotifierNetwork -DataRoot $script:TrayDataRoot).enabled | Should -Be $true
        Enable-NotifierNetworkAccess | Should -Be $true
        Disable-NotifierNetworkAccess
        $script:Net.Server | Should -Be $null
        (Get-NotifierNetwork -DataRoot $script:TrayDataRoot).enabled | Should -Be $false
    }

    It 'сервер не запускается → текст ошибки; при старте трея с enabled=true это не роняет трей' {
        Mock Get-NotifierHttpPrefix { 'http://+:1/' }
        Start-NotifierNetServer | Should -Be $false
        $script:Net.Error | Should -Not -BeNullOrEmpty
        Save-NotifierNetwork -Network @{ enabled = $true; port = 1024; devices = @() } -DataRoot $script:TrayDataRoot
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
        $script:Net.Server | Should -Be $null
        $script:Net.Error | Should -Not -BeNullOrEmpty
    }

    It 'окно «Подключить устройство»: адрес, PIN, «Новый код», статус подключения; закрытие гасит PIN' {
        Mock Enable-NotifierNetworkAccess { $true }
        Mock Invoke-NotifierSessionsRefresh { , @() }
        Show-NotifierConnectDialog
        $f = $script:ConnectForm
        try {
            $f | Should -Not -Be $null
            $pin1 = $script:Net.Pairing.Pin
            $f.Tag.Pin.Text | Should -Be ($pin1.Substring(0, 3) + ' ' + $pin1.Substring(3))
            $f.Tag.Url.Text | Should -Be "http://192.168.1.50:$($script:Net.Network.port)"
            $f.Tag.NewPin.PerformClick()
            $script:Net.Pairing.Pin | Should -Match '^\d{6}$'
            Update-NotifierConnectStatus -Device ([pscustomobject]@{ name = 'iPhone'; hooks = $false })
            $f.Tag.Status.Text | Should -Match 'Подключено: iPhone$'
            Update-NotifierConnectStatus -Device ([pscustomobject]@{ name = 'MacBook'; hooks = $true })
            $f.Tag.Status.Text | Should -Match 'MacBook: хуки установлены'
            Show-NotifierConnectDialog
            $script:ConnectForm | Should -Be $f
        }
        finally { $f.Close(); $f.Dispose() }
        $script:Net.Pairing | Should -Be $null
        $script:ConnectForm | Should -Be $null
    }

    It 'доступ не включён (например, UAC отклонён) → окно подключения не открывается' {
        Mock Enable-NotifierNetworkAccess { $false }
        Mock Invoke-NotifierSessionsRefresh { , @() }
        Show-NotifierConnectDialog
        $script:ConnectForm | Should -Be $null
    }
}

Describe 's_007_02 · кнопки вкладки «Устройства»' {
    BeforeEach {
        $script:TrayDataRoot = Join-Path $TestDrive ('dev-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:TrayDataRoot -Force | Out-Null
        Initialize-NotifierNet -DataRoot $script:TrayDataRoot
    }

    It 'кнопка «Уведомления на ПК» переключает уведомления выделенного устройства' {
        [void](Add-NotifierDevice -Network $script:Net.Network -Name 'MacBook')
        $script:SessionsForm = New-NotifierSessionsForm
        try {
            [void](Invoke-NotifierSessionsRefresh)
            $list = $script:SessionsForm.Tag.Net.Devices
            Invoke-NotifierDeviceAction -Action notify   # ничего не выделено → ничего не происходит
            $script:Net.Network.devices[0].notify | Should -Be $false
            $list.Select(0)
            Invoke-NotifierDeviceAction -Action notify
            (Get-NotifierNetwork -DataRoot $script:TrayDataRoot).devices[0].notify | Should -Be $true
            $script:SessionsForm.Tag.Net.Devices[0].Meta | Should -Match 'уведомления на ПК$'
            Get-NotifierDeviceKindText ([pscustomobject]@{ hooks = $false; name = 'Mac' }) | Should -Be 'Браузер · хуки не установлены'
            Get-NotifierDeviceKindText ([pscustomobject]@{ hooks = $false; name = 'iPhone' }) | Should -Be 'Браузер · только просмотр'
        }
        finally { $script:SessionsForm.Dispose(); $script:SessionsForm = $null }
    }
}
