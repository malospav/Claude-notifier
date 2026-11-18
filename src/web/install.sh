#!/bin/sh
# claude-notifier: установка хуков Claude Code на этот Mac, Linux или в WSL.
# Скрипт выдан ПК __PCNAME__ один раз; он содержит личный токен этого компьютера — не публикуйте его.
set -e
DIR="$HOME/.claude-notifier"
BASE='__URL__'
# Отпечаток открытого ключа ПК (https): curl проверяет его вместо цепочки сертификатов. Пусто — шифрования нет.
PIN='__PIN__'
if [ -n "$PIN" ]; then curl() { command curl -k --pinnedpubkey "sha256//$PIN" "$@"; }; fi

OS=linux
case "$(uname -s)" in Darwin) OS=mac ;; esac
if [ "$OS" = linux ] && grep -qi microsoft /proc/version 2>/dev/null; then OS=wsl; fi
echo "claude-notifier: установка на этот компьютер…"
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Файлы сверяются с SHA-256 из этого скрипта: подменённые по дороге (сеть без шифрования) не ставятся.
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1"; else sha256sum "$1"; fi | cut -d' ' -f1; }
fetch() {
  curl -fsS -m 10 "$BASE/mac/$1" -o "$TMP/$1"
  GOT="$(sha256 "$TMP/$1")"
  if [ "$GOT" != "$2" ]; then
    echo "claude-notifier: файл $1 не совпадает с ожидаемым — установка прервана." >&2
    exit 1
  fi
  mv -f "$TMP/$1" "$DIR/$1"
}
fetch hook.sh '__SHA_HOOK__'
fetch settings.js '__SHA_SETTINGS__'
fetch settings.py '__SHA_SETTINGS_PY__'
fetch uninstall.sh '__SHA_UNINSTALL__'
chmod 755 "$DIR/hook.sh" "$DIR/uninstall.sh"

# WSL: ПК — это Windows, на которой работает WSL; второй адрес — шлюз виртуальной сети (имя .local там не находится).
URL2='__URL2__'
if [ "$OS" = wsl ]; then
  GW="$(ip route show default 2>/dev/null | awk '{print $3; exit}')"
  PORT="${BASE##*:}"; case "$PORT" in *[!0-9]*|"") PORT="" ;; esac
  if [ -n "$GW" ] && [ -n "$PORT" ]; then URL2="${BASE%%://*}://$GW:$PORT"; fi
fi
umask 077
cat > "$DIR/env" <<EOF
CN_URL='$BASE'
CN_URL2='$URL2'
CN_OS='$OS'
CN_PIN='$PIN'
EOF
printf '%s' '__HOOKS_VER__' > "$DIR/version"   # hook.sh сверяет её с ПК и сам обновляется
# Токен — в отдельном файле заголовка (curl -H @файл): в командной строке curl его видно через ps.
printf '%s\n' 'Authorization: Bearer __TOKEN__' > "$DIR/auth"

mkdir -p "$HOME/.claude"
# Хуки в settings.json: macOS — osascript (есть всегда); Linux и WSL — node, а если его нет — python3.
if [ "$OS" = mac ]; then osascript -l JavaScript "$DIR/settings.js" install "$HOME/.claude/settings.json" "$DIR/hook.sh"
elif command -v node >/dev/null 2>&1; then node "$DIR/settings.js" install "$HOME/.claude/settings.json" "$DIR/hook.sh"
elif command -v python3 >/dev/null 2>&1; then python3 "$DIR/settings.py" install "$HOME/.claude/settings.json" "$DIR/hook.sh"
else echo "claude-notifier: нужен node или python3, чтобы изменить ~/.claude/settings.json — установите один из них." >&2; exit 1
fi

NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
[ "$OS" = wsl ] && NAME="$NAME (WSL)"
SAFE="$(printf '%s' "$NAME" | tr -d '"\\')"
# replies — эти хуки умеют ждать решения и быстрого ответа с ПК: у сеансов Mac на ПК появятся кнопки ответа.
printf '{"name":"%s","replies":true,"version":"__HOOKS_VER__","os":"%s"}' "$SAFE" "$OS" | curl -fsS -m 5 -X POST \
  -H @"$DIR/auth" -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary @- "$BASE/api/hello" >/dev/null || true

echo "Готово: «$NAME» подключён к ПК __PCNAME__."
echo "Новые запросы в Claude Code здесь появятся в шторке и окне «Сеансы» на ПК."
echo "Удалить: ~/.claude-notifier/uninstall.sh"
