Set-StrictMode -Version 2.0

# Уведомления на телефон вне домашней сети: ntfy (https://ntfy.sh/<тема> или свой сервер) или бот Telegram.
# Адрес — одна строка в config.json (push.url):
#   https://ntfy.sh/<тема>                                         — приложение ntfy, подписка на тему;
#   https://api.telegram.org/bot<токен>/sendMessage?chat_id=<id>   — бот Telegram пишет в ваш чат.
# Отправка не блокирует трей: HttpClient.PostAsync, задача проверяется при следующей отправке (ошибка — в журнал).

Import-Module (Join-Path $PSScriptRoot 'Log.psm1')

$script:PushTypes = @('permission', 'done', 'error', 'limit')
$script:PushTasks = New-Object System.Collections.ArrayList
$script:PushClient = $null

function Get-NotifierPushTarget {
    <#
    .SYNOPSIS
    Разбирает адрес push.url: @{ Kind = ntfy | telegram; Endpoint; Topic; Chat } или $null, если адрес не подходит.
    #>
    param([AllowEmptyString()][string]$Url)
    $u = ([string]$Url).Trim()
    if ($u -match '^https://api\.telegram\.org/bot([0-9]{3,20}:[A-Za-z0-9_-]{20,80})/sendMessage\?chat_id=(-?[0-9]{1,20})$') {
        return @{ Kind = 'telegram'; Endpoint = "https://api.telegram.org/bot$($Matches[1])/sendMessage"; Chat = $Matches[2]; Topic = '' }
    }
    if ($u -match '^(https?://[A-Za-z0-9.-]+(?::[0-9]{1,5})?)/([A-Za-z0-9_-]{1,64})/?$') {
        return @{ Kind = 'ntfy'; Endpoint = $Matches[1]; Topic = $Matches[2]; Chat = '' }
    }
    return $null
}

function Format-NotifierPushTarget {
    <# .SYNOPSIS Подпись в настройках: «ntfy · ntfy.sh/тема» / «Telegram · чат 123» / «Не настроено». Токен не показывается. #>
    param([AllowEmptyString()][string]$Url)
    $t = Get-NotifierPushTarget $Url
    if ($null -eq $t) { return 'Не настроено' }
    if ($t.Kind -eq 'telegram') { return "Telegram $([char]0x00B7) чат $($t.Chat)" }
    return "ntfy $([char]0x00B7) $(([uri]$t.Endpoint).Host)/$($t.Topic)"
}

function Test-NotifierPushDue {
    <#
    .SYNOPSIS
    Нужно ли отправить событие на телефон: включено, адрес верный, тип важный, вас нет за ПК дольше push.away минут
    (0 — всегда).
    #>
    param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Config, [double]$IdleSeconds = 0)
    if (-not $Config.Contains('push') -or -not $Config.push.enabled) { return $false }
    if ($null -eq (Get-NotifierPushTarget ([string]$Config.push.url))) { return $false }
    if ($script:PushTypes -notcontains [string]$Event.type) { return $false }
    return ($IdleSeconds -ge 60 * [int]$Config.push.away)
}

function New-NotifierPushMessage {
    <#
    .SYNOPSIS
    Текст уведомления: заголовок события; текст вопроса или ответа — только с -Preview (он уходит на сторонний сервер).
    #>
    param([Parameter(Mandatory = $true)]$Event, [switch]$Preview)
    $title = ([string]$Event.title).Trim()
    if ($title -eq '') { $title = 'Claude Code' }
    $text = ''
    if ($Preview -and $Event.PSObject.Properties['preview']) { $text = ([string]$Event.preview).Trim() }
    if ($text.Length -gt 500) { $text = $text.Substring(0, 499) + [char]0x2026 }
    if ($text -eq '') {
        $text = @{ permission = 'Нужно ваше решение'; done = 'Claude закончил и ждёт ответа'; error = 'Ошибка в сеансе'; limit = 'Лимит' }[[string]$Event.type]
        if (-not $text) { $text = 'Событие сеанса' }
    }
    $priority = 3
    if (@('permission', 'error') -contains [string]$Event.type) { $priority = 4 }
    return @{ Title = $title; Text = $text; Priority = $priority }
}

function Get-PushClient {
    if ($null -eq $script:PushClient) {
        Add-Type -AssemblyName System.Net.Http
        # PS 5.1: TLS 1.2 по умолчанию может быть выключен — ntfy.sh и Telegram его требуют.
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $script:PushClient = New-Object System.Net.Http.HttpClient
        $script:PushClient.Timeout = [TimeSpan]::FromSeconds(15)
    }
    return $script:PushClient
}

function New-NotifierPushRequest {
    <# .SYNOPSIS Запрос: @{ Uri; Json }. Для ntfy — публикация JSON в корень сервера (UTF-8 без заголовков). #>
    param([Parameter(Mandatory = $true)][hashtable]$Target, [Parameter(Mandatory = $true)][hashtable]$Message)
    if ($Target.Kind -eq 'telegram') {
        $body = [ordered]@{ chat_id = $Target.Chat; text = "$($Message.Title)`n$($Message.Text)"; disable_web_page_preview = $true }
        return @{ Uri = $Target.Endpoint; Json = (ConvertTo-Json -InputObject $body -Compress) }
    }
    $body = [ordered]@{ topic = $Target.Topic; title = $Message.Title; message = $Message.Text; priority = [int]$Message.Priority; tags = @('robot') }
    return @{ Uri = "$($Target.Endpoint)/"; Json = (ConvertTo-Json -InputObject $body -Compress) }
}

function Send-NotifierPush {
    <#
    .SYNOPSIS
    Отправляет сообщение. Без -Wait — в фоне (возвращает задачу); с -Wait — ждёт до 15 с и возвращает
    @{ Ok; Error } (для проверки в настройках).
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Url, [Parameter(Mandatory = $true)][hashtable]$Message, [switch]$Wait, [string]$DataRoot)
    $target = Get-NotifierPushTarget $Url
    if ($null -eq $target) { if ($Wait) { return @{ Ok = $false; Error = 'Адрес не похож на ntfy или Telegram' } }; return $null }
    Receive-NotifierPushResults -DataRoot $DataRoot
    $req = New-NotifierPushRequest -Target $target -Message $Message
    try {
        $client = Get-PushClient   # сначала клиент: он подгружает System.Net.Http
        $content = New-Object System.Net.Http.StringContent($req.Json, [Text.Encoding]::UTF8, 'application/json')
        $task = $client.PostAsync($req.Uri, $content)
        if (-not $Wait) { [void]$script:PushTasks.Add($task); return $task }
        if (-not $task.Wait(15000)) { return @{ Ok = $false; Error = 'Сервер не ответил за 15 с' } }
        if ($task.Result.IsSuccessStatusCode) { return @{ Ok = $true; Error = '' } }
        return @{ Ok = $false; Error = "Сервер ответил $([int]$task.Result.StatusCode)" }
    }
    catch {
        $e = $_.Exception
        while ($e.InnerException) { $e = $e.InnerException }
        if ($Wait) { return @{ Ok = $false; Error = $e.Message } }
        if ($DataRoot) { Write-NotifierLog -Level WARN -Message "push: не отправлено $([char]0x2014) $($e.Message)" -DataRoot $DataRoot }
        return $null
    }
}

function Receive-NotifierPushResults {
    <# .SYNOPSIS Завершённые фоновые отправки: ошибки — в журнал (без адреса: в нём может быть токен бота). #>
    param([string]$DataRoot)
    foreach ($t in @($script:PushTasks)) {
        if (-not $t.IsCompleted) { continue }
        $script:PushTasks.Remove($t)
        $err = ''
        if ($t.IsFaulted) { $e = $t.Exception; while ($e.InnerException) { $e = $e.InnerException }; $err = $e.Message }
        elseif ($t.IsCanceled) { $err = 'истекло время' }
        elseif (-not $t.Result.IsSuccessStatusCode) { $err = "сервер ответил $([int]$t.Result.StatusCode)" }
        if ($err -and $DataRoot) { Write-NotifierLog -Level WARN -Message "push: уведомление на телефон не отправлено $([char]0x2014) $err" -DataRoot $DataRoot }
    }
}

Export-ModuleMember -Function Get-NotifierPushTarget, Format-NotifierPushTarget, Test-NotifierPushDue, New-NotifierPushMessage, New-NotifierPushRequest, Send-NotifierPush, Receive-NotifierPushResults
