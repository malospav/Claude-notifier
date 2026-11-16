Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

# AUMID Windows PowerShell (ADR-006). Windows 11 доставляет клик по уведомлению только приложению
# с исполняемым COM-активатором; для зарегистрированного в реестре AUMID без exe клик открывает
# окно Microsoft Store («нет программы»). С AUMID PowerShell клик просто закрывает уведомление,
# а переход к сессии делается через «Историю» в трее.
$script:AppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function ConvertTo-XmlText([AllowNull()][string]$Text) {
    # Экранирует & < > " ' для текста и атрибутов XML.
    if ($null -eq $Text) { return '' }
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-NotifierToastXml {
    <#
    .SYNOPSIS
    XML toast-уведомления (шаблон ToastGeneric) для события v1: заголовок и превью.

    .DESCRIPTION
    Без атрибута launch: клик по уведомлению ничего не запускает (ADR-006). Звук toast выключен —
    его играет Sound.psm1.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Event)

    $lines = "<text>$(ConvertTo-XmlText ([string]$Event.title))</text>"
    $preview = [string]$Event.preview
    if ($preview -ne '') { $lines += "<text>$(ConvertTo-XmlText $preview)</text>" }

    return "<toast><visual><binding template=`"ToastGeneric`">$lines</binding></visual><audio silent=`"true`"/></toast>"
}

function ConvertTo-WinRtXml([string]$Xml) {
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($Xml)
    return $doc
}

function Invoke-ToastShow([string]$Xml, [string]$AppId) {
    # Точка подмены в тестах: реальный показ через WinRT.
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $toast = New-Object Windows.UI.Notifications.ToastNotification (ConvertTo-WinRtXml $Xml)
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

function Show-NotifierToast {
    <#
    .SYNOPSIS
    Показывает toast для события. Ошибки WinRT пишутся в лог (ERROR), наружу не выбрасываются.

    .OUTPUTS
    $true — показано; $false — ошибка.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Event,
        [string]$AppId = $script:AppId,
        [string]$DataRoot = (Get-NotifierDataRoot)
    )
    try {
        Invoke-ToastShow -Xml (New-NotifierToastXml -Event $Event) -AppId $AppId
        return $true
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "toast: $($_.Exception.Message)" -DataRoot $DataRoot
        return $false
    }
}

Export-ModuleMember -Function New-NotifierToastXml, Show-NotifierToast
