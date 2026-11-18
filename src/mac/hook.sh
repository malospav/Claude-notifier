#!/bin/sh
# claude-notifier: передаёт событие хука Claude Code на ПК с Windows, а для двух хуков ждёт ответа с ПК.
#   hook.sh stop|notification|stopfailure|sessionstart|prompt|sessionend — событие, асинхронно, сразу выходит;
#   hook.sh permreq   — PermissionRequest: запрос на ПК, ждёт решения (с ПК или телефона); вывод — JSON решения;
#   hook.sh replywait — Stop (asyncRewake): ждёт быстрого ответа с ПК; ответ — в stderr и код 2 (Claude получит
#                       его сообщением, как на ПК).
# ПК выключен, недоступен или вы ответили прямо в Claude — тихо выходит с кодом 0, Claude работает как обычно.
DIR="$HOME/.claude-notifier"
[ -f "$DIR/env" ] || exit 0
. "$DIR/env"
KIND="$1"
case "$KIND" in stop|notification|stopfailure|sessionstart|prompt|sessionend|permreq|replywait) ;; *) exit 0 ;; esac

# Служебный Claude, запущенный изнутри другого сеанса (хук плагина делает сводку через «claude -p» и т. п.):
# среди предков два процесса claude — не отдельный сеанс, ПК о нём не сообщаем. ps не тот (не macOS) — не вложен.
nested() {
  pid=$PPID; n=0; codes=0
  while [ "$n" -lt 15 ] && [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    comm="$(ps -o comm= -p "$pid" 2>/dev/null)"
    case "${comm##*/}" in claude) codes=$((codes + 1)) ;; esac
    [ "$codes" -ge 2 ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')"
    n=$((n + 1))
  done
  return 1
}
nested && exit 0

ENTRY="$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-cli}" | tr -cd 'A-Za-z0-9_.-')"
# Токен — из файла заголовка (не виден в ps); старые установки хранили его в env.
if [ -f "$DIR/auth" ]; then AUTH="@$DIR/auth"; else AUTH="Authorization: Bearer ${CN_TOKEN:-}"; fi
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/cn.$$")"
mkdir -p "$TMP" 2>/dev/null
cat > "$TMP/body"
OUT="$TMP/out"
cleanup() { rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT

# POST тела хука на первый отвечающий адрес ПК. Выставляет BASE и CODE; ответ — в $OUT.
post() {
  for BASE in "$CN_URL" "$CN_URL2"; do
    [ -n "$BASE" ] || continue
    CODE="$(curl -s -m "$1" -o "$OUT" -w '%{http_code}' -X POST \
      -H "$AUTH" -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary @"$TMP/body" "$BASE$2" 2>/dev/null)"
    case "$CODE" in 2??|4??) return 0 ;; esac
  done
  BASE=''
  return 1
}
get() { CODE="$(curl -s -m 5 -o "$OUT" -w '%{http_code}' -H "$AUTH" "$BASE$1" 2>/dev/null)"; }

case "$KIND" in
  permreq)
    post 5 "/api/mac/permreq?entry=$ENTRY" || exit 0
    [ "$CODE" = 200 ] || exit 0
    ID="$(sed -n 's/.*"id":"\([0-9a-fA-F-]*\)".*/\1/p' "$OUT")"
    WAIT="$(sed -n 's/.*"wait":\([0-9]*\).*/\1/p' "$OUT")"
    [ -n "$ID" ] || exit 0
    # Закончили ждать (решили в Claude, истёк срок) — снять запрос на ПК, чтобы кнопки там исчезли сразу.
    trap 'curl -s -m 2 -o /dev/null -X POST -H "$AUTH" -H "Content-Type: application/json" --data "{}" "$BASE/api/mac/done?id=$ID" >/dev/null 2>&1; cleanup' EXIT
    trap 'exit 0' INT TERM HUP
    END=$(( $(date +%s) + ${WAIT:-600} ))
    FAILS=0
    while [ "$(date +%s)" -lt "$END" ]; do
      sleep 1
      get "/api/mac/decision?id=$ID"
      case "$CODE" in
        200) cat "$OUT"; exit 0 ;;
        204) FAILS=0 ;;
        403|404|410) exit 0 ;;
        *) FAILS=$((FAILS + 1)); [ "$FAILS" -ge 15 ] && exit 0 ;;
      esac
    done
    exit 0
    ;;
  replywait)
    SID="$(sed -n 's/.*"session_id"[ ]*:[ ]*"\([A-Za-z0-9_-]*\)".*/\1/p' "$TMP/body" | head -n 1)"
    [ -n "$SID" ] || exit 0
    post 5 '/api/mac/replywait' || exit 0
    [ "$CODE" = 200 ] || exit 0
    MIN="$(sed -n 's/.*"minutes":\([0-9]*\).*/\1/p' "$OUT")"
    END=$(( $(date +%s) + ${MIN:-60} * 60 ))
    FAILS=0
    while [ "$(date +%s)" -lt "$END" ]; do
      sleep 2
      get "/api/mac/reply?session=$SID"
      case "$CODE" in
        200)
          printf '%s\n' 'Пользователь ответил через Claude Notifier (быстрый ответ вместо сообщения в чате):' >&2
          cat "$OUT" >&2
          exit 2 ;;
        204) FAILS=0 ;;
        403|404|410) exit 0 ;;
        *) FAILS=$((FAILS + 1)); [ "$FAILS" -ge 15 ] && exit 0 ;;
      esac
    done
    exit 0
    ;;
  *)
    post 2 "/api/event?kind=$KIND&entry=$ENTRY"
    exit 0
    ;;
esac
