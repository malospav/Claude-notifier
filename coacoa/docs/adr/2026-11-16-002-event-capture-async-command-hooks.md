---
adr_id: "2026-11-16-002"
title: "Захват событий: async command-хуки + bridge"
status: "Proposed"
deciders: ["architect", "pm", "user"]
date: "2026-11-16"
supersedes: []
---

# Context
Claude Code умеет хуки типов `command` и `http`. Нужно: не тормозить Claude (≤ 500 мс; изначально 200 мс, см. Consequences), знать origin (`CLAUDE_CODE_ENTRYPOINT`) и окно консоли, запускать трей, если он не работает.

# Decision
Хуки `Stop`, `Notification` и `StopFailure` пишутся как `type: "command"` в exec-форме (`command: "powershell.exe"`, `args: [...]`) с `async: true`. Скрипт `hook-bridge.ps1` наследует переменные среды и консоль Claude Code. Это позволяет определить origin и окно и при необходимости запустить трей.

# Consequences
+ Claude Code не ждёт bridge, поэтому его время не задерживает Claude.
− Сам bridge на PowerShell 5.1 работает ≈ 373 мс (замер 2026-11-16, s_001_04): бюджет FR-5 пересмотрен с 200 до 500 мс.
+ Работает, даже если трей не запущен.
− На каждое событие запускается отдельный процесс PowerShell (≈ 130 мс). Это приемлемо: событий единицы в минуту.

# Alternatives
- **`type: "http"` прямо в трей:** нет доступа к консоли и дереву процессов, трей нельзя поднять, при выключенном трее событие теряется.
- **Синхронный command-хук:** задерживал бы Claude на ≈ 130 мс на каждое событие.
