<#
.SYNOPSIS
Точка входа хуков Claude Code: читает JSON из stdin, собирает событие v1 и передаёт его трею.

.DESCRIPTION
Вызывается из ~/.claude/settings.json (exec-форма, async: true):
  powershell.exe -NoProfile -NonInteractive -File hook-bridge.ps1 stop|notification|stopfailure|sessionstart|prompt|sessionend
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
Import-Module (Join-Path $script:BridgeRoot 'lib\Transcript.psm1')
Import-Module (Join-Path $script:BridgeRoot 'lib\Requests.psm1')

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

function Send-NotifierEventToTray {
    <#
    .SYNOPSIS
    Доставляет событие трею; если трей не отвечает — запускает его и повторяет.
    'sent' | 'sent-after-start' | 'undelivered'.
    #>
    param($Event, [string]$DataRoot)
    if (Send-NotifierEvent -Event $Event) { return 'sent' }
    [void](Start-NotifierTray -DataRoot $DataRoot)
    for ($i = 1; $i -le $script:RetryCount; $i++) {
        Wait-NotifierRetry $script:RetryDelayMs
        if (Send-NotifierEvent -Event $Event) { return 'sent-after-start' }
    }
    Write-NotifierLog -Level ERROR -Message "bridge: событие '$($Event.type)' не доставлено после $($script:RetryCount) повторов" -DataRoot $DataRoot
    return 'undelivered'
}

function Invoke-NotifierPermissionHook {
    <#
    .SYNOPSIS
    Хук PermissionRequest (синхронный): показывает запрос в трее, окне и на телефоне и ждёт решения.
    Возвращает JSON-ответ для Claude Code или '' — тогда решает обычный диалог Claude.
    #>
    param([AllowEmptyString()][string]$InputJson, [string]$DataRoot = (Get-NotifierDataRoot))
    try {
        $config = Get-NotifierConfig -DataRoot $DataRoot
        if (-not $config.approvals.enabled) { return '' }
        if (Test-NotifierNestedClaude) { return '' }   # служебный Claude внутри другого сеанса — решает он сам
        # Приложение Claude показывает свой диалог параллельно с хуком («кто решит первым»), поэтому там ждём
        # полный срок. В CLI хук может выполняться до диалога — там ждём только cliWaitSeconds (по умолчанию 0).
        $wait = $config.approvals.waitSeconds
        if ($env:CLAUDE_CODE_ENTRYPOINT -ne 'claude-desktop') { $wait = $config.approvals.cliWaitSeconds }
        if ($wait -le 0) { return '' }
        $hook = ConvertFrom-Json -InputObject $InputJson -ErrorAction Stop
        $req = New-NotifierPermissionRequest -HookInput $hook -WaitSeconds $wait -DataRoot $DataRoot
        $event = ConvertTo-NotifierEvent -HookKind permreq -Json $InputJson -Config $config -DataRoot $DataRoot
        if ($null -eq $event) { return '' }
        $title = Get-NotifierEventTitle -Type permission
        if ($event.project) { $title = "$title $([char]0x00B7) $($event.project)" }
        $event.title = $title
        $event.preview = [string]$req.title
        $event | Add-Member -NotePropertyName request_id -NotePropertyValue $req.id -Force
        $event.window = Get-SessionWindow -Origin $event.origin
        if ((Send-NotifierEventToTray -Event $event -DataRoot $DataRoot) -eq 'undelivered') {
            Remove-Item -LiteralPath (Join-Path $DataRoot "requests\perm-$($req.id).json") -Force -ErrorAction SilentlyContinue
            return ''
        }
        $decision = Wait-NotifierDecision -Request $req -DataRoot $DataRoot
        if ($null -eq $decision) { return '' }
        Write-NotifierLog -Level INFO -Message "bridge: запрос $($req.id) решён в приложении: $($decision.behavior)" -DataRoot $DataRoot
        return (ConvertTo-NotifierDecisionOutput -Request $req -Decision $decision)
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "bridge: запрос разрешения: $($_.Exception.Message)" -DataRoot $DataRoot
        return ''
    }
}

function Invoke-NotifierReplyHook {
    <#
    .SYNOPSIS
    Хук Stop с asyncRewake: ждёт быстрого ответа из приложения. Возвращает текст для Claude или $null.
    #>
    param([AllowEmptyString()][string]$InputJson, [string]$DataRoot = (Get-NotifierDataRoot))
    try {
        $config = Get-NotifierConfig -DataRoot $DataRoot
        if (-not $config.quickReplies.enabled) { return $null }
        if (Test-NotifierNestedClaude) { return $null }   # служебный Claude (сводка и т. п.) — быстрый ответ не ждём
        $hook = ConvertFrom-Json -InputObject $InputJson -ErrorAction Stop
        $sid = [string]$hook.session_id
        if ($sid -eq '') { return $null }
        $wait = New-NotifierReplyWait -SessionId $sid -Minutes $config.quickReplies.minutes -DataRoot $DataRoot
        $text = Wait-NotifierReply -Wait $wait -DataRoot $DataRoot
        if ($null -eq $text) { return $null }
        Write-NotifierLog -Level INFO -Message 'bridge: быстрый ответ передан Claude' -DataRoot $DataRoot
        return "Пользователь ответил через Claude Notifier (быстрый ответ вместо сообщения в чате):`n$text"
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "bridge: быстрый ответ: $($_.Exception.Message)" -DataRoot $DataRoot
        return $null
    }
}

function Write-Utf8([System.IO.Stream]$Stream, [string]$Text) {
    # Консольный вывод PowerShell 5.1 не в UTF-8: пишем байты напрямую.
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($Text)
    $Stream.Write($bytes, 0, $bytes.Length)
    $Stream.Flush()
}

function Invoke-NotifierHookBridge {
    <#
    .SYNOPSIS
    Логика bridge без побочных эффектов процесса (exit): удобно тестировать.

    .OUTPUTS
    'sent' | 'sent-after-start' | 'disabled' | 'invalid' | 'nested' | 'undelivered' | 'failed'.
    #>
    param(
        [string]$Kind,
        [AllowEmptyString()][string]$InputJson,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    try {
        # Служебный Claude внутри другого сеанса (сводка через «claude -p» и т. п.) — не отдельный сеанс в шторке.
        if (Test-NotifierNestedClaude) { return 'nested' }
        $config = Get-NotifierConfig -DataRoot $DataRoot
        $event = ConvertTo-NotifierEvent -HookKind $Kind -Json $InputJson -Config $config -DataRoot $DataRoot
        if ($null -eq $event) { return 'invalid' }
        if ($config.events.ContainsKey($event.type) -and -not $config.events[$event.type].enabled) { return 'disabled' }

        $event.window = Get-SessionWindow -Origin $event.origin
        Add-NotifierEventDetails -Event $event -Kind $Kind -InputJson $InputJson -Config $config -DataRoot $DataRoot
        return (Send-NotifierEventToTray -Event $event -DataRoot $DataRoot)
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "bridge: $($_.Exception.GetType().Name): $($_.Exception.Message)" -DataRoot $DataRoot
        return 'failed'
    }
}

# При dot-source (тесты) только объявляем функции.
if ($MyInvocation.InvocationName -ne '.') {
    $code = 0
    try {
        switch ($Kind) {
            'permreq' {
                $out = Invoke-NotifierPermissionHook -InputJson (Read-HookInput)
                if ($out) { Write-Utf8 ([Console]::OpenStandardOutput()) $out }
            }
            'replywait' {
                # asyncRewake: код 2 будит Claude, текст из stderr приходит ему напоминанием.
                $text = Invoke-NotifierReplyHook -InputJson (Read-HookInput)
                if ($text) { Write-Utf8 ([Console]::OpenStandardError()) $text; $code = 2 }
            }
            default { [void](Invoke-NotifierHookBridge -Kind $Kind -InputJson (Read-HookInput)) }
        }
    }
    catch { }
    exit $code
}
