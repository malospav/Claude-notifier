Set-StrictMode -Version 2.0

$script:MaxLogBytes = 1MB

function Get-NotifierDataRoot {
    <#
    .SYNOPSIS
    Возвращает каталог claude-notifier: %USERPROFILE%\.claude-notifier (или $env:CLAUDE_NOTIFIER_HOME).

    .DESCRIPTION
    Не %LOCALAPPDATA%: приложение Claude для Windows — пакет MSIX, и всё, что его процессы (хуки, установщик,
    запущенный из Claude) пишут в AppData, Windows перенаправляет в личную папку пакета. Такую копию не видят
    «Пуск», Проводник и Claude Code CLI. Папку профиля Windows не виртуализирует — как и ~\.claude.
    #>
    [CmdletBinding()]
    param()
    if ($env:CLAUDE_NOTIFIER_HOME) { return $env:CLAUDE_NOTIFIER_HOME }
    return (Join-Path $env:USERPROFILE '.claude-notifier')
}

function Write-NotifierLog {
    <#
    .SYNOPSIS
    Дописывает строку в log.txt каталога данных; при размере больше 1 МБ переносит файл в log.1.txt.

    .DESCRIPTION
    Формат строки: "<UTC ISO-8601> [LEVEL] <Message>". Ошибки ввода-вывода не пробрасываются:
    логирование никогда не должно ломать вызывающий код.

    .PARAMETER Level
    INFO, WARN или ERROR.

    .PARAMETER Message
    Текст записи. Не передавайте сюда превью сообщений Claude и секреты.

    .PARAMETER DataRoot
    Каталог данных; по умолчанию Get-NotifierDataRoot.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Message,

        [string]$DataRoot = (Get-NotifierDataRoot)
    )

    try {
        if (-not (Test-Path -LiteralPath $DataRoot -PathType Container)) {
            New-Item -ItemType Directory -Path $DataRoot -Force | Out-Null
        }
        $logPath = Join-Path $DataRoot 'log.txt'
        $item = Get-Item -LiteralPath $logPath -ErrorAction SilentlyContinue
        if ($item -and -not $item.PSIsContainer -and $item.Length -gt $script:MaxLogBytes) {
            Move-Item -LiteralPath $logPath -Destination (Join-Path $DataRoot 'log.1.txt') -Force
        }
        $stamp = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", [Globalization.CultureInfo]::InvariantCulture)
        $line = "$stamp [$Level] $Message" + [Environment]::NewLine
        [System.IO.File]::AppendAllText($logPath, $line, (New-Object System.Text.UTF8Encoding $false))
    }
    catch {
        # Логирование не должно прерывать работу хуков и трея.
    }
}

Export-ModuleMember -Function Get-NotifierDataRoot, Write-NotifierLog
