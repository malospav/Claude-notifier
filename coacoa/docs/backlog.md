# Backlog — claude-notifier

> Составлен scrum-master на основе PRD и архитектуры: этап `/po-refine-epics` пропущен. Приоритет эпиков задан порядком зависимостей компонентов.

## Ranking

| Rank | Epic | Title | Priority |
|---|---|---|---|
| 1 | [e_001](prd/e_001.md) | Хук-мост и установщик | P1 |
| 2 | [e_003](prd/e_003.md) | Переход к сессии по клику | P1 |
| 3 | [e_002](prd/e_002.md) | Toast-уведомления и звуки | P1 |
| 4 | [e_005](prd/e_005.md) | Трей-программа и история | P1 |
| 5 | [e_004](prd/e_004.md) | Предупреждения о лимитах | P2 |

## Dependencies

- e_001: []
- e_003: []
- e_002: [e_001]
- e_005: [e_001, e_002, e_003]
- e_004: [e_001]

## Stories

| Story | Title | Depends on |
|---|---|---|
| [s_001_01](prd/stories/s_001_01.md) | Каркас репозитория, Config, Log, Pester | — |
| [s_001_02](prd/stories/s_001_02.md) | Event: вход хука → событие v1 | s_001_01 |
| [s_001_03](prd/stories/s_001_03.md) | Ipc: named pipe клиент/сервер | s_001_01 |
| [s_001_04](prd/stories/s_001_04.md) | hook-bridge.ps1 | s_001_02, s_001_03, s_003_01 |
| [s_001_05](prd/stories/s_001_05.md) | Settings + install/uninstall (хуки) | s_001_04 |
| [s_003_01](prd/stories/s_003_01.md) | Window: поиск и фокус окна | s_001_01 |
| [s_003_02](prd/stories/s_003_02.md) | focus-handler.ps1 + URL-протокол | s_003_01, s_001_05 |
| [s_002_01](prd/stories/s_002_01.md) | Toast + AUMID | s_001_02, s_003_02 |
| [s_002_02](prd/stories/s_002_02.md) | Sound: звук на тип события | s_001_01 |
| [s_005_01](prd/stories/s_005_01.md) | Трей: один экземпляр, приём событий, показ | s_002_01, s_002_02, s_001_03 |
| [s_005_02](prd/stories/s_005_02.md) | История + меню | s_005_01 |
| [s_005_03](prd/stories/s_005_03.md) | README + сквозная ручная проверка | s_005_02, s_004_02 |
| [s_004_01](prd/stories/s_004_01.md) | Limits: пороги и дедупликация | s_001_01 |
| [s_004_02](prd/stories/s_004_02.md) | statusline.ps1 + установка | s_004_01, s_001_03, s_001_05 |
