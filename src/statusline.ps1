<#
.SYNOPSIS
Строка статуса Claude Code: «<модель> · ctx N% · 5ч N% · нед N%» + уведомления о лимитах (ADR-005).

.DESCRIPTION
Claude Code передаёт JSON на stdin и показывает то, что скрипт печатает. Если у пользователя
была своя строка статуса (config.json → chainStatusLine), она вызывается с тем же stdin и её
вывод печатается первым. Пересечение порога лимита отправляется трею (без автозапуска трея).
Любая ошибка → печатается хотя бы имя модели, код выхода 0.
#>
param()

Import-Module (Join-Path $PSScriptRoot 'lib\Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Ipc.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Limits.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Usage.psm1')

$script:ChainTimeoutMs = 3000
$script:Sep = " $([char]0x00B7) "

function Get-StatusProp($Object, [string[]]$Path) {
    $cur = $Object
    foreach ($name in $Path) {
        if ($cur -isnot [System.Management.Automation.PSCustomObject]) { return $null }
        $p = $cur.PSObject.Properties[$name]
        if ($null -eq $p) { return $null }
        $cur = $p.Value
    }
    return $cur
}

function Format-Percent($Value) {
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal]) { return "$([int][Math]::Floor([double]$Value))%" }
    return $null
}

function Format-NotifierStatusLine {
    <#
    .SYNOPSIS
    Строка «<модель> · ctx N% · 5ч N% · нед N%» из объекта JSON statusLine; отсутствующие части пропускаются.
    #>
    param($Status)
    $parts = @()
    $model = Get-StatusProp $Status @('model', 'display_name')
    if ($model -is [string] -and $model -ne '') { $parts += $model }
    $ctx = Format-Percent (Get-StatusProp $Status @('context_window', 'used_percentage'))
    if ($ctx) { $parts += "ctx $ctx" }
    $five = Format-Percent (Get-StatusProp $Status @('rate_limits', 'five_hour', 'used_percentage'))
    if ($five) { $parts += "5ч $five" }
    $week = Format-Percent (Get-StatusProp $Status @('rate_limits', 'seven_day', 'used_percentage'))
    if ($week) { $parts += "нед $week" }
    return ($parts -join $script:Sep)
}

function Get-ChainShell {
    # Та же оболочка, что у Claude Code на Windows: Git Bash, иначе PowerShell.
    $candidates = @($env:CLAUDE_CODE_GIT_BASH_PATH, (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'))
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return @{ File = $c; Args = @('-c') } }
    }
    return @{ File = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'); Args = @('-NoProfile', '-NonInteractive', '-Command') }
}

function Invoke-ChainedStatusLine {
    <#
    .SYNOPSIS
    Выполняет прежнюю команду строки статуса с тем же stdin; возвращает её вывод (без хвостовых
    переводов строк) или '' при ошибке/таймауте.
    #>
    param([Parameter(Mandatory = $true)][string]$Command, [AllowEmptyString()][string]$StdinText, [string]$DataRoot = (Get-NotifierDataRoot))
    $shell = Get-ChainShell
    $psi = New-Object System.Diagnostics.ProcessStartInfo $shell.File
    $quoted = @($shell.Args) + @($Command) | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }
    $psi.Arguments = $quoted -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding $false
    # Writer для StandardInput создаётся в Console.InputEncoding и, если это UTF-8 с BOM, пишет BOM
    # в начало stdin дочернего процесса. На время запуска ставим UTF-8 без BOM.
    $oldInputEncoding = $null
    try { $oldInputEncoding = [Console]::InputEncoding; [Console]::InputEncoding = New-Object System.Text.UTF8Encoding $false } catch { }
    try {
        $p = [System.Diagnostics.Process]::Start($psi)
        if ($null -ne $oldInputEncoding) { try { [Console]::InputEncoding = $oldInputEncoding } catch { } }
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($StdinText)
        $p.StandardInput.BaseStream.Write($bytes, 0, $bytes.Length)
        $p.StandardInput.Close()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        [void]$p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($script:ChainTimeoutMs)) {
            try { $p.Kill() } catch { }
            Write-NotifierLog -Level WARN -Message "statusline: прежняя строка статуса не ответила за $($script:ChainTimeoutMs) мс" -DataRoot $DataRoot
            return ''
        }
        return $outTask.Result.TrimEnd("`r", "`n")
    }
    catch {
        Write-NotifierLog -Level WARN -Message "statusline: прежняя строка статуса не запустилась: $($_.Exception.Message)" -DataRoot $DataRoot
        return ''
    }
}

function Send-NotifierLimitEvents {
    # Отправляет события о пересечении порогов; трей не запускается (statusLine вызывается часто).
    param([AllowEmptyString()][string]$StdinText, [string]$DataRoot)
    # Расход для полос в окне: строка статуса CLI — второй источник после сервера Anthropic.
    try {
        $rl = (ConvertFrom-Json -InputObject $StdinText -ErrorAction Stop).rate_limits
        if ($rl) { [void](Save-NotifierUsage -Windows (ConvertFrom-NotifierUsageWindows -Object $rl -PercentField used_percentage) -Source cli -DataRoot $DataRoot) }
    }
    catch { }
    foreach ($r in @(Test-NotifierLimits -StatusJson $StdinText -DataRoot $DataRoot)) {
        if ($null -eq $r) { continue }
        $event = New-NotifierLimitEvent -Result $r -StatusJson $StdinText
        if (-not (Send-NotifierEvent -Event $event)) {
            Write-NotifierLog -Level WARN -Message "statusline: событие о лимите ($($r.Window) $($r.Threshold) %) не доставлено: трей не запущен" -DataRoot $DataRoot
        }
    }
}

function Invoke-NotifierStatusLine {
    <#
    .SYNOPSIS
    Логика строки статуса без вывода в консоль. Возвращает текст для печати.
    #>
    param([AllowEmptyString()][string]$StdinText, [string]$DataRoot = (Get-NotifierDataRoot))
    $status = $null
    try { $status = $StdinText | ConvertFrom-Json -ErrorAction Stop } catch { }
    $fallback = [string](Get-StatusProp $status @('model', 'display_name'))
    try {
        $config = Get-NotifierConfig -DataRoot $DataRoot
        $lines = @()
        if ($null -ne $config.chainStatusLine) {
            $prev = Invoke-ChainedStatusLine -Command ([string]$config.chainStatusLine.command) -StdinText $StdinText -DataRoot $DataRoot
            if ($prev -ne '') { $lines += $prev }
        }
        $own = Format-NotifierStatusLine $status
        if ($own -ne '') { $lines += $own }
        try { Send-NotifierLimitEvents -StdinText $StdinText -DataRoot $DataRoot }
        catch { Write-NotifierLog -Level ERROR -Message "statusline: лимиты: $($_.Exception.Message)" -DataRoot $DataRoot }
        return ($lines -join "`n")
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "statusline: $($_.Exception.Message)" -DataRoot $DataRoot
        return $fallback
    }
}

function Read-StatusInput {
    if (-not [Console]::IsInputRedirected) { return '' }
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), (New-Object System.Text.UTF8Encoding $false))
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

if ($MyInvocation.InvocationName -ne '.') {
    $text = ''
    try {
        $text = Invoke-NotifierStatusLine -StdinText (Read-StatusInput)
    }
    catch { }
    # Claude Code читает вывод как UTF-8; консольная кодировка Windows (CP866) испортила бы «5ч», «нед», «·».
    $out = [Console]::OpenStandardOutput()
    $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($text + "`n")
    $out.Write($bytes, 0, $bytes.Length)
    $out.Flush()
    exit 0
}
