#!/bin/sh
# claude-notifier: удаляет хуки с этого Mac и папку ~/.claude-notifier.
DIR="$HOME/.claude-notifier"
if [ -f "$HOME/.claude/settings.json" ] && [ -f "$DIR/settings.js" ]; then
  osascript -l JavaScript "$DIR/settings.js" uninstall "$HOME/.claude/settings.json" "$DIR/hook.sh"
fi
rm -rf "$DIR"
echo "claude-notifier удалён с этого Mac. На ПК устройство можно убрать во вкладке «Устройства»."
