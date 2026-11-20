<#
.SYNOPSIS
Ответы из приложения в трее: запросы разрешения, вопросы Claude, быстрые ответы, подробности сеанса.

.DESCRIPTION
Подключается к ClaudeNotifier.Tray.ps1 через dot-source. Файлы запросов — lib\Requests.psm1 (ADR-008).
Карточка сеанса с запросом раскрыта всегда и показывает кнопки; решение сразу переводит сеанс в «Работает».
#>

Import-Module (Join-Path $PSScriptRoot 'lib\Requests.psm1')
Import-Module (Join-Path $PSScriptRoot 'lib\Transcript.psm1')

$script:Pending = @{ Permissions = @(); Replies = @{}; Gone = @() }
$script:RecentRequest = @{}
$script:QuickReplies = @('Продолжай', 'Да', 'Нет')   # по умолчанию; свои — в настройках (quickReplies.texts)

function ConvertTo-NotifierQuickReplyTexts {
    <# .SYNOPSIS Строка «Продолжай; Да; Нет» → до 5 текстов до 40 знаков; пусто — ответы по умолчанию. #>
    param([AllowEmptyString()][string]$Text)
    $list = @($Text -split '[;\r\n]' | ForEach-Object { ($_ -replace '[\x00-\x1f|]', ' ').Trim() } | Where-Object { $_ -ne '' } |
        ForEach-Object { if ($_.Length -gt 40) { $_.Substring(0, 40).Trim() } else { $_ } } | Select-Object -First 5)
    if ($list.Count -eq 0) { return , [string[]]$script:QuickReplies }
    return , [string[]]$list
}

function Edit-NotifierQuickReplyTexts {
    <# .SYNOPSIS Диалог «Кнопки ответа»: свои тексты через «;» (до 5). #>
    $config = Get-NotifierConfig -DataRoot $script:TrayDataRoot
    $r = Show-NotifierDialog -Owner $null -Title 'Кнопки быстрого ответа' -Primary 'Сохранить' `
        -Message 'До 5 ответов через точку с запятой, например: Продолжай; Да; Нет; Запусти тесты. Пусто — как было по умолчанию.' `
        -InputValue (@($config.quickReplies.texts) -join '; ')
    if (-not $r.Ok) { return }
    $section = $config.quickReplies
    $section.texts = ConvertTo-NotifierQuickReplyTexts ([string]$r.Value)
    Set-NotifierConfigValue -Name quickReplies -Value ([pscustomobject]$section) -DataRoot $script:TrayDataRoot
    $script:SessionsDirty = $true
}

function Get-NotifierQuickReplyTexts {
    <# .SYNOPSIS Тексты кнопок быстрого ответа: свои из настроек или «Продолжай / Да / Нет». #>
    try {
        $t = @((Get-NotifierConfig -DataRoot $script:TrayDataRoot).quickReplies.texts | Where-Object { $_ })
        if ($t.Count -gt 0) { return , [string[]]$t }
    }
    catch { }
    return , [string[]]$script:QuickReplies
}
$script:RemindMinutes = 3

function Update-NotifierPending {
    <#
    .SYNOPSIS
    Перечитывает запросы. Сеансы, чей запрос исчез без нашего решения (ответили в Claude, истекло время),
    переходят из «Нужно разрешение» в «Работает». Возвращает $true, если статус какого-то сеанса изменился.
    #>
    param([string]$DataRoot = $script:TrayDataRoot)
    $script:Pending = Get-NotifierPendingRequests -DataRoot $DataRoot
    $changed = $false
    foreach ($sid in @($script:Pending.Gone | Select-Object -Unique)) {
        $stillAsking = @($script:Pending.Permissions | Where-Object { $_.session_id -eq $sid }).Count -gt 0
        if (-not $stillAsking -and (Set-NotifierSessionState -SessionId $sid -State working -OnlyFrom permission -DataRoot $DataRoot)) { $changed = $true }
    }
    return $changed
}

function Set-NotifierSessionState {
    <#
    .SYNOPSIS
    Меняет статус сеанса служебным событием (working). -OnlyFrom — только если сейчас этот статус.
    Возвращает $true, если статус изменился.
    #>
    param([Parameter(Mandatory = $true)][string]$SessionId, [string]$State = 'working', [string]$OnlyFrom = '', [string]$DataRoot = $script:TrayDataRoot)
    $sessions = @(Get-NotifierSessions -DataRoot $DataRoot)
    $cur = @($sessions | Where-Object { [string]$_.session_id -eq $SessionId })[0]
    if ($null -eq $cur) { return $false }
    if ($OnlyFrom -and [string]$cur.state -ne $OnlyFrom) { return $false }
    $ev = [pscustomobject]@{ type = $State; session_id = $SessionId; ts = [DateTime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'") }
    $updated = Update-NotifierSessionList -Sessions $sessions -Event $ev
    Save-NotifierSessions -Sessions $updated -DataRoot $DataRoot
    $script:SessionsDirty = $true
    return $true
}

function Add-NotifierCardRequest {
    <#
    .SYNOPSIS
    Добавляет в карточку сеанса запрос и кнопки: разрешение, вопрос с вариантами, утверждение плана,
    быстрый ответ. Только для сеансов этого ПК.
    #>
    param([Parameter(Mandatory = $true)]$Card, [Parameter(Mandatory = $true)]$Session)
    $sid = [string]$Session.session_id
    $req = @($script:Pending.Permissions | Where-Object { [string]$_.session_id -eq $sid }) | Select-Object -First 1
    if ($req) {
        $Card.ForceExpand = $true
        $Card.Urgent = Test-NotifierRequestOverdue -Request $req -Minutes ([int]$script:RemindMinutes)
        $Card.RequestTitle = [string]$req.title
        $Card.RequestDetail = [string]$req.detail
        $acts = @()
        switch ([string]$req.kind) {
            'question' {
                $i = 0
                foreach ($o in @($req.options)) { $acts += "answer:$i|$o|$(if ($i -eq 0) { 'primary' } else { 'secondary' })"; $i++ }
                $acts += 'answer-custom|Свой ответ…|secondary'
            }
            'question-complex' { $acts += 'focus|Открыть Claude|primary' }
            'plan' { $acts += 'allow|Утвердить|primary'; $acts += 'deny|Отклонить|destructive' }
            default {
                $acts += 'allow|Разрешить|primary'
                # «На 30 мин»: такие же запросы в этом проекте полчаса разрешаются сами (Bash — по началу команды, без цепочек).
                if ($null -ne (Get-NotifierAutoAllowPrefix -ToolName ([string]$req.tool_name) -ToolInput $req.tool_input) -and [string]$Session.project -ne '') { $acts += 'allow30|На 30 мин|secondary' }
                if ($req.canAlways) { $acts += 'always|Разрешать всегда|secondary' }
                $acts += 'deny|Запретить|destructive'
            }
        }
        $Card.Actions = [string[]]$acts
        $Card.Tag = @{ Session = $Session; Request = $req }
        return
    }
    # Быстрый ответ — только если Claude в конце ответа что-то спросил; иначе кнопки «Да / Нет» ни к чему.
    if ($script:Pending.Replies.ContainsKey($sid) -and [string]$Session.state -eq 'waiting' -and (Test-NotifierSessionAsks -Session $Session -Fallback ([string]$Session.preview))) {
        $Card.RequestTitle = 'Быстрый ответ'
        $acts = @()
        $i = 0
        foreach ($q in (Get-NotifierQuickReplyTexts)) { $acts += "reply:$i|$q|secondary"; $i++ }
        $acts += 'reply-custom|Ответить…|primary'
        $Card.Actions = [string[]]$acts
    }
}

function Invoke-NotifierCardAction {
    <#
    .SYNOPSIS
    Кнопка в карточке сеанса: allow | always | deny | answer:<n> | answer-custom | reply:<n> | reply-custom | focus.
    Возвращает текст подсказки для окна или ''.
    #>
    param([Parameter(Mandatory = $true)]$Item, [Parameter(Mandatory = $true)][string]$ActionId, [string]$DataRoot = $script:TrayDataRoot, [string]$Text = '')
    $session = $Item.Tag
    $req = $null
    if ($session -is [hashtable]) { $req = $session.Request; $session = $session.Session }
    $sid = [string]$session.session_id
    $notice = ''
    switch -Regex ($ActionId) {
        '^(allow|always|deny)$' {
            if ($req -and (Write-NotifierDecision -RequestId $req.id -Behavior $ActionId -DataRoot $DataRoot)) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = @{ allow = 'Разрешено'; always = 'Разрешено — и впредь без вопросов'; deny = 'Запрещено' }[$ActionId]
            }
            else { $notice = 'Запрос уже решён в Claude' }
        }
        '^allow30$' {
            # Разрешить и полчаса разрешать такие же запросы этого проекта без вопросов.
            $rule = $null
            if ($req) { $rule = Add-NotifierAutoAllowRule -Project ([string]$session.project) -ToolName ([string]$req.tool_name) -ToolInput $req.tool_input -Minutes 30 -DataRoot $DataRoot }
            if ($req -and (Write-NotifierDecision -RequestId $req.id -Behavior allow -DataRoot $DataRoot)) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = if ($rule) { "Разрешено — и ещё 30 минут: $($rule.title)" } else { 'Разрешено' }
                if ($rule) { Write-NotifierLog -Level INFO -Message "replies: правило на 30 мин — $($rule.title) ($($session.project))" -DataRoot $DataRoot }
            }
            else { $notice = 'Запрос уже решён в Claude' }
        }
        '^answer:(\d+)$' {
            $label = [string]@($req.options)[[int]$Matches[1]]
            if ($req -and (Write-NotifierDecision -RequestId $req.id -Behavior allow -Answer $label -DataRoot $DataRoot)) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = "Ответ: $label"
            }
            else { $notice = 'Вопрос уже закрыт в Claude' }
        }
        '^answer-custom$' {
            $r = Show-NotifierDialog -Owner $script:SessionsForm -Title ([string]$req.title) -Primary 'Ответить' -InputValue ''
            if ($r.Ok -and ([string]$r.Value).Trim() -ne '' -and (Write-NotifierDecision -RequestId $req.id -Behavior allow -Answer ([string]$r.Value).Trim() -DataRoot $DataRoot)) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = 'Ответ отправлен'
            }
        }
        '^reply:(\d+)$' {
            $texts = Get-NotifierQuickReplyTexts
            $n = [int]$Matches[1]
            if ($n -ge $texts.Count) { $notice = 'Такого ответа больше нет'; break }
            $text = $texts[$n]
            if (Write-NotifierReply -SessionId $sid -Text $text -DataRoot $DataRoot) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = "Отправлено: $text"
            }
            else { $notice = 'Сеанс больше не ждёт ответа' }
        }
        '^reply-custom$' {
            $r = Show-NotifierDialog -Owner $script:SessionsForm -Title "Ответ для «$($session.project)»" -Message 'Claude получит его как ваше сообщение и продолжит работу.' -Primary 'Отправить' -InputValue ''
            if ($r.Ok -and ([string]$r.Value).Trim() -ne '') {
                if (Write-NotifierReply -SessionId $sid -Text ([string]$r.Value) -DataRoot $DataRoot) {
                    [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                    $notice = 'Ответ отправлен'
                }
                else { $notice = 'Сеанс больше не ждёт ответа' }
            }
        }
        '^answer-text$' {
            # Свой ответ на вопрос — текстом из поля шторки (без диалога).
            $t = $Text.Trim()
            if ($t -ne '' -and $req -and (Write-NotifierDecision -RequestId $req.id -Behavior allow -Answer $t -DataRoot $DataRoot)) {
                [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                $notice = 'Ответ отправлен'
            }
            elseif ($t -ne '') { $notice = 'Вопрос уже закрыт в Claude' }
        }
        '^reply-text$' {
            # Свой ответ после «Готово» — текстом из поля шторки.
            $t = $Text.Trim()
            if ($t -ne '') {
                if (Write-NotifierReply -SessionId $sid -Text $t -DataRoot $DataRoot) {
                    [void](Set-NotifierSessionState -SessionId $sid -State working -DataRoot $DataRoot)
                    $notice = 'Ответ отправлен'
                }
                else { $notice = 'Сеанс больше не ждёт ответа' }
            }
        }
        '^focus$' {
            $result = Invoke-NotifierSessionFocus -Session $session -DataRoot $DataRoot
            if ($result -eq 'unknown') { $notice = 'Окно этого сеанса не определено' }
        }
    }
    [void](Update-NotifierPending -DataRoot $DataRoot)
    return $notice
}

# --- Кнопки в уведомлениях Windows ---

function Get-NotifierToastButtons {
    <#
    .SYNOPSIS
    Кнопки уведомления: у запроса разрешения — те же решения, что в карточке (без «Свой ответ…»: для него нужно окно);
    у «Готово» сеанса этого ПК — быстрые ответы. Аргументы кнопки: «cn|<session_id>|<request_id>|<действие>».
    #>
    param([Parameter(Mandatory = $true)]$Event, [Parameter(Mandatory = $true)]$Config, [switch]$Request, [string]$DataRoot = $script:TrayDataRoot)
    $sid = ''
    if ($Event.PSObject.Properties['session_id']) { $sid = [string]$Event.session_id }
    if ($sid -eq '') { return @() }
    # Сеанс другого устройства — кнопки, только если его хуки умеют ждать ответа от ПК (новая установка на Mac).
    if ($Event.PSObject.Properties['device'] -and [string]$Event.device -ne '') {
        $dev = $null
        if ($script:Net -and $script:Net.Network) { $dev = Find-NotifierDevice -Network $script:Net.Network -Id ([string]$Event.device) }
        if ($null -eq $dev -or -not ($dev.PSObject.Properties['replies'] -and [bool]$dev.replies)) { return @() }
    }
    $mk = { param($content, $req, $act) @{ Content = $content; Arguments = "cn|$sid|$req|$act" } }
    if ($Request -and $Event.PSObject.Properties['request_id'] -and $Config.approvals.enabled) {
        $rid = [string]$Event.request_id
        $req = @((Get-NotifierPendingRequests -DataRoot $DataRoot).Permissions | Where-Object { [string]$_.id -eq $rid }) | Select-Object -First 1
        if ($null -eq $req) { return @() }
        switch ([string]$req.kind) {
            'question' {
                $out = @(); $i = 0
                foreach ($o in @($req.options | Select-Object -First 5)) { $out += (& $mk ([string]$o) $rid "answer:$i"); $i++ }
                return $out
            }
            'question-complex' { return @() }
            'plan' { return @((& $mk 'Утвердить' $rid 'allow'), (& $mk 'Отклонить' $rid 'deny')) }
            default {
                $out = @((& $mk 'Разрешить' $rid 'allow'))
                if ($req.canAlways) { $out += (& $mk 'Всегда' $rid 'always') }
                $out += (& $mk 'Запретить' $rid 'deny')
                return $out
            }
        }
    }
    if ([string]$Event.type -eq 'done' -and $Config.quickReplies.enabled -and (Test-NotifierSessionAsks -Session $Event -Fallback ([string]$Event.preview))) {
        $out = @(); $i = 0
        foreach ($q in (Get-NotifierQuickReplyTexts)) { $out += (& $mk $q '' "reply:$i"); $i++ }
        return $out
    }
    return @()
}

function Invoke-NotifierToastButton {
    <#
    .SYNOPSIS
    Нажатие кнопки уведомления: «cn|<session_id>|<request_id>|<действие>» → то же, что кнопка карточки. Возвращает подсказку.
    #>
    param([AllowEmptyString()][string]$Arguments, [string]$DataRoot = $script:TrayDataRoot)
    $p = $Arguments -split '\|'
    if ($Arguments -eq 'cn|||update') { return (Invoke-NotifierUpdateNow) }   # уведомление «Доступно обновление»
    if ($p.Count -ne 4 -or $p[0] -ne 'cn' -or $p[3] -notmatch '^(allow|always|deny|answer:\d+|reply:\d+)$') { return '' }
    $session = @(Get-NotifierSessions -DataRoot $DataRoot | Where-Object { [string]$_.session_id -eq $p[1] }) | Select-Object -First 1
    if ($null -eq $session) { return 'Сеанс уже завершён' }
    $item = New-Object ClaudeNotifier.Ui.CardItem
    $item.Tag = $session
    if ($p[2] -ne '') {
        $req = @((Get-NotifierPendingRequests -DataRoot $DataRoot).Permissions | Where-Object { [string]$_.id -eq $p[2] }) | Select-Object -First 1
        if ($null -eq $req) { return 'Запрос уже решён в Claude' }
        $item.Tag = @{ Session = $session; Request = $req }
    }
    $notice = Invoke-NotifierCardAction -Item $item -ActionId $p[3] -DataRoot $DataRoot
    Write-NotifierLog -Level INFO -Message "tray: кнопка уведомления '$($p[3])' $([char]0x2192) $notice" -DataRoot $DataRoot
    return $notice
}

function Invoke-NotifierToastButtons {
    <# .SYNOPSIS Из таймера трея: разобрать нажатые кнопки уведомлений. #>
    if (-not ('ClaudeNotifier.Ui.ToastHook' -as [type])) { return }
    $a = $null
    while ([ClaudeNotifier.Ui.ToastHook]::Queue.TryDequeue([ref]$a)) {
        [void](Invoke-NotifierToastButton -Arguments $a)
        $script:SessionsDirty = $true
    }
}

function Test-NotifierDuplicatePermissionToast {
    <#
    .SYNOPSIS
    Уведомление «Нужно разрешение» от Claude сразу после нашего запроса по тому же сеансу — дубль, его не показываем.
    Запоминает запросы (type request) и проверяет permission в пределах 30 с.
    #>
    param([Parameter(Mandatory = $true)]$Event, [datetime]$Now = [DateTime]::UtcNow)
    $sid = ''
    if ($Event.PSObject.Properties['session_id']) { $sid = [string]$Event.session_id }
    if ($Event.type -eq 'request') { $script:RecentRequest[$sid] = $Now; return $false }
    if ($Event.type -ne 'permission' -or -not $script:RecentRequest.ContainsKey($sid)) { return $false }
    return (($Now - $script:RecentRequest[$sid]).TotalSeconds -lt 30)
}
