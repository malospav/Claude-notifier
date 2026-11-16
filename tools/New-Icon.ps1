<#
.SYNOPSIS
Генерирует иконку приложения src\assets\icon.ico: «сквиркл» с градиентом Apple (systemBlue → systemIndigo)
и белой точкой статуса с мягким кольцом — тот же мотив, что точка в трее.

.DESCRIPTION
Кадры 16, 20, 24, 32, 40, 48, 64, 128 и 256 px — PNG внутри ICO (Windows Vista+), альфа-канал сохраняется.
Мелкие размеры рисуются упрощённо: без кольца, точка крупнее — иначе детали сливаются.
С -PreviewDir дополнительно сохраняет PNG каждого размера для просмотра.
#>
param(
    [string]$OutFile = (Join-Path $PSScriptRoot '..\src\assets\icon.ico'),
    [string]$PreviewDir = ''
)

Add-Type -AssemblyName System.Drawing

function New-SquirclePath([float]$X, [float]$Y, [float]$Size, [float]$N = 5) {
    # Суперэллипс |x|^n + |y|^n = 1: «непрерывные» углы, как у иконок Apple.
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $a = $Size / 2; $cx = $X + $a; $cy = $Y + $a
    $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
    for ($i = 0; $i -lt 360; $i++) {
        $t = $i * [Math]::PI / 180
        $c = [Math]::Cos($t); $s = [Math]::Sin($t)
        $px = $cx + $a * [Math]::Sign($c) * [Math]::Pow([Math]::Abs($c), 2 / $N)
        $py = $cy + $a * [Math]::Sign($s) * [Math]::Pow([Math]::Abs($s), 2 / $N)
        $pts.Add((New-Object System.Drawing.PointF([float]$px, [float]$py)))
    }
    $path.AddPolygon($pts.ToArray())
    return $path
}

function New-IconBitmap([int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)

    # Поле: у больших размеров отступ под тень, как у иконок macOS.
    $margin = if ($Size -ge 64) { $Size * 0.06 } else { 0 }
    $tile = $Size - 2 * $margin
    $path = New-SquirclePath $margin $margin $tile

    if ($Size -ge 64) {
        # Мягкая тень под плиткой.
        for ($i = 4; $i -ge 1; $i--) {
            $shadow = New-SquirclePath ($margin - $i * $Size * 0.004) ($margin + $Size * 0.012 + $i * $Size * 0.003) ($tile + 2 * $i * $Size * 0.004)
            $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(14, 0, 0, 0))), $shadow)
            $shadow.Dispose()
        }
    }

    # Градиент systemBlue → systemIndigo сверху вниз.
    $rect = New-Object System.Drawing.RectangleF($margin, $margin, $tile, $tile)
    $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(255, 10, 132, 255), [System.Drawing.Color]::FromArgb(255, 94, 92, 230), [single]90)
    $grad.WrapMode = [System.Drawing.Drawing2D.WrapMode]::TileFlipXY   # без полосы на краю кисти (артефакт GDI+)
    $g.FillPath($grad, $path)

    # Точка статуса и кольцо-«пульс».
    $c = $Size / 2
    $white = [System.Drawing.Color]::White
    if ($Size -ge 32) {
        $ringD = $tile * 0.56
        $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(110, 255, 255, 255)), ([float]($tile * 0.055))
        $g.DrawEllipse($pen, [float]($c - $ringD / 2), [float]($c - $ringD / 2), [float]$ringD, [float]$ringD)
        $dotD = $tile * 0.30
    }
    else {
        $dotD = $tile * 0.42
    }
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $white), [float]($c - $dotD / 2), [float]($c - $dotD / 2), [float]$dotD, [float]$dotD)
    $g.Dispose()
    return $bmp
}

$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$frames = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($PreviewDir) {
        New-Item -ItemType Directory -Path $PreviewDir -Force | Out-Null
        $bmp.Save((Join-Path $PreviewDir "icon-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    }
    $bmp.Dispose()
    $frames += , @{ Size = $s; Bytes = $ms.ToArray() }
}

# ICO: ICONDIR + ICONDIRENTRY на каждый кадр + PNG-данные.
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$frames.Count)
$offset = 6 + 16 * $frames.Count
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([uint16]1); $w.Write([uint16]32)
    $w.Write([uint32]$f.Bytes.Length); $w.Write([uint32]$offset)
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $w.Write($f.Bytes) }
$w.Flush()
$dir = Split-Path -Parent $OutFile
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
Write-Output "Иконка: $OutFile ($($frames.Count) кадров: $($sizes -join ', ') px)"
