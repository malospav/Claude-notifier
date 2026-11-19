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
# Шифрование (https): отпечаток открытого ключа ПК из установки — curl проверяет его в каждом запросе.
if [ -n "${CN_PIN:-}" ]; then curl() { command curl -k --pinnedpubkey "sha256//$CN_PIN" "$@"; }; fi
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
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
# Хуки в settings.json: macOS — osascript, Linux и WSL — node или python3.
settings_edit() {
  S="$HOME/.claude/settings.json"
  case "${CN_OS:-mac}" in
    mac) osascript -l JavaScript "$DIR/settings.js" "$1" "$S" "$DIR/hook.sh" ;;
    *) if command -v node >/dev/null 2>&1; then node "$DIR/settings.js" "$1" "$S" "$DIR/hook.sh"
       else python3 "$DIR/settings.py" "$1" "$S" "$DIR/hook.sh"; fi ;;
  esac
}
# Самообновление (в фоне, при старте сеанса): ПК обновился — скачать новые файлы, сверить SHA-256 из ответа ПК,
# заменить и переписать хуки. Любая ошибка — тихо остаёмся на старой версии.
self_update() {
  U="$(mktemp -d 2>/dev/null)" || return 0
  C="$(curl -s -m 5 -o "$U/m" -w '%{http_code}' -H "$AUTH" "$BASE/api/mac/update?have=$(cat "$DIR/version" 2>/dev/null)" 2>/dev/null)"
  NEWVER="$(sed -n 's/^version \([0-9a-f][0-9a-f]*\)$/\1/p' "$U/m" 2>/dev/null)"
  if [ "$C" != 200 ] || [ -z "$NEWVER" ]; then rm -rf "$U"; return 0; fi
  for F in hook.sh settings.js settings.py uninstall.sh; do
    WANT="$(awk -v f="$F" '$1 == f && length($2) == 64 { print $2 }' "$U/m")"
    if [ -z "$WANT" ] || ! curl -fsS -m 10 "$BASE/mac/$F" -o "$U/$F" 2>/dev/null || [ "$(sha256 "$U/$F")" != "$WANT" ]; then rm -rf "$U"; return 0; fi
  done
  for F in hook.sh settings.js settings.py uninstall.sh; do mv -f "$U/$F" "$DIR/$F"; done
  chmod 755 "$DIR/hook.sh" "$DIR/uninstall.sh"
  settings_edit install >/dev/null 2>&1
  printf '%s' "$NEWVER" > "$DIR/version"
  printf '{"replies":true,"version":"%s","os":"%s"}' "$NEWVER" "${CN_OS:-mac}" | curl -s -m 5 -o /dev/null -X POST \
    -H "$AUTH" -H 'Content-Type: application/json; charset=utf-8' --data-binary @- "$BASE/api/hello" 2>/dev/null
  rm -rf "$U"
}

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
    if flush && post 2 "/api/event?kind=$KIND&entry=$ENTRY"; then
      # Новый сеанс — заодно проверить, не обновились ли хуки на ПК (в фоне: Claude не ждёт).
      # Без файла версии — тоже: старая установка иначе никогда не обновилась бы.
      if [ "$KIND" = sessionstart ]; then ( self_update ) </dev/null >/dev/null 2>&1 & fi
      exit 0
    fi
    enqueue
    exit 0
    ;;
esac
