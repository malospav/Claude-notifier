<#
.SYNOPSIS
Проверка сборки: каждый .ps1/.psm1 в src и .ps1 в корне репозитория разбирается парсером PowerShell без ошибок и сохранён в UTF-8 с BOM.
Код выхода = число файлов с проблемами.
#>
param([string]$Root = (Join-Path $PSScriptRoot '..'))

$bad = 0
$files = @(Get-ChildItem (Join-Path $Root 'src') -Recurse -Include *.ps1, *.psm1) + @(Get-ChildItem $Root -Filter *.ps1 -File)
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    if ($errors) {
        Write-Output "PARSE  $($f.FullName)"
        $errors | ForEach-Object { Write-Output "  $($_.Extent.StartLineNumber): $($_.Message)" }
        $bad++
    }
    elseif (-not $hasBom) {
        Write-Output "NO-BOM $($f.FullName)"
        $bad++
    }
}
Write-Output "Checked $($files.Count) file(s), problems: $bad"
exit $bad
