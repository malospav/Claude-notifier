Set-StrictMode -Version 2.0

# Элементы интерфейса в стиле Windows 11 (исходник — Ui.cs рядом). Скомпилированная сборка кэшируется в
# %LOCALAPPDATA%\claude-notifier\cache по хэшу исходника: компилятор C# вызывается только после обновления.
$script:UiSourcePath = Join-Path $PSScriptRoot 'Ui.cs'

function Import-NotifierUi {
    <#
    .SYNOPSIS
    Загружает типы ClaudeNotifier.Ui.*. Возвращает 'loaded' | 'cache' | 'compiled' | 'inline'.
    #>
    [CmdletBinding()]
    param([string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'claude-notifier\cache'))
    if ('ClaudeNotifier.Ui.Theme' -as [type]) { return 'loaded' }
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $source = [IO.File]::ReadAllText($script:UiSourcePath, [Text.Encoding]::UTF8)
    $refs = @('System.Windows.Forms', 'System.Drawing')
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))
        $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
        $dll = Join-Path $CacheDir "ClaudeNotifier.Ui.$hash.dll"
        $result = 'cache'
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            $tmp = Join-Path $CacheDir "build.$PID.$([guid]::NewGuid().ToString('N')).dll"
            Add-Type -TypeDefinition $source -ReferencedAssemblies $refs -OutputAssembly $tmp -OutputType Library
            Move-Item -LiteralPath $tmp -Destination $dll -Force
            $result = 'compiled'
        }
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) { [void][System.Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll)) }
        # Сборки прежних версий больше не нужны (загруженные из байтов файлы не заняты).
        # Сравнение по имени: пути бывают в коротком виде (OLEKSA~1).
        $keep = Split-Path -Leaf $dll
        foreach ($old in @(Get-ChildItem -LiteralPath $CacheDir -Filter 'ClaudeNotifier.Ui.*.dll' | Where-Object { $_.Name -ne $keep })) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
        return $result
    }
    catch {
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) { Add-Type -TypeDefinition $source -ReferencedAssemblies $refs }
        return 'inline'
    }
}

function Get-NotifierTrayState {
    <#
    .SYNOPSIS
    Общий статус для точки в трее по списку сеансов: permission > error > working > waiting > none.
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $states = @($Sessions | ForEach-Object { if ($_.PSObject.Properties['state']) { [string]$_.state } })
    foreach ($s in @('permission', 'error', 'working', 'waiting')) { if ($states -contains $s) { return $s } }
    return 'none'
}

function Format-NotifierTrayTooltip {
    <#
    .SYNOPSIS
    Подсказка иконки трея (не длиннее 63 символов): «Claude · 1 разрешение · 2 работают · 1 ждёт».
    #>
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Sessions = @())
    $count = @{ permission = 0; error = 0; working = 0; waiting = 0 }
    foreach ($s in $Sessions) {
        if ($s.PSObject.Properties['state'] -and $count.ContainsKey([string]$s.state)) { $count[[string]$s.state]++ }
    }
    $parts = @()
    if ($count.permission) { $parts += "$($count.permission) ждёт разрешения" }
    if ($count.error) { $parts += "$($count.error) с ошибкой" }
    if ($count.working) { $parts += "$($count.working) работает" }
    if ($count.waiting) { $parts += "$($count.waiting) ждёт ответа" }
    if ($parts.Count -eq 0) { return 'Claude · сеансов нет' }
    $text = 'Claude · ' + ($parts -join ' · ')
    if ($text.Length -gt 63) { $text = $text.Substring(0, 62) + [char]0x2026 }
    return $text
}

Export-ModuleMember -Function Import-NotifierUi, Get-NotifierTrayState, Format-NotifierTrayTooltip
