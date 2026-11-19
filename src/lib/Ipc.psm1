Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:MaxFrameChars = 65536

function Get-NotifierPipeName {
    <#
    .SYNOPSIS
    Имя named pipe трея: claude-notifier-<USERNAME>.
    #>
    [CmdletBinding()]
    param()
    return "claude-notifier-$env:USERNAME"
}

function New-NotifierPipeSecurity {
    <#
    .SYNOPSIS
    DACL для сервера pipe: полный доступ только у SID текущего пользователя, без унаследованных правил.
    #>
    [CmdletBinding()]
    param()
    $security = New-Object System.IO.Pipes.PipeSecurity
    $security.SetAccessRuleProtection($true, $false)
    $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $rule = New-Object System.IO.Pipes.PipeAccessRule($sid, [System.IO.Pipes.PipeAccessRights]::FullControl, [System.Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    return , $security
}

function Send-NotifierEvent {
    <#
    .SYNOPSIS
    Отправляет событие трею одной строкой JSON (UTF-8) по named pipe.

    .OUTPUTS
    $true — отправлено; $false — сервер недоступен или ошибка. Исключений не выбрасывает.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Event,
        [string]$PipeName = (Get-NotifierPipeName),
        [ValidateRange(1, 60000)][int]$TimeoutMs = 50
    )
    $client = $null
    try {
        $line = (ConvertTo-NotifierJson -InputObject $Event -Depth 6) + "`n"
        $bytes = (New-Object System.Text.UTF8Encoding $false).GetBytes($line)
        $client = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::Out)
        $client.Connect($TimeoutMs)
        $client.Write($bytes, 0, $bytes.Length)
        $client.Flush()
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($client) { $client.Dispose() }
    }
}

function Receive-NotifierFrame {
    <#
    .SYNOPSIS
    Читает из потока один кадр (строку до \n или до конца потока) и кладёт разобранный JSON-объект в очередь.

    .OUTPUTS
    'ok' | 'empty' | 'toolong' | 'invalid'. О 'toolong' и 'invalid' пишется WARN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Queue,
        [string]$DataRoot = (Get-NotifierDataRoot),
        [int]$MaxChars = $script:MaxFrameChars
    )
    $reader = New-Object System.IO.StreamReader($Stream, (New-Object System.Text.UTF8Encoding $false), $false, 4096, $true)
    try {
        $sb = New-Object System.Text.StringBuilder
        while ($true) {
            $c = $reader.Read()
            if ($c -lt 0 -or $c -eq 10) { break }
            if ($sb.Length -ge $MaxChars) {
                Write-NotifierLog -Level WARN -Message "Ipc: кадр длиннее $MaxChars символов отброшен" -DataRoot $DataRoot
                return 'toolong'
            }
            [void]$sb.Append([char]$c)
        }
    }
    finally { $reader.Dispose() }

    $text = $sb.ToString().Trim()
    if ($text -eq '') { return 'empty' }
    try {
        $obj = ConvertFrom-NotifierJson -InputObject $text
    }
    catch { $obj = $null }
    if ($obj -isnot [System.Management.Automation.PSCustomObject]) {
        Write-NotifierLog -Level WARN -Message 'Ipc: невалидный JSON отброшен' -DataRoot $DataRoot
        return 'invalid'
    }
    $Queue.Enqueue($obj)
    return 'ok'
}

# Тело фонового runspace сервера: только цикл подключений; разбор кадра — Receive-NotifierFrame.
$script:ServerLoop = {
    param($PipeName, $Queue, $State, $IpcModule, $DataRoot, $MaxChars)
    Import-Module $IpcModule
    $security = New-NotifierPipeSecurity
    while (-not $State.Stop) {
        $server = $null
        try {
            $server = New-Object System.IO.Pipes.NamedPipeServerStream($PipeName, [System.IO.Pipes.PipeDirection]::In, 1,
                [System.IO.Pipes.PipeTransmissionMode]::Byte, [System.IO.Pipes.PipeOptions]::None, 0, 0, $security)
            $State.Listening = $true
            $server.WaitForConnection()
            if ($State.Stop) { break }
            [void](Receive-NotifierFrame -Stream $server -Queue $Queue -DataRoot $DataRoot -MaxChars $MaxChars)
        }
        catch {
            if (-not $State.Stop) {
                Write-NotifierLog -Level ERROR -Message "Ipc: ошибка сервера pipe: $($_.Exception.Message)" -DataRoot $DataRoot
                Start-Sleep -Milliseconds 200
            }
        }
        finally {
            if ($server) { $server.Dispose() }
        }
    }
    $State.Listening = $false
}

function Start-NotifierPipeServer {
    <#
    .SYNOPSIS
    Запускает сервер pipe в отдельном runspace; каждое принятое событие кладётся в Queue.

    .PARAMETER Queue
    System.Collections.Concurrent.ConcurrentQueue[object], которую разбирает UI-поток трея.

    .OUTPUTS
    Объект-дескриптор для Stop-NotifierPipeServer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][System.Collections.Concurrent.ConcurrentQueue[object]]$Queue,
        [string]$PipeName = (Get-NotifierPipeName),
        [string]$DataRoot = (Get-NotifierDataRoot),
        [int]$MaxChars = $script:MaxFrameChars
    )
    $state = [hashtable]::Synchronized(@{ Stop = $false; Listening = $false })
    $runspace = [runspacefactory]::CreateRunspace()
    $runspace.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $runspace
    [void]$ps.AddScript($script:ServerLoop.ToString())
    [void]$ps.AddArgument($PipeName).AddArgument($Queue).AddArgument($state).AddArgument((Join-Path $PSScriptRoot 'Ipc.psm1')).AddArgument($DataRoot).AddArgument($MaxChars)
    $handle = $ps.BeginInvoke()
    return [pscustomobject]@{
        PipeName   = $PipeName
        State      = $state
        PowerShell = $ps
        Runspace   = $runspace
        Handle     = $handle
    }
}

function Stop-NotifierPipeServer {
    <#
    .SYNOPSIS
    Останавливает сервер: ставит флаг, будит WaitForConnection пустым подключением, закрывает runspace.

    .OUTPUTS
    $true, если runspace завершился за TimeoutMs.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Server,
        [int]$TimeoutMs = 3000
    )
    $Server.State.Stop = $true
    $poke = $null
    try {
        $poke = New-Object System.IO.Pipes.NamedPipeClientStream('.', $Server.PipeName, [System.IO.Pipes.PipeDirection]::Out)
        $poke.Connect(200)
    }
    catch { }
    finally { if ($poke) { $poke.Dispose() } }

    $finished = $Server.Handle.AsyncWaitHandle.WaitOne($TimeoutMs)
    if ($finished) {
        try { [void]$Server.PowerShell.EndInvoke($Server.Handle) } catch { }
    }
    else {
        $Server.PowerShell.Stop()
    }
    $Server.PowerShell.Dispose()
    $Server.Runspace.Dispose()
    return $finished
}

Export-ModuleMember -Function Get-NotifierPipeName, New-NotifierPipeSecurity, Receive-NotifierFrame, Send-NotifierEvent, Start-NotifierPipeServer, Stop-NotifierPipeServer
