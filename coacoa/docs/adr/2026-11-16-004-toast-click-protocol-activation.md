---
adr_id: "2026-11-16-004"
title: "Клик по toast: AUMID + URL-протокол"
status: "Superseded"
deciders: ["architect", "pm", "user"]
date: "2026-11-16"
supersedes: []
---

# Context
Событие `Activated` у WinRT-toast работает, только пока процесс жив и toast ещё на экране. Клик из Центра уведомлений запускает приложение по AUMID. Если взять AUMID PowerShell, откроется консоль PowerShell.

# Decision
Установщик регистрирует в HKCU:
1. AUMID `ClaudeNotifier` (`Software\Classes\AppUserModelId\ClaudeNotifier`: `DisplayName`, `IconUri`).
2. URL-протокол `claude-notifier:` (`Software\Classes\claude-notifier`), команда: `conhost.exe --headless powershell.exe -NoProfile -File focus-handler.ps1 "%1"`.

Toast создаётся с `activationType="protocol"`, `launch="claude-notifier:focus?id=<event_id>"`. Обработчик ищет id в локальной истории и сам фокусирует окно: его запустил клик пользователя, поэтому у него есть право на передний план.

# Consequences
+ Клик работает и из всплывающего toast, и из Центра уведомлений, даже после перезапуска трея.
+ В уведомлении написано «Claude Notifier», а не «Windows PowerShell».
− Записи в HKCU должен удалять деинсталлятор.

# Alternatives
- **`NotifyIcon.ShowBalloonTip` + `BalloonTipClicked`:** нельзя кликнуть из Центра уведомлений; нет полноценного XML-шаблона.
- **Событие `Activated` WinRT:** ненадёжно (см. Context).
