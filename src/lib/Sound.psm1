Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# Системные звуки по умолчанию: свой для каждого типа события (проверены на целевом ПК).
$script:DefaultSounds = @{
    done       = 'Windows Notify System Generic.wav'
    permission = 'Windows Notify Messaging.wav'
    error      = 'Windows Critical Stop.wav'
    limit      = 'Windows Battery Low.wav'
}

# Последний SoundPlayer держим в поле модуля: асинхронное воспроизведение не прервётся сборщиком мусора.
$script:CurrentPlayer = $null

function Get-DefaultSoundPath([string]$Type) {
    return (Join-Path (Join-Path $env:SystemRoot 'Media') $script:DefaultSounds[$Type])
}

function Resolve-NotifierSoundPath {
    <#
    .SYNOPSIS
    Путь к WAV для типа события: свой файл из config.json или системный по умолчанию.

    .DESCRIPTION
    Пустой путь в конфиге означает «системный звук» и не логируется.
    Путь задан, но файла нет → системный звук + WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('done', 'permission', 'error', 'limit')][string]$Type,
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    $custom = [string]$Config.events[$Type].sound
    if ($custom -ne '') {
        if (Test-Path -LiteralPath $custom -PathType Leaf) { return $custom }
        Write-NotifierLog -Level WARN -Message "sound: файл '$custom' для '$Type' не найден; используется системный звук" -DataRoot $DataRoot
    }
    return (Get-DefaultSoundPath $Type)
}

function New-SoundPlayer([string]$Path) {
    # Загружает WAV синхронно. SoundPlayer.Load() не проверяет формат, поэтому заголовок
    # RIFF....WAVE проверяется здесь: битый файл → исключение до воспроизведения.
    $header = New-Object byte[] 12
    $fs = [System.IO.File]::OpenRead($Path)
    try { $read = $fs.Read($header, 0, 12) } finally { $fs.Dispose() }
    $ascii = [Text.Encoding]::ASCII
    if ($read -lt 12 -or $ascii.GetString($header, 0, 4) -ne 'RIFF' -or $ascii.GetString($header, 8, 4) -ne 'WAVE') {
        throw "файл не является WAV: $Path"
    }
    $player = New-Object System.Media.SoundPlayer $Path
    $player.Load()
    return $player
}

function Invoke-SoundPlay([string]$Path) {
    # Точка подмены в тестах: реальное асинхронное воспроизведение.
    $player = New-SoundPlayer $Path
    $player.Play()
    $script:CurrentPlayer = $player
}

function Invoke-NotifierSound {
    <#
    .SYNOPSIS
    Асинхронно играет звук типа события, если тип включён. Исключений не выбрасывает.

    .OUTPUTS
    Путь сыгранного файла или $null (тип выключен либо воспроизвести не удалось).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('done', 'permission', 'error', 'limit')][string]$Type,
        [hashtable]$Config,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    if ($null -eq $Config) { $Config = Get-NotifierConfig -DataRoot $DataRoot }
    if (-not $Config.events[$Type].enabled) { return $null }

    $path = Resolve-NotifierSoundPath -Type $Type -Config $Config -DataRoot $DataRoot
    try {
        Invoke-SoundPlay $path
        return $path
    }
    catch {
        $fallback = Get-DefaultSoundPath $Type
        if ($path -ne $fallback) {
            Write-NotifierLog -Level WARN -Message "sound: '$path' не воспроизводится ($($_.Exception.Message)); используется системный звук" -DataRoot $DataRoot
            try {
                Invoke-SoundPlay $fallback
                return $fallback
            }
            catch { }
        }
        Write-NotifierLog -Level ERROR -Message "sound: не удалось воспроизвести звук '$Type': $($_.Exception.Message)" -DataRoot $DataRoot
        return $null
    }
}

Export-ModuleMember -Function Resolve-NotifierSoundPath, Invoke-NotifierSound
