#!/bin/sh
# claude-notifier: установка хуков Claude Code на этот Mac.
# Скрипт выдан ПК __PCNAME__ один раз; он содержит личный токен этого Mac — не публикуйте его.
set -e
DIR="$HOME/.claude-notifier"
BASE='__URL__'

echo "claude-notifier: установка на этот Mac…"
mkdir -p "$DIR"
curl -fsS -m 10 "$BASE/mac/hook.sh" -o "$DIR/hook.sh"
curl -fsS -m 10 "$BASE/mac/settings.js" -o "$DIR/settings.js"
curl -fsS -m 10 "$BASE/mac/uninstall.sh" -o "$DIR/uninstall.sh"
chmod 755 "$DIR/hook.sh" "$DIR/uninstall.sh"

umask 077
cat > "$DIR/env" <<'EOF'
CN_URL='__URL__'
CN_URL2='__URL2__'
CN_TOKEN='__TOKEN__'
EOF

mkdir -p "$HOME/.claude"
osascript -l JavaScript "$DIR/settings.js" install "$HOME/.claude/settings.json" "$DIR/hook.sh"

NAME="$(scutil --get ComputerName 2>/dev/null || hostname)"
SAFE="$(printf '%s' "$NAME" | tr -d '"\\')"
printf '{"name":"%s"}' "$SAFE" | curl -fsS -m 5 -X POST \
  -H 'Authorization: Bearer __TOKEN__' -H 'Content-Type: application/json; charset=utf-8' \
  --data-binary @- "$BASE/api/hello" >/dev/null || true

echo "Готово: «$NAME» подключён к ПК __PCNAME__."
echo "Новые запросы в Claude Code на этом Mac появятся в окне «Сеансы» на ПК."
echo "Удалить: ~/.claude-notifier/uninstall.sh"
