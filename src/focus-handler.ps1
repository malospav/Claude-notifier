<#
.SYNOPSIS
Обработчик URL-протокола claude-notifier: — выводит на передний план окно сессии из события истории.

.DESCRIPTION
Вызывается Windows по клику на toast или пунктом истории трея:
  conhost.exe --headless powershell.exe ... -File focus-handler.ps1 "claude-notifier:focus?id=<guid>"
URI может прийти из любого источника (например, со страницы в браузере), поэтому принимается
только команда focus с GUID; событие ищется лишь в локальной истории. Код выхода всегда 0.
#>
param([string]$Uri = '')

Import-Module (Join-Path $PSScriptRoot 'lib\Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Window.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\History.psm1')

$script:UriPattern = '^claude-notifier:focus\?id=([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/?$'

function ConvertFrom-NotifierUri {
    <# .SYNOPSIS id события из "claude-notifier:focus?id=<guid>" или $null для любого другого URI. #>
    param([string]$Uri)
    if ([string]::IsNullOrEmpty($Uri)) { return $null }
    $m = [regex]::Match($Uri.Trim(), $script:UriPattern, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { return $null }
    return $m.Groups[1].Value.ToLowerInvariant()
}

function Invoke-NotifierFocus {
    <#
    .SYNOPSIS
    Логика обработчика без exit.

    .OUTPUTS
    'focused' | 'flashed' | 'closed' | 'invalid' | 'not-found' | 'failed'.
    #>
    param(
        [AllowEmptyString()][string]$Uri,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    try {
        $id = ConvertFrom-NotifierUri $Uri
        if ($null -eq $id) {
            Write-NotifierLog -Level INFO -Message 'focus: отклонён URI неизвестного формата' -DataRoot $DataRoot
            return 'invalid'
        }
        $event = Find-NotifierHistoryEvent -Id $id -DataRoot $DataRoot
        if ($null -eq $event) {
            Write-NotifierLog -Level INFO -Message "focus: событие $id не найдено в истории" -DataRoot $DataRoot
            return 'not-found'
        }

        $hwnd = [int64]0
        $win = $event.PSObject.Properties['window']
        if ($win -and $win.Value -and $win.Value.PSObject.Properties['hwnd']) { $hwnd = [int64]$win.Value.hwnd }
        $result = 'closed'
        if ($hwnd -ne 0) { $result = Set-SessionWindowFocus -Hwnd $hwnd }

        if ($result -eq 'closed') { [void](Set-NotifierHistoryStatus -Id $id -Status 'closed' -DataRoot $DataRoot) }
        Write-NotifierLog -Level INFO -Message "focus: событие $id → $result" -DataRoot $DataRoot
        return $result
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "focus: $($_.Exception.Message)" -DataRoot $DataRoot
        return 'failed'
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { [void](Invoke-NotifierFocus -Uri $Uri) } catch { }
    exit 0
}
