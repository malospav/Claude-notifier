#!/bin/sh
# claude-notifier: удаляет хуки с этого Mac (Linux, WSL) и папку ~/.claude-notifier.
DIR="$HOME/.claude-notifier"
S="$HOME/.claude/settings.json"
if [ -f "$S" ]; then
  if command -v osascript >/dev/null 2>&1 && [ -f "$DIR/settings.js" ]; then osascript -l JavaScript "$DIR/settings.js" uninstall "$S" "$DIR/hook.sh"
  elif command -v node >/dev/null 2>&1 && [ -f "$DIR/settings.js" ]; then node "$DIR/settings.js" uninstall "$S" "$DIR/hook.sh"
  elif command -v python3 >/dev/null 2>&1 && [ -f "$DIR/settings.py" ]; then python3 "$DIR/settings.py" uninstall "$S" "$DIR/hook.sh"
  fi
fi
rm -rf "$DIR"
echo "claude-notifier удалён с этого компьютера. На ПК устройство можно убрать во вкладке «Устройства»."
