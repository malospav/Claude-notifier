#!/bin/sh
# claude-notifier: передаёт событие хука Claude Code на ПК с Windows.
# Вызывается Claude Code асинхронно: hook.sh stop|notification|stopfailure|sessionstart|prompt|sessionend
# Ничего не выводит и всегда завершается с кодом 0 — даже если ПК выключен или недоступен.
DIR="$HOME/.claude-notifier"
[ -f "$DIR/env" ] || exit 0
. "$DIR/env"
KIND="$1"
case "$KIND" in stop|notification|stopfailure|sessionstart|prompt|sessionend) ;; *) exit 0 ;; esac
ENTRY="$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-cli}" | tr -cd 'A-Za-z0-9_.-')"
BODY="$(cat)"
# Токен — из файла заголовка (не виден в ps); старые установки хранили его в env.
if [ -f "$DIR/auth" ]; then AUTH="@$DIR/auth"; else AUTH="Authorization: Bearer ${CN_TOKEN:-}"; fi
for BASE in "$CN_URL" "$CN_URL2"; do
  [ -n "$BASE" ] || continue
  CODE="$(printf '%s' "$BODY" | curl -s -m 2 -o /dev/null -w '%{http_code}' -X POST \
    -H "$AUTH" -H 'Content-Type: application/json; charset=utf-8' \
    --data-binary @- "$BASE/api/event?kind=$KIND&entry=$ENTRY" 2>/dev/null)"
  case "$CODE" in 2??|4??) exit 0 ;; esac
done
exit 0
