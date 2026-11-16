---
adr_id: "2026-11-16-003"
title: "IPC: named pipe + очередь в runspace"
status: "Proposed"
deciders: ["architect", "pm", "user"]
date: "2026-11-16"
supersedes: []
---

# Context
Трей-программа — однопоточное WinForms-приложение. События приходят из других процессов.

# Decision
Сервер `NamedPipeServerStream` с именем `claude-notifier-<USERNAME>` и DACL только для текущего пользователя работает в отдельном runspace. Кадр — одна строка JSON (событие v1). Сервер кладёт события в `ConcurrentQueue`, а `System.Windows.Forms.Timer` раз в 100 мс разбирает очередь в UI-потоке.

# Consequences
+ Нет сетевых портов, нет конфликтов портов, межсетевой экран не участвует.
+ UI-код выполняется только в UI-потоке.
− Нужен аккуратный перезапуск сервера после каждого клиента (цикл `WaitForConnection`).

# Alternatives
- **HttpListener на 127.0.0.1:** работает (проверено), но возможны конфликты портов, и другой локальный процесс может подключиться без DACL.
- **Файл-очередь + FileSystemWatcher:** медленнее и ненадёжно при параллельной записи.
