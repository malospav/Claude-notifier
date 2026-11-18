<#
.SYNOPSIS
Тесты для GitHub Actions: каждый файл — в своём процессе с ограничением времени.

.DESCRIPTION
Зависший файл не съедает всё задание: через TimeoutSec его процесс снимается, а в аннотацию (::error)
попадают имя файла и последние строки его вывода — видно, на каком тесте встал. Упавшие тесты — тоже
аннотациями: они видны на странице запуска и через API без входа в GitHub (журнал шага — только после входа).
Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File tools\Invoke-CiTests.ps1
#>
param([int]$TimeoutSec = 240, [string]$Path = (Join-Path $PSScriptRoot '..\tests\unit'))

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$tmp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $env:TEMP }
$bad = 0; $passed = 0; $failed = 0

function Write-Annotation([string]$Title, [string]$Message) {
    # Перевод строки и «::» ломают формат аннотации.
    $t = ($Title -replace '[\r\n]+', ' ' -replace '::', ': ' -replace ',', ';')
    $m = ($Message -replace '\s+', ' ' -replace '::', ': ')
    if ($m.Length -gt 600) { $m = $m.Substring(0, 600) }
    Write-Output "::error title=$t::$m"
}

foreach ($f in Get-ChildItem -LiteralPath $Path -Filter '*.Tests.ps1' | Sort-Object Name) {
    $json = Join-Path $tmp "$($f.BaseName).result.json"
    $log = Join-Path $tmp "$($f.BaseName).log"
    Remove-Item -LiteralPath $json, $log -ErrorAction SilentlyContinue
    $q = $f.FullName -replace "'", "''"; $qj = $json -replace "'", "''"
    $cmd = @"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
Import-Module Pester -RequiredVersion 5.7.1
`$c = New-PesterConfiguration
`$c.Run.Path = '$q'
`$c.Run.PassThru = `$true
`$c.Output.Verbosity = 'Detailed'
`$r = Invoke-Pester -Configuration `$c
`$o = [ordered]@{ Passed = `$r.PassedCount; Containers = `$r.FailedContainersCount
    Failed = @(`$r.Failed | ForEach-Object { [ordered]@{ Name = `$_.ExpandedPath; Message = [string](`$_.ErrorRecord | Select-Object -First 1).Exception.Message } })
    Errors = @(`$r.Containers | Where-Object { `$_.Result -eq 'Failed' } | ForEach-Object { [string](`$_.ErrorRecord | Select-Object -First 1) }) }
[IO.File]::WriteAllText('$qj', (ConvertTo-Json -InputObject `$o -Depth 5), (New-Object Text.UTF8Encoding `$false))
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err" -PassThru -WindowStyle Hidden
    $done = $p.WaitForExit($TimeoutSec * 1000)
    $out = @(); if (Test-Path -LiteralPath $log) { $out = @(Get-Content -LiteralPath $log -Encoding UTF8) }
    $out | ForEach-Object { "  $_" }
    if (-not $done) {
        & taskkill.exe /T /F /PID $p.Id 2>&1 | Out-Null
        $tail = ($out | Select-Object -Last 6) -join ' | '
        Write-Annotation "Hung: $($f.Name)" "No result after $TimeoutSec s. Last output: $tail"
        $bad++
        continue
    }
    if (-not (Test-Path -LiteralPath $json)) {
        $err = ''; if (Test-Path -LiteralPath "$log.err") { $err = (Get-Content -LiteralPath "$log.err" -Raw -Encoding UTF8) }
        Write-Annotation "No result: $($f.Name)" "Exit code $($p.ExitCode). $err $(($out | Select-Object -Last 4) -join ' | ')"
        $bad++
        continue
    }
    $r = Get-Content -LiteralPath $json -Raw -Encoding UTF8 | ConvertFrom-Json
    $passed += [int]$r.Passed
    foreach ($x in @($r.Failed)) { if ($x) { Write-Annotation "$($f.Name): $($x.Name)" $x.Message; $failed++ } }
    if ([int]$r.Containers -gt 0) { Write-Annotation "File failed: $($f.Name)" ((@($r.Errors) -join ' | ')); $bad++ }
    "== $($f.Name): passed $($r.Passed), failed $(@($r.Failed | Where-Object { $_ }).Count), $([int]$sw.Elapsed.TotalSeconds) s"
}

"Passed: $passed, failed: $failed, broken or hung files: $bad"
if ($failed -gt 0 -or $bad -gt 0) { exit 1 }
exit 0
