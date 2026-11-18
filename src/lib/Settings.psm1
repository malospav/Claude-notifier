Set-StrictMode -Version 2.0

# Хуки, которые ставит claude-notifier (architecture.md §4): событие Claude Code → (matcher, аргумент bridge).
# Via = 'curl' — хук запускает встроенный в Windows curl.exe (~20 мс) и отправляет JSON трею на 127.0.0.1;
# окно сеанса трей находит сам. Остальные — PowerShell-мост: SessionStart заодно запускает трей, если он не
# работает; PermissionRequest и быстрый ответ ждут решения в отдельном процессе.
$script:HookSpecs = @(
    @{ Event = 'Stop'; Matcher = $null; Kind = 'stop'; Via = 'curl' },
    @{ Event = 'Notification'; Matcher = 'permission_prompt|elicitation_dialog|agent_needs_input'; Kind = 'notification'; Via = 'curl' },
    @{ Event = 'StopFailure'; Matcher = $null; Kind = 'stopfailure'; Via = 'curl' },
    # Окно «Сеансы»: начало, новый запрос (статус «Работает»), завершение сеанса.
    @{ Event = 'SessionStart'; Matcher = $null; Kind = 'sessionstart' },
    @{ Event = 'UserPromptSubmit'; Matcher = $null; Kind = 'prompt'; Via = 'curl' },
    @{ Event = 'SessionEnd'; Matcher = $null; Kind = 'sessionend'; Via = 'curl' },
    # Ответы из приложения (ADR-008): синхронный PermissionRequest ждёт решения; Stop с asyncRewake — быстрого ответа.
    @{ Event = 'PermissionRequest'; Matcher = $null; Kind = 'permreq'; Mode = 'sync'; Timeout = 3700 },
    @{ Event = 'Stop'; Matcher = $null; Kind = 'replywait'; Mode = 'rewake'; Timeout = 14700 }
)
$script:Marker = 'claude-notifier\app\hook-bridge.ps1'
$script:CurlMarker = '/claude-notifier/hook/'
$script:StatusLineMarker = 'claude-notifier/app/statusline.ps1'

function Test-NotifierStatusLine {
    <# .SYNOPSIS $true, если statusLine — наш (команда указывает на claude-notifier\app\statusline.ps1). #>
    param($StatusLine)
    if ($StatusLine -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $cmd = $StatusLine.PSObject.Properties['command']
    if ($null -eq $cmd -or $cmd.Value -isnot [string]) { return $false }
    return ($cmd.Value.Replace('\', '/').IndexOf($script:StatusLineMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Set-NotifierStatusLine {
    <#
    .SYNOPSIS
    Ставит наш statusLine. Возвращает прежний statusLine пользователя (если он был и не наш) — его
    нужно сохранить в config.json (chainStatusLine), иначе $null.

    .DESCRIPTION
    Команда — строка, которую Claude Code выполняет в оболочке (Git Bash или PowerShell), поэтому
    пути записаны через прямые слэши, а powershell.exe — без кавычек (в пути нет пробелов).
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$AppRoot
    )
    $previous = $null
    $current = $Settings.PSObject.Properties['statusLine']
    if ($current -and -not (Test-NotifierStatusLine $current.Value)) { $previous = $current.Value }
    $ps = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe').Replace('\', '/')
    $script = (Join-Path $AppRoot 'statusline.ps1').Replace('\', '/')
    $ours = [pscustomobject][ordered]@{
        type    = 'command'
        command = "$ps -NoProfile -NonInteractive -File `"$script`""
    }
    $Settings | Add-Member -NotePropertyName statusLine -NotePropertyValue $ours -Force
    return $previous
}

function Restore-NotifierStatusLine {
    <#
    .SYNOPSIS
    Если statusLine наш — возвращает прежний (Previous) или удаляет ключ. Чужой statusLine не трогает.
    Возвращает $true, если настройки изменились.
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        $Previous
    )
    $current = $Settings.PSObject.Properties['statusLine']
    if ($null -eq $current -or -not (Test-NotifierStatusLine $current.Value)) { return $false }
    if ($null -ne $Previous) { $current.Value = $Previous }
    else { $Settings.PSObject.Properties.Remove('statusLine') }
    return $true
}

function Read-ClaudeSettings {
    <#
    .SYNOPSIS
    Читает settings.json. Нет файла → пустой объект. Невалидный файл → исключение с понятным текстом.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return [pscustomobject]@{} }
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    if ($text.Trim() -eq '') { return [pscustomobject]@{} }
    try { $obj = $text | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "settings.json не является корректным JSON ($Path): $($_.Exception.Message)" }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) {
        throw "settings.json должен содержать JSON-объект ($Path)"
    }
    $hooks = $obj.PSObject.Properties['hooks']
    if ($hooks) {
        if ($hooks.Value -isnot [System.Management.Automation.PSCustomObject]) {
            throw "settings.json: поле 'hooks' должно быть объектом ($Path)"
        }
        foreach ($ev in $hooks.Value.PSObject.Properties) {
            if ($ev.Value -isnot [array]) { throw "settings.json: 'hooks.$($ev.Name)' должно быть массивом ($Path)" }
        }
    }
    return $obj
}

function Test-NotifierHook {
    <# .SYNOPSIS $true, если hook-объект поставлен claude-notifier (args: app\hook-bridge.ps1 или адрес /claude-notifier/hook/). #>
    param($Hook)
    if ($Hook -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $argsProp = $Hook.PSObject.Properties['args']
    if ($null -eq $argsProp) { return $false }
    $line = @($argsProp.Value) -join ' '
    return ($line.IndexOf($script:Marker, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $line.IndexOf($script:CurlMarker, [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Remove-NotifierHooks {
    <#
    .SYNOPSIS
    Удаляет из настроек все hook-объекты claude-notifier; пустые группы, события и секцию hooks убирает.

    .OUTPUTS
    Число удалённых hook-объектов.
    #>
    param([Parameter(Mandatory = $true)]$Settings)
    $hooksProp = $Settings.PSObject.Properties['hooks']
    if ($null -eq $hooksProp) { return 0 }
    $removed = 0
    foreach ($ev in @($hooksProp.Value.PSObject.Properties)) {
        $groups = New-Object System.Collections.ArrayList
        foreach ($group in @($ev.Value)) {
            $inner = $null
            if ($group -is [System.Management.Automation.PSCustomObject]) { $inner = $group.PSObject.Properties['hooks'] }
            if ($null -eq $inner) { [void]$groups.Add($group); continue }
            $kept = @(@($inner.Value) | Where-Object { -not (Test-NotifierHook $_) })
            $removed += @($inner.Value).Count - $kept.Count
            if ($kept.Count -eq 0 -and @($inner.Value).Count -gt 0) { continue }
            $group.hooks = $kept
            [void]$groups.Add($group)
        }
        if ($groups.Count -eq 0) { $hooksProp.Value.PSObject.Properties.Remove($ev.Name) }
        else { $ev.Value = $groups.ToArray() }
    }
    if (@($hooksProp.Value.PSObject.Properties).Count -eq 0) { $Settings.PSObject.Properties.Remove('hooks') }
    return $removed
}

function Add-NotifierHooks {
    <#
    .SYNOPSIS
    Добавляет хуки claude-notifier ($script:HookSpecs) (exec-форма, async) с путём к <AppRoot>\hook-bridge.ps1.
    Вызывайте после Remove-NotifierHooks, чтобы не было дублей.
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [int]$Port = 47611,
        [string]$Curl = (Join-Path $env:SystemRoot 'System32\curl.exe')
    )
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $bridge = Join-Path $AppRoot 'hook-bridge.ps1'
    $hasCurl = Test-Path -LiteralPath $Curl -PathType Leaf
    if ($null -eq $Settings.PSObject.Properties['hooks']) {
        $Settings | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
    }
    foreach ($spec in $script:HookSpecs) {
        $hook = [ordered]@{
            type    = 'command'
            command = $ps
            args    = @('-NoProfile', '-NonInteractive', '-File', $bridge, $spec.Kind)
        }
        if ($hasCurl -and $spec.ContainsKey('Via') -and $spec.Via -eq 'curl') {
            # JSON хука из stdin → трею; переменные окружения сеанса — в заголовках (без оболочки).
            $hook.command = $Curl
            $hook.args = @('-s', '-m', '5', '-o', 'NUL', '-H', 'X-Claude-Notifier: hook',
                '--variable', '%CLAUDE_CODE_ENTRYPOINT=', '--variable', '%CLAUDE_CODE_HOST_SESSION_ID=',
                '--expand-header', 'X-Claude-Entry: {{CLAUDE_CODE_ENTRYPOINT}}', '--expand-header', 'X-Claude-Host: {{CLAUDE_CODE_HOST_SESSION_ID}}',
                '--data-binary', '@-', "http://127.0.0.1:$Port$($script:CurlMarker)$($spec.Kind)")
        }
        $mode = ''
        if ($spec.ContainsKey('Mode')) { $mode = [string]$spec.Mode }
        switch ($mode) {
            'sync' { $hook.timeout = $spec.Timeout }
            'rewake' { $hook.asyncRewake = $true; $hook.timeout = $spec.Timeout }
            default { $hook.async = $true }
        }
        $hook = [pscustomobject]$hook
        $group = [ordered]@{}
        if ($spec.Matcher) { $group.matcher = $spec.Matcher }
        $group.hooks = @($hook)
        $existing = $Settings.hooks.PSObject.Properties[$spec.Event]
        if ($existing) { $existing.Value = @($existing.Value) + [pscustomobject]$group }
        else { $Settings.hooks | Add-Member -NotePropertyName $spec.Event -NotePropertyValue @([pscustomobject]$group) }
    }
}

function ConvertTo-PrettyJson {
    <#
    .SYNOPSIS
    Сериализует объект в JSON с отступом 2 пробела (ConvertTo-Json в PS 5.1 даёт неровные отступы).
    #>
    param([Parameter(Mandatory = $true)]$InputObject)
    $compact = $InputObject | ConvertTo-Json -Depth 30 -Compress
    $sb = New-Object System.Text.StringBuilder
    $indent = 0
    $inString = $false
    $nl = [Environment]::NewLine
    for ($i = 0; $i -lt $compact.Length; $i++) {
        $c = $compact[$i]
        if ($inString) {
            [void]$sb.Append($c)
            if ($c -eq '\') { $i++; [void]$sb.Append($compact[$i]) }
            elseif ($c -eq '"') { $inString = $false }
            continue
        }
        switch ($c) {
            '"' { $inString = $true; [void]$sb.Append($c) }
            { $_ -eq '{' -or $_ -eq '[' } {
                $close = if ($c -eq '{') { '}' } else { ']' }
                if ($i + 1 -lt $compact.Length -and $compact[$i + 1] -eq $close) {
                    [void]$sb.Append($c).Append($close); $i++
                }
                else {
                    $indent++
                    [void]$sb.Append($c).Append($nl).Append(' ' * (2 * $indent))
                }
            }
            { $_ -eq '}' -or $_ -eq ']' } {
                $indent--
                [void]$sb.Append($nl).Append(' ' * (2 * $indent)).Append($c)
            }
            ',' { [void]$sb.Append(',').Append($nl).Append(' ' * (2 * $indent)) }
            ':' { [void]$sb.Append(': ') }
            default { [void]$sb.Append($c) }
        }
    }
    return $sb.ToString()
}

function Save-ClaudeSettings {
    <#
    .SYNOPSIS
    Записывает настройки атомарно (временный файл + замена). Если файл уже был — сначала копия settings.json.bak-<yyyyMMddHHmmss>.

    .OUTPUTS
    Путь резервной копии или $null.
    #>
    param(
        [Parameter(Mandatory = $true)]$Settings,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $backup = $null
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $backup = "$Path.bak-" + (Get-Date).ToString('yyyyMMddHHmmss')
        Copy-Item -LiteralPath $Path -Destination $backup -Force
    }
    $tmp = "$Path.tmp-$PID"
    [IO.File]::WriteAllText($tmp, (ConvertTo-PrettyJson $Settings) + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding $false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return $backup
}

Export-ModuleMember -Function Test-NotifierStatusLine, Set-NotifierStatusLine, Restore-NotifierStatusLine, Read-ClaudeSettings, Test-NotifierHook, Remove-NotifierHooks, Add-NotifierHooks, ConvertTo-PrettyJson, Save-ClaudeSettings
