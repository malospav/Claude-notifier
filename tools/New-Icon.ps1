<#
.SYNOPSIS
Генерирует src\assets\icon.ico (колокольчик на скруглённом квадрате) в размерах 32, 64 и 256 px.
ICO собирается вручную с PNG-кадрами (поддерживается Windows Vista+), чтобы не терять альфа-канал.
#>
param([string]$OutFile = (Join-Path $PSScriptRoot '..\src\assets\icon.ico'))

Add-Type -AssemblyName System.Drawing

function New-IconPng([int]$Size) {
    $bmp = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $Size / 32.0

    # Фон: скруглённый квадрат.
    $r = 7 * $s
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $w = $Size - 1
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($w - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($w - 2 * $r, $w - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc(0, $w - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 79, 70, 229))), $path)

    # Колокольчик: купол, юбка, язычок.
    $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
    $g.FillEllipse($white, 10 * $s, 7 * $s, 12 * $s, 13 * $s)
    $g.FillRectangle($white, 10 * $s, 13.5 * $s, 12 * $s, 6.5 * $s)
    $skirt = New-Object System.Drawing.Drawing2D.GraphicsPath
    $skirt.AddPolygon(@(
        (New-Object System.Drawing.PointF ([single](10 * $s)), ([single](19 * $s))),
        (New-Object System.Drawing.PointF ([single](22 * $s)), ([single](19 * $s))),
        (New-Object System.Drawing.PointF ([single](25 * $s)), ([single](23 * $s))),
        (New-Object System.Drawing.PointF ([single](7 * $s)), ([single](23 * $s)))
    ))
    $g.FillPath($white, $skirt)
    $g.FillEllipse($white, 13.5 * $s, 23 * $s, 5 * $s, 4 * $s)
    $g.FillEllipse($white, 14.5 * $s, 5 * $s, 3 * $s, 3 * $s)

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return , $ms.ToArray()
}

$sizes = @(32, 64, 256)
$pngs = @($sizes | ForEach-Object { , (New-IconPng $_) })

$out = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter $out
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)   # ICONDIR
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {                                      # ICONDIRENTRY
    $dim = $sizes[$i]; if ($dim -ge 256) { $dim = 0 }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim); $bw.Write([byte]0); $bw.Write([byte]0)
    $bw.Write([uint16]1); $bw.Write([uint16]32)
    $bw.Write([uint32]$pngs[$i].Length); $bw.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($p in $pngs) { $bw.Write($p) }
$bw.Flush()
New-Item -ItemType Directory -Path (Split-Path $OutFile) -Force | Out-Null
[IO.File]::WriteAllBytes($OutFile, $out.ToArray())
Write-Output "icon: $OutFile ($($out.Length) bytes)"
