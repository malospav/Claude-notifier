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
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    $files = @(Get-NotifierUiSources)
    $source = (@($files | ForEach-Object { [IO.File]::ReadAllText($_, [Text.Encoding]::UTF8) }) -join "`n//--file--`n")
    $refs = @('System.Windows.Forms', 'System.Drawing', 'System.Management')   # System.Management — температура ЦП из WMI мониторов
    $tmp = $null
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($source))
        $hash = -join ($bytes[0..7] | ForEach-Object { $_.ToString('x2') })
        $dll = Join-Path $CacheDir "ClaudeNotifier.Ui.$hash.dll"
        $result = 'cache'
        if (-not (Test-Path -LiteralPath $dll -PathType Leaf)) {
            Add-Type -AssemblyName System.Management
            New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
            $tmp = Join-Path $CacheDir "build.$PID.$([guid]::NewGuid().ToString('N')).dll"
            Add-Type -Path $files -ReferencedAssemblies $refs -OutputAssembly $tmp -OutputType Library
            Move-Item -LiteralPath $tmp -Destination $dll -Force
            $result = 'compiled'
        }
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) { [void][System.Reflection.Assembly]::Load([IO.File]::ReadAllBytes($dll)) }
        # Кадры прежнего объёмного сфинкса больше не нужны — папки sprites-* удаляются.
        foreach ($old in @(Get-ChildItem -LiteralPath $CacheDir -Directory -Filter 'sprites-*' -ErrorAction SilentlyContinue)) {
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
        # Кэш сборки не сработал: причину — вызывающему (трей пишет её в журнал), недописанную сборку — удалить.
        $script:UiImportError = $_.Exception.Message
        if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        if (-not ('ClaudeNotifier.Ui.Theme' -as [type])) {
            Add-Type -AssemblyName System.Management
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

$script:UiImportError = $null

# Эталонные картинки маскотов (tests\golden): каждый маскот в каждом статусе, кадр без анимации.
$script:GoldenStates = @('waiting', 'working', 'permission', 'error', 'none')

function Get-NotifierGoldenStates { return $script:GoldenStates }

function New-NotifierMascotFrame {
    <#
    .SYNOPSIS
    Кадр маскота для сравнения с эталоном: Width×Height на чёрном фоне, без анимации (t = 0), seed = 1.
    Возвращает Bitmap (освобождает вызывающий).
    #>
    param([Parameter(Mandatory = $true)][string]$Kind, [Parameter(Mandatory = $true)][string]$State, [int]$Width = 104, [int]$Height = 84)
    $bmp = New-Object System.Drawing.Bitmap $Width, $Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Black)
        $r = New-Object System.Drawing.RectangleF(($Width * 0.12), ($Height * 0.16), ($Width * 0.76), ($Height * 0.74))
        [ClaudeNotifier.Ui.Mascot]::PaintKind($g, $r, $Kind, $State, 0, 1, $false, $null)
    }
    finally { $g.Dispose() }
    return $bmp
}

function Compare-NotifierBitmap {
    <#
    .SYNOPSIS
    Доля заметно отличающихся пикселей (любой канал больше чем на Threshold из 255) между двумя картинками одного
    размера; разный размер — 1. -Diff — сохранить картинку отличий (красным) по этому пути.
    #>
    param([Parameter(Mandatory = $true)][System.Drawing.Bitmap]$A, [Parameter(Mandatory = $true)][System.Drawing.Bitmap]$B, [int]$Threshold = 48, [string]$Diff = '')
    if ($A.Width -ne $B.Width -or $A.Height -ne $B.Height) { return 1.0 }
    $rect = New-Object System.Drawing.Rectangle(0, 0, $A.Width, $A.Height)
    $fmt = [System.Drawing.Imaging.PixelFormat]::Format32bppArgb
    $da = $A.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
    $db = $B.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, $fmt)
    try {
        $n = [Math]::Abs($da.Stride) * $A.Height
        $ba = New-Object byte[] $n; $bb = New-Object byte[] $n
        [Runtime.InteropServices.Marshal]::Copy($da.Scan0, $ba, 0, $n)
        [Runtime.InteropServices.Marshal]::Copy($db.Scan0, $bb, 0, $n)
    }
    finally { $A.UnlockBits($da); $B.UnlockBits($db) }
    $bad = [ClaudeNotifier.Ui.PixelDiff]::Count($ba, $bb, $Threshold)
    if ($Diff -and $bad -gt 0) {
        $out = New-Object System.Drawing.Bitmap $A.Width, $A.Height
        try {
            for ($y = 0; $y -lt $A.Height; $y++) {
                for ($x = 0; $x -lt $A.Width; $x++) {
                    $p = $A.GetPixel($x, $y); $q = $B.GetPixel($x, $y)
                    $d = [Math]::Max([Math]::Abs($p.R - $q.R), [Math]::Max([Math]::Abs($p.G - $q.G), [Math]::Abs($p.B - $q.B)))
                    if ($d -gt $Threshold) { $out.SetPixel($x, $y, [System.Drawing.Color]::Red) } else { $out.SetPixel($x, $y, [System.Drawing.Color]::FromArgb(255, [int]($p.R / 3), [int]($p.G / 3), [int]($p.B / 3))) }
                }
            }
            $out.Save($Diff, [System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $out.Dispose() }
    }
    return [double]$bad / ($A.Width * $A.Height)
}

function Get-NotifierUiImportError {
    <# .SYNOPSIS Почему последняя загрузка интерфейса пошла медленным путём (без кэша сборки), или $null. #>
    return $script:UiImportError
}

Export-ModuleMember -Function Import-NotifierUi, Get-NotifierUiImportError, Get-NotifierTrayState, Format-NotifierTrayTooltip, Get-NotifierGoldenStates, New-NotifierMascotFrame, Compare-NotifierBitmap
