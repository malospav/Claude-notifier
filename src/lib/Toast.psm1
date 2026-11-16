Set-StrictMode -Version 2.0

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')
Import-Module (Join-Path $PSScriptRoot 'Shortcut.psm1')

# ADR-006: Windows 11 доставляет клик по уведомлению (launch/protocol) только приложению с исполняемым
# COM-активатором; без него клик открывает окно Microsoft Store. Поэтому у уведомлений нет действия по клику,
# а переход к сессии — через окно «Сеансы» и «Историю» в трее.
$script:PowerShellAppId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'

function Get-NotifierToastAppId {
    <#
    .SYNOPSIS
    От чьего имени показывать уведомления. Есть ярлык «Claude Notifier» в меню «Пуск» → свой AppUserModelID:
    подпись «Claude Notifier» и иконка приложения (проверено вживую 2026-11-17: клик закрывает уведомление,
    Store не открывается). Нет ярлыка → AUMID Windows PowerShell, иначе Windows не показала бы уведомление.
    #>
    param([string]$StartMenuDir = ([Environment]::GetFolderPath('Programs')))
    if (Test-NotifierShortcutInstalled -StartMenuDir $StartMenuDir) { return (Get-NotifierAppId) }
    return $script:PowerShellAppId
}

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
        [string]$AppId = (Get-NotifierToastAppId),
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

Export-ModuleMember -Function New-NotifierToastXml, Show-NotifierToast, Get-NotifierToastAppId
