#!/bin/sh
# claude-notifier: установка хуков Claude Code на этот Mac.
# Скрипт выдан ПК __PCNAME__ один раз; он содержит личный токен этого Mac — не публикуйте его.
set -e
DIR="$HOME/.claude-notifier"
BASE='__URL__'

echo "claude-notifier: установка на этот Mac…"
mkdir -p "$DIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Файлы сверяются с SHA-256 из этого скрипта: подменённые по дороге (сеть без шифрования) не ставятся.
fetch() {
  curl -fsS -m 10 "$BASE/mac/$1" -o "$TMP/$1"
  GOT="$(shasum -a 256 "$TMP/$1" | cut -d' ' -f1)"
  if [ "$GOT" != "$2" ]; then
    echo "claude-notifier: файл $1 не совпадает с ожидаемым — установка прервана." >&2
    exit 1
  fi
  mv -f "$TMP/$1" "$DIR/$1"
}
fetch hook.sh '__SHA_HOOK__'
fetch settings.js '__SHA_SETTINGS__'
fetch uninstall.sh '__SHA_UNINSTALL__'
chmod 755 "$DIR/hook.sh" "$DIR/uninstall.sh"

umask 077
cat > "$DIR/env" <<'EOF'
CN_URL='__URL__'
CN_URL2='__URL2__'
EOF
# Токен — в отдельном файле заголовка (curl -H @файл): в командной строке curl его видно через ps.
printf '%s\n' 'Authorization: Bearer __TOKEN__' > "$DIR/auth"

mkdir -p "$HOME/.claude"
osascript -l JavaScript "$DIR/settings.js" install "$HOME/.claude/settings.json" "$DIR/hook.sh"

NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
SAFE="$(printf '%s' "$NAME" | tr -d '"\\')"
printf '{"name":"%s"}' "$SAFE" | curl -fsS -m 5 -X POST \
  -H @"$DIR/auth" -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary @- "$BASE/api/hello" >/dev/null || true

echo "Готово: «$NAME» подключён к ПК __PCNAME__."
echo "Новые запросы в Claude Code на этом Mac появятся в окне «Сеансы» на ПК."
echo "Удалить: ~/.claude-notifier/uninstall.sh"
