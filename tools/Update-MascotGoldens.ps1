<#
.SYNOPSIS
Пересоздаёт эталонные картинки маскотов (tests\golden\<маскот>-<статус>.png).

.DESCRIPTION
Запускайте, когда рисунок маскота изменён намеренно: тест s_018_02 сравнивает текущую отрисовку с этими
картинками и падает, если у маскота что-то «отвалилось» или сдвинулось. Посмотрите новые PNG перед коммитом.
Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Update-MascotGoldens.ps1 [-Kind fox]
#>
param([string]$Kind = '', [string]$Out = (Join-Path $PSScriptRoot '..\tests\golden'))

Import-Module (Join-Path $PSScriptRoot '..\src\lib\Ui.psm1')
[void](Import-NotifierUi)
New-Item -ItemType Directory -Path $Out -Force | Out-Null
$n = 0
foreach ($k in [ClaudeNotifier.Ui.Mascot]::Kinds) {
    if ($Kind -and $k -ne $Kind) { continue }
    foreach ($s in (Get-NotifierGoldenStates)) {
        $bmp = New-NotifierMascotFrame -Kind $k -State $s
        try { $bmp.Save((Join-Path $Out "$k-$s.png"), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $bmp.Dispose() }
        $n++
    }
}
"Эталонов записано: $n в $((Resolve-Path $Out).Path)"
