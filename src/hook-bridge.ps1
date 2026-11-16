<#
.SYNOPSIS
Точка входа хуков Claude Code: читает JSON из stdin, собирает событие v1 и передаёт его трею.

.DESCRIPTION
Вызывается из ~/.claude/settings.json (exec-форма, async: true):
  powershell.exe -NoProfile -NonInteractive -File hook-bridge.ps1 stop|notification|stopfailure
Никогда не мешает Claude Code: stdout пуст, код выхода всегда 0, ошибки только в лог.
Превью и текст сообщений в лог не пишутся.
#>
param([string]$Kind = '')

$script:BridgeRoot = $PSScriptRoot
$script:RetryCount = 3
$script:RetryDelayMs = 300

Import-Module (Join-Path $script:BridgeRoot 'lib\Log.psm1')
Import-Module (Join-Path $script:BridgeRoot 'lib\Config.psm1')
Import-Module (Join-Path $script:BridgeRoot 'lib\Event.psm1')
Import-Module (Join-Path $script:BridgeRoot 'lib\Ipc.psm1')
Import-Module (Join-Path $script:BridgeRoot 'lib\Window.psm1')

function Read-HookInput {
    # Весь stdin как UTF-8; если stdin не перенаправлен (ручной запуск), — пустая строка.
    if (-not [Console]::IsInputRedirected) { return '' }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Start-NotifierTray {
    # Запускает трей без окна консоли. Возвращает $true, если процесс запущен.
    param([string]$DataRoot)
    $tray = Join-Path $script:BridgeRoot 'ClaudeNotifier.Tray.ps1'
    if (-not (Test-Path -LiteralPath $tray -PathType Leaf)) {
        Write-NotifierLog -Level ERROR -Message "bridge: трей не найден: $tray" -DataRoot $DataRoot
        return $false
    }
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $conhost -ArgumentList @('--headless', "`"$ps`"", '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-File', "`"$tray`"") -WindowStyle Hidden | Out-Null
    Write-NotifierLog -Level INFO -Message 'bridge: трей не отвечал, запущен' -DataRoot $DataRoot
    return $true
}

function Wait-NotifierRetry([int]$Milliseconds) { Start-Sleep -Milliseconds $Milliseconds }

function Invoke-NotifierHookBridge {
    <#
    .SYNOPSIS
    Логика bridge без побочных эффектов процесса (exit): удобно тестировать.

    .OUTPUTS
    'sent' | 'sent-after-start' | 'disabled' | 'invalid' | 'undelivered' | 'failed'.
    #>
    param(
        [string]$Kind,
        [AllowEmptyString()][string]$InputJson,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    try {
        $config = Get-NotifierConfig -DataRoot $DataRoot
        $event = ConvertTo-NotifierEvent -HookKind $Kind -Json $InputJson -Config $config -DataRoot $DataRoot
        if ($null -eq $event) { return 'invalid' }
        if (-not $config.events[$event.type].enabled) { return 'disabled' }

        $event.window = Get-SessionWindow -Origin $event.origin
        if (Send-NotifierEvent -Event $event) { return 'sent' }

        [void](Start-NotifierTray -DataRoot $DataRoot)
        for ($i = 1; $i -le $script:RetryCount; $i++) {
            Wait-NotifierRetry $script:RetryDelayMs
            if (Send-NotifierEvent -Event $event) { return 'sent-after-start' }
        }
        Write-NotifierLog -Level ERROR -Message "bridge: событие '$($event.type)' не доставлено после $($script:RetryCount) повторов" -DataRoot $DataRoot
        return 'undelivered'
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "bridge: $($_.Exception.GetType().Name): $($_.Exception.Message)" -DataRoot $DataRoot
        return 'failed'
    }
}

# При dot-source (тесты) только объявляем функции.
if ($MyInvocation.InvocationName -ne '.') {
    try {
        [void](Invoke-NotifierHookBridge -Kind $Kind -InputJson (Read-HookInput))
    }
    catch { }
    exit 0
}
