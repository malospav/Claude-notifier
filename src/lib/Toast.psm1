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
    param([Parameter(Mandatory = $true)]$Event, [object[]]$Actions = @(), [string]$Logo = '')

    $lines = "<text>$(ConvertTo-XmlText ([string]$Event.title))</text>"
    $preview = [string]$Event.preview
    if ($preview -ne '') { $lines += "<text>$(ConvertTo-XmlText $preview)</text>" }
    # Мелкая подпись внизу: проект и откуда сеанс («shop · Терминал»).
    $attr = Get-NotifierToastAttribution -Event $Event
    if ($attr) { $lines += "<text placement=`"attribution`">$(ConvertTo-XmlText $attr)</text>" }
    # Маскот сеанса с подходящей эмоцией — круглой картинкой слева (только свой файл из кэша).
    if ($Logo -and (Test-Path -LiteralPath $Logo -PathType Leaf)) {
        $uri = (New-Object System.Uri ([IO.Path]::GetFullPath($Logo))).AbsoluteUri
        $lines = "<image placement=`"appLogoOverride`" hint-crop=`"circle`" src=`"$(ConvertTo-XmlText $uri)`"/>" + $lines
    }
    # Кнопки (до 5): activationType foreground — нажатие ловит сам трей (ToastHook), внешний обработчик не запускается.
    $acts = ''
    foreach ($a in @($Actions | Select-Object -First 5)) {
        $acts += "<action content=`"$(ConvertTo-XmlText ([string]$a.Content))`" arguments=`"$(ConvertTo-XmlText ([string]$a.Arguments))`" activationType=`"foreground`"/>"
    }
    if ($acts) { $acts = "<actions>$acts</actions>" }

    return "<toast><visual><binding template=`"ToastGeneric`">$lines</binding></visual>$acts<audio silent=`"true`"/></toast>"
}

function Get-NotifierToastAttribution {
    <# .SYNOPSIS Подпись уведомления: «проект · Терминал / Приложение / устройство»; '' — нечего подписать. #>
    param([Parameter(Mandatory = $true)]$Event)
    $parts = @()
    if ($Event.PSObject.Properties['project'] -and [string]$Event.project -ne '') { $parts += [string]$Event.project }
    if ($Event.PSObject.Properties['origin']) {
        switch ([string]$Event.origin) { 'cli' { $parts += 'Терминал' } 'desktop' { $parts += 'Приложение' } }
    }
    return ($parts -join " $([char]0x00B7) ")
}

function ConvertTo-WinRtXml([string]$Xml) {
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    $doc = New-Object Windows.Data.Xml.Dom.XmlDocument
    $doc.LoadXml($Xml)
    return $doc
}

function Invoke-ToastShow([string]$Xml, [string]$AppId, [string]$Tag = '', [string]$Group = '') {
    # Точка подмены в тестах: реальный показ через WinRT.
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $toast = New-Object Windows.UI.Notifications.ToastNotification (ConvertTo-WinRtXml $Xml)
    # Тег и группа: новое уведомление того же типа по тому же сеансу заменяет прежнее в центре уведомлений.
    if ($Tag -and $Group) { $toast.Tag = $Tag.Substring(0, [Math]::Min(64, $Tag.Length)); $toast.Group = $Group.Substring(0, [Math]::Min(64, $Group.Length)) }
    # С кнопками — подписка на нажатие (если интерфейс загружен); уведомление держим, пока оно может быть нажато.
    if ($Xml.Contains('<actions>') -and ('ClaudeNotifier.Ui.ToastHook' -as [type])) {
        [ClaudeNotifier.Ui.ToastHook]::Attach($toast)
        $script:LiveToasts.Add($toast)
        while ($script:LiveToasts.Count -gt 30) { $script:LiveToasts.RemoveAt(0) }
    }
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId).Show($toast)
}

$script:LiveToasts = New-Object System.Collections.ArrayList

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
        [object[]]$Actions = @(),
        [string]$AppId = (Get-NotifierToastAppId),
        [string]$DataRoot = (Get-NotifierDataRoot),
        [string]$Logo = ''
    )
    try {
        $tag = ''; $group = ''
        if ($Event.PSObject.Properties['session_id'] -and [string]$Event.session_id -match '^[A-Za-z0-9_-]{1,64}$') { $group = [string]$Event.session_id; $tag = [string]$Event.type }
        if ($Event.PSObject.Properties['reminder'] -and $Event.reminder) { $tag = '' }   # напоминание — отдельным уведомлением
        Invoke-ToastShow -Xml (New-NotifierToastXml -Event $Event -Actions $Actions -Logo $Logo) -AppId $AppId -Tag $tag -Group $group
        return $true
    }
    catch {
        Write-NotifierLog -Level ERROR -Message "toast: $($_.Exception.Message)" -DataRoot $DataRoot
        return $false
    }
}

Export-ModuleMember -Function New-NotifierToastXml, Show-NotifierToast, Get-NotifierToastAppId, Get-NotifierToastAttribution
