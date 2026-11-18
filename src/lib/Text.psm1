Set-StrictMode -Version 2.0

# Текст для карточек и уведомлений: без разметки Markdown, с короткими путями.

$script:RxUserDir = [regex]'(?i)[A-Z]:[\\/]Users[\\/][^\\/\s"''`;|&<>]+'
$script:RxLongPath = [regex]'(?:~|[A-Za-z]:)(?:[\\/][^\\/\s"''`;|&<>]+){5,}'

function ConvertTo-NotifierPlainText {
    <#
    .SYNOPSIS
    Убирает разметку Markdown из ответа Claude для превью: **жирный**, *курсив*, `код`, заголовки #, цитаты >,
    ссылки [текст](адрес) → текст; маркеры списков - и * → «•».
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, '```[A-Za-z0-9_+-]*', '')
    $t = [regex]::Replace($t, '!?\[([^\]\r\n]+)\]\([^)\s]+\)', '$1')
    $t = [regex]::Replace($t, '(\*\*|__)(?=\S)(.+?)(?<=\S)\1', '$2')
    $t = [regex]::Replace($t, '(?<![\w*])\*(?=\S)([^*\r\n]+?)(?<=\S)\*(?![\w*])', '$1')
    $t = [regex]::Replace($t, '`([^`\r\n]+)`', '$1')
    $t = [regex]::Replace($t, '(?m)^[ \t]{0,3}#{1,6}[ \t]+', '')
    $t = [regex]::Replace($t, '(?m)^[ \t]*>[ \t]?', '')
    $t = [regex]::Replace($t, '(?m)^([ \t]*)[-*+][ \t]+', '$1• ')
    # Превью обрезано посреди разметки — непарные остатки убрать.
    $t = $t.Replace('**', '').Replace('__', '').Replace('`', '')
    return $t
}

function Format-NotifierShortText {
    <#
    .SYNOPSIS
    Длинные пути в команде или строке — коротко: папка пользователя → «~», в середине длинного пути — «…»
    (остаются первая папка и две последние части). Max — обрезать до стольких символов (0 — не обрезать).
    #>
    param([AllowEmptyString()][AllowNull()][string]$Text, [int]$Max = 0)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $script:RxUserDir.Replace($Text, '~')
    $t = $script:RxLongPath.Replace($t, [Text.RegularExpressions.MatchEvaluator] {
            param($m)
            $v = $m.Value
            $sep = '\'; if ($v.IndexOf('/') -ge 0 -and $v.IndexOf('\') -lt 0) { $sep = '/' }
            $parts = @($v -split '[\\/]')
            return ($parts[0] + $sep + $parts[1] + $sep + [char]0x2026 + $sep + $parts[-2] + $sep + $parts[-1])
        })
    if ($Max -gt 0 -and $t.Length -gt $Max) { $t = $t.Substring(0, $Max - 1) + [char]0x2026 }
    return $t
}

Export-ModuleMember -Function ConvertTo-NotifierPlainText, Format-NotifierShortText
