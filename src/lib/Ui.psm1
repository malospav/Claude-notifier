Set-StrictMode -Version 2.0

# Элементы интерфейса в стиле Windows 11 (исходники — ui\*.cs рядом: тема, шторка, сфинкс, маскоты, карточки, элементы, хуки). Скомпилированная сборка кэшируется в
# <каталог claude-notifier>\cache по хэшу исходников: компилятор C# вызывается только после обновления.
$script:UiSourcePath = Join-Path $PSScriptRoot 'Ui.cs'

function Get-NotifierUiSources {
    <# .SYNOPSIS Файлы C# сборки ClaudeNotifier.Ui: lib\ui\*.cs (по имени). #>
    $files = @()
    if (Test-Path -LiteralPath $script:UiSourcePath) { $files += $script:UiSourcePath }   # прежний единый файл (если остался)
    $dir = Join-Path $PSScriptRoot 'ui'
    if (Test-Path -LiteralPath $dir) { $files += @(Get-ChildItem -LiteralPath $dir -Filter '*.cs' | Sort-Object Name | ForEach-Object { $_.FullName }) }
    return $files
}

function Import-NotifierUi {
    <#
    .SYNOPSIS
    Загружает типы ClaudeNotifier.Ui.*. Возвращает 'loaded' | 'cache' | 'compiled' | 'inline'.
    #>
    [CmdletBinding()]
    param([string]$CacheDir = (Join-Path $(if ($env:CLAUDE_NOTIFIER_HOME) { $env:CLAUDE_NOTIFIER_HOME } else { Join-Path $env:USERPROFILE '.claude-notifier' }) 'cache'))
    if ('ClaudeNotifier.Ui.Theme' -as [type]) { return 'loaded' }
    # WPF (3D-сфинкс) нужен только компилятору; во время работы он загружается сам при первом 3D-рендере,
    # а кадры, что уже на диске, рендерить не нужно — обычно WPF не загружается вовсе.
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $files = @(Get-NotifierUiSources)
    $source = (@($files | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`n//--file--`n")
    $refs = @('System.Windows.Forms', 'System.Drawing', 'PresentationCore', 'PresentationFramework', 'WindowsBase', 'System.Xaml')
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))
        $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
        $dll = Join-Path $CacheDir "ClaudeNotifier.Ui.$hash.dll"
        $result = 'cache'
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
            Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            $tmp = Join-Path $CacheDir "build.$PID.$([guid]::NewGuid().ToString('N')).dll"
            Add-Type -Path $files -ReferencedAssemblies $refs -OutputAssembly $tmp -OutputType Library
            Move-Item -LiteralPath $tmp -Destination $dll -Force
            $result = 'compiled'
        }
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) { [void][System.Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll)) }
        # Кадры 3D-сфинкса на диске — своя папка для каждой версии интерфейса; прежние удаляются.
        $sprites = Join-Path $CacheDir "sprites-$hash"
        [ClaudeNotifier.Ui.SphynxSprites]::DiskDir = $sprites
        foreach ($old in @(Get-ChildItem -LiteralPath $CacheDir -Directory -Filter 'sprites-*' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne (Split-Path -Leaf $sprites) })) {
            Remove-Item -LiteralPath $old.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Сборки прежних версий больше не нужны (загруженные из байтов файлы не заняты).
        # Сравнение по имени: пути бывают в коротком виде (OLEKSA~1).
        $keep = Split-Path -Leaf $dll
        foreach ($old in @(Get-ChildItem -LiteralPath $CacheDir -Filter 'ClaudeNotifier.Ui.*.dll' | Where-Object { $_.Name -ne $keep })) {
            Remove-Item -LiteralPath $old.FullName -Force -ErrorAction SilentlyContinue
        }
        return $result
    }
    catch {
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) {
            Add-Type -AssemblyName PresentationCore, PresentationFramework, WindowsBase, System.Xaml
            Add-Type -Path $files -ReferencedAssemblies $refs
        }
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
