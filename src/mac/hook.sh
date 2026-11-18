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

# Служебный Claude, запущенный изнутри другого сеанса (плагин ECC делает сводку через «claude -p» с этими
# переменными окружения; хуки вложенного Claude их наследуют) — не отдельный сеанс, ПК о нём не сообщаем.
# По дереву процессов не определяем: на Mac в цепочке обычного сеанса тоже бывает два процесса claude.
[ -n "${ECC_LLM_SUMMARY_SUBPROCESS:-}${ECC_SKIP_LLM_SUMMARY:-}" ] && exit 0

ENTRY="$(printf '%s' "${CLAUDE_CODE_ENTRYPOINT:-cli}" | tr -cd 'A-Za-z0-9_.-')"
# Токен — из файла заголовка (не виден в ps); старые установки хранили его в env.
if [ -f "$DIR/auth" ]; then AUTH="@$DIR/auth"; else AUTH="Authorization: Bearer ${CN_TOKEN:-}"; fi
TMP="$(mktemp -d 2>/dev/null || echo "/tmp/cn.$$")"
mkdir -p "$TMP" 2>/dev/null
cat > "$TMP/body"
OUT="$TMP/out"
cleanup() { rm -rf "$TMP" 2>/dev/null; }
trap cleanup EXIT

# POST тела хука ($3, по умолчанию тело этого вызова) на первый отвечающий адрес ПК. Выставляет BASE и CODE; ответ — в $OUT.
post() {
  for BASE in "$CN_URL" "$CN_URL2"; do
    [ -n "$BASE" ] || continue
    CODE="$(curl -s -m "$1" -o "$OUT" -w '%{http_code}' -X POST \
      -H "$AUTH" -H 'Content-Type: application/json; charset=utf-8' \
      --data-binary @"${3:-$TMP/body}" "$BASE$2" 2>/dev/null)"
    case "$CODE" in 2??|4??) return 0 ;; esac
  done
  BASE=''
  return 1
}

# Очередь событий: ПК выключен, спит или трей перезапускается — событие ждёт в queue/ и уходит перед следующим
# (иначе сеанс на ПК навсегда «работает»). Не больше 50 событий и не старше 6 часов.
QUEUE="$DIR/queue"
enqueue() {
  mkdir -p "$QUEUE" 2>/dev/null || return 0
  # Имя: <время>.<pid>.<тип>.<точка входа без точек>.ev — по нему отправляется в том же порядке.
  cp "$TMP/body" "$QUEUE/$(date +%s).$$.$KIND.$(printf '%s' "$ENTRY" | tr -d '.').ev" 2>/dev/null
  N="$(ls -1 "$QUEUE" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${N:-0}" -gt 50 ]; then
    ls -1 "$QUEUE" | sort | head -n $((N - 50)) | while read -r f; do rm -f "$QUEUE/$f"; done
  fi
}
flush() {
  [ -d "$QUEUE" ] || return 0
  NOW="$(date +%s)"
  for f in $(ls -1 "$QUEUE" 2>/dev/null | sort); do
    TS="${f%%.*}"; REST="${f#*.}"; REST="${REST#*.}"; QK="${REST%%.*}"; QE="${REST#*.}"; QE="${QE%.ev}"
    if [ $((NOW - TS)) -gt 21600 ] 2>/dev/null; then rm -f "$QUEUE/$f"; continue; fi
    post 2 "/api/event?kind=$QK&entry=$QE&queued=$TS" "$QUEUE/$f" || return 1
    rm -f "$QUEUE/$f"
  done
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
    # Сначала — отложенные события (порядок важен: «запрос» после «готово» снова сделал бы сеанс «работающим»).
    if flush && post 2 "/api/event?kind=$KIND&entry=$ENTRY"; then exit 0; fi
    enqueue
    exit 0
    ;;
esac
