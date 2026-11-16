# Product Requirements Document (PRD)

---

prd_version: 0.1.0
sha: "uncommitted"
generated: "2026-11-16T00:00:00Z"
mode: "Greenfield"

---

## 1. Summary

**claude-notifier**: фоновая программа для Windows 11 с иконкой в трее. Она показывает toast-уведомления со звуком, когда сессия Claude Code (desktop-приложение или CLI) завершила задачу, ждёт разрешения, упала с ошибкой или подходит к лимиту использования. В уведомлении видно превью сообщения Claude. Клик по нему переключает на окно этой сессии. События приходят из официальных хуков Claude Code и из JSON строки статуса (`statusLine`). Сеть не используется. Режим: Greenfield. Источник требований: [d_domain_analysis.md](d_domain_analysis.md).

## 2. Goals & Non-goals

### Goals

- **G-1** Сократить простой Claude в ожидании пользователя: от события до уведомления ≤ 1 с (P95). *(J-1, J-2)*
- **G-2** Тип события понятен без взгляда на экран: 4 разных звука, 100 % событий со звуком. *(R-6)*
- **G-3** Переход к нужной сессии за 1 клик в ≥ 90 % случаев. *(J-5)*
- **G-4** Предупреждать о лимите заранее: 2 порога (80 %, 90 %) для 5-часового и недельного окна. *(J-4)*
- **G-5** Установка и удаление за ≤ 2 команды, без ручной правки `settings.json`.

### Non-goals

- Telegram, мессенджеры, мобильные push-уведомления. *(R-2)*
- Чат claude.ai и Claude API как источники. *(R-3)*
- Режим «Не беспокоить», автозапуск с Windows, настройки через меню трея: не выбраны на интервью.
- Подавление уведомлений, когда окно Claude активно. *(R-4)*
- macOS и Linux.

## 3. Personas

| Persona | Role | Pain-point |
|---------|------|-----------|
| Разработчик-оператор | Единственный пользователь; Windows 11; Claude Code desktop и CLI; работает в других окнах | Не замечает, что сессия Claude ждёт его или завершилась |

## 4. Functional Requirements

| ID | Requirement | Priority | Epic |
|----|-------------|----------|------|
| FR-1 | Установщик добавляет хуки и `statusLine` в `~/.claude/settings.json`, сохраняя чужие записи; деинсталлятор удаляет только свои. | Must | [e_001](prd/e_001.md) |
| FR-2 | Хук `Stop` создаёт событие **«Готово»** с превью из поля `last_assistant_message`. | Must | [e_001](prd/e_001.md) |
| FR-3 | Хук `Notification` с типом `permission_prompt`, `elicitation_dialog` или `agent_needs_input` создаёт событие **«Нужно разрешение»** с текстом из `message`. | Must | [e_001](prd/e_001.md) |
| FR-4 | Хук `StopFailure` создаёт событие **«Ошибка»** с полями `error` и `error_details`. | Must | [e_001](prd/e_001.md) |
| FR-5 | Хук-мост завершается за ≤ 500 мс и никогда не блокирует и не меняет работу Claude Code. | Must | [e_001](prd/e_001.md) |
| FR-6 | Если трей-программа не запущена, хук-мост запускает её и передаёт событие. | Should | [e_001](prd/e_001.md) |
| FR-7 | Toast показывает тип события, имя папки проекта из `cwd` и превью ≤ 200 символов. | Must | [e_002](prd/e_002.md) |
| FR-8 | Каждый из 4 типов событий играет свой звук; по умолчанию это системный звук Windows. | Must | [e_002](prd/e_002.md) |
| FR-9 | Файл настроек позволяет задать свой WAV для каждого типа события и выключить тип целиком. | Must | [e_002](prd/e_002.md) |
| FR-10 | Уведомления показываются всегда, независимо от того, какое окно активно. | Must | [e_002](prd/e_002.md) |
| FR-11 | Клик по toast выводит на передний план окно сессии: терминал для CLI, приложение Claude для desktop. | Must | [e_003](prd/e_003.md) |
| FR-12 | Скрипт `statusLine` читает `rate_limits.five_hour` и `rate_limits.seven_day` и создаёт событие **«Лимит»** при 80 % и 90 %. | Must | [e_004](prd/e_004.md) |
| FR-13 | Каждый порог срабатывает не чаще одного раза за окно, до смены его `resets_at`. | Must | [e_004](prd/e_004.md) |
| FR-14 | Скрипт `statusLine` выводит строку статуса: модель, % контекста, % лимитов. | Should | [e_004](prd/e_004.md) |
| FR-15 | Иконка в трее с меню: «История» (последние 20 событий) и «Выход». | Must | [e_005](prd/e_005.md) |
| FR-16 | Клик по пункту истории действует так же, как клик по toast (FR-11). | Must | [e_005](prd/e_005.md) |
| FR-17 | README описывает, как выключить встроенные уведомления desktop-приложения Claude, чтобы не было дублей. | Must | [e_005](prd/e_005.md) |

## 5. Non-functional Requirements

| Aspect | Target | Rationale |
|--------|--------|-----------|
| Performance | Событие → toast ≤ 1 с (P95); хук-мост ≤ 500 мс | G-1, FR-5 (было 200 мс; пересмотрено 2026-11-16: старт powershell.exe ≈ 160 мс, замер bridge ≈ 373 мс) |
| Availability | Падение трей-программы не влияет на Claude Code; хук всегда завершается с кодом 0 | Хуки не должны мешать работе |
| Security | Только локальное взаимодействие (named pipe или localhost); без сети; секреты не пишутся в лог | H-10, S-4 |
| Compatibility | Запуск при включённом Smart App Control; без неподписанных нативных DLL из pip/npm | §5 анализа: DLL `pydantic_core` заблокирована |
| Resource usage | В простое ≤ 150 МБ RAM, ≈ 0 % CPU | Работает постоянно (было 50 МБ; пересмотрено 2026-11-16: пустой powershell.exe — 70 МБ, трей через 10 мин простоя — 61 МБ рабочего набора, 122 МБ приватной памяти) |
| Accessibility | Тип события передаётся и текстом, и звуком | G-2 |
| Observability | Локальный лог с ротацией ≤ 1 МБ; история ≤ 100 событий на диске | Отладка хуков |

## 6. UI / UX Overview

> “(UI/UX flows will be added by UX-Designer in `ui_ux.md`).”

- **Toast:** заголовок «<Тип> · <папка проекта>», текст: превью, звук по типу.
- **Меню трея:** «История ▸» (20 событий: время, тип, проект), «Выход».

## 7. API / Data Contracts

| Endpoint / Module | Current | Proposed |
|-------------------|---------|----------|
| Вход хука `Stop` (stdin JSON) | Claude Code | Читать `session_id`, `cwd`, `transcript_path`, `last_assistant_message` |
| Вход хука `Notification` | Claude Code | Читать `message`, `title`, `notification_type` |
| Вход хука `StopFailure` | Claude Code | Читать `error`, `error_details`, `last_assistant_message` |
| Вход `statusLine` | Claude Code | Читать `rate_limits.{five_hour,seven_day}.{used_percentage,resets_at}`, `context_window.used_percentage` |
| Событие мост → трей | — | `{type, session_id, project, preview, ts, origin: desktop\|cli, window_hint}` |

Поля сверены с документацией Claude Code (hooks, statusline) 2026-11-16.

## 8. Dependencies / Constraints

| Package | Version | Licence | Impact |
|---------|---------|---------|--------|
| Стек не выбран | — | — | Решает архитектор с учётом Smart App Control (NFR Compatibility) |

- `rate_limits` есть только у подписчиков Pro, Max и Ultra и только после первого ответа в сессии.
- Документированного deep-link для открытия конкретной desktop-сессии нет. Поэтому FR-11 для desktop выводит на передний план окно приложения.
- `~/.claude/settings.json` на ПК пока не существует; `claude` не найден в PATH PowerShell.

## 9. Acceptance Criteria by Epic

| Epic | Title |
|------|-------|
| [e_001](prd/e_001.md) | Хук-мост и установщик |
| [e_002](prd/e_002.md) | Toast-уведомления и звуки |
| [e_003](prd/e_003.md) | Переход к сессии по клику |
| [e_004](prd/e_004.md) | Предупреждения о лимитах |
| [e_005](prd/e_005.md) | Трей-программа и история |

## 10. Glossary

Определения терминов (Сессия, Событие, Хук, Toast, Превью, Трей): [d_domain_analysis.md §6](d_domain_analysis.md#6-глоссарий). Дополнительно:

| Term | Definition |
|------|------------|
| Хук-мост | Короткий процесс, который Claude Code запускает на хук; передаёт событие в трей-программу и сразу завершается. |
| `statusLine` | Скрипт строки статуса Claude Code; получает на stdin JSON с данными о контексте и лимитах. |
| Окно лимита | 5-часовое (`five_hour`) или недельное (`seven_day`) окно использования Claude. |

## 11. Open Questions (для архитектора)

- **OQ-1** Как отличить desktop-сессию от CLI и найти окно терминала для FR-11?
- **OQ-2** Запускается ли `statusLine` в desktop-приложении? Если нет, FR-12 работает только в CLI.
- **OQ-3** Какой стек и механизм toast совместимы со Smart App Control?
