---
adr_id: "2026-11-16-006"
title: "Клик по toast не обрабатывается; переход к сессии — через «Историю» в трее"
status: "Accepted"
deciders: ["architect", "dev", "user"]
date: "2026-11-16"
supersedes: ["2026-11-16-004"]
---

# Context
ADR-004 предполагал: AUMID «ClaudeNotifier» в HKCU + `activationType="protocol"` → клик открывает `claude-notifier:focus?id=…`. Живая проверка на целевом ПК (Windows 11 26200, Smart App Control On) 2026-11-16:

| Вариант | Результат клика |
|---|---|
| AUMID ClaudeNotifier, `protocol` → `claude-notifier:` | окно Microsoft Store «нет программы» |
| AUMID ClaudeNotifier, `protocol` → пробные протоколы (с `conhost` и без) | Store / ничего; обработчик не запускается |
| AUMID ClaudeNotifier, `foreground` + подписка на `Activated` | Store; `Activated` не приходит |
| то же + `SetCurrentProcessExplicitAppUserModelID` | `Activated` не приходит |
| AUMID Windows PowerShell, `foreground` / `protocol` | уведомление просто закрывается; `Activated` не приходит |

При этом протокол зарегистрирован верно: `ShellExecute` и `Launcher.LaunchUriAsync` из обычного процесса его запускают; подписка на события WinRT исправна (`Dismissed` приходит). Windows 11 доставляет активацию toast только приложению с исполняемым COM-активатором (или пакетному приложению). Свой `.exe` противоречит ADR-001 (Smart App Control).

# Decision
- Toast показывается от AUMID Windows PowerShell, без атрибута `launch`: клик только закрывает уведомление (без окна Store).
- Переход к сессии — пункт «Истории» в меню трея: трей сам запускает `focus-handler.ps1` (через `conhost --headless`) с правом на передний план (`AllowSetForegroundWindow`). Проверено пользователем.
- Протокол `claude-notifier:` сохраняется (переход по ссылке, Win+R); AUMID «ClaudeNotifier» больше не регистрируется, ключ от прежних версий установщик удаляет.

# Consequences
+ Нет окна Store при клике; переход к сессии работает (2 клика через трей).
− FR-11 («клик по toast открывает сессию») выполняется только через историю; e_003 AC-1/AC-2 для toast не выполнены.
− В уведомлении подпись «Windows PowerShell» и его иконка, а не «Claude Notifier».

# Alternatives
- **Свой exe с COM-активатором (C#/.NET):** единственный штатный путь, но неподписанный exe блокирует Smart App Control (ADR-001).
- **COM LocalServer32 = powershell.exe + скрипт:** не реализует `INotificationActivationCallback`, поведение не гарантировано; отложено.
- **Store-пакет / MSIX:** требует подписи и упаковки — вне рамок утилиты.

# Update 2026-11-17: ярлык с AppUserModelID
- Установщик создаёт ярлык «Claude Notifier» в меню «Пуск» (и на рабочем столе) с `PKEY_AppUserModel_ID = ClaudeNotifier.App` и иконкой приложения; трей вызывает `SetCurrentProcessExplicitAppUserModelID` с тем же ID.
- Проверено вживую: уведомление от `ClaudeNotifier.App` **без** `launch` подписано «Claude Notifier» с нашей иконкой, клик закрывает его. С `launch="claude-notifier:…"` и `activationType="protocol"` клик по-прежнему открывает окно Store — exe-активатор всё так же нужен.
- Решение: уведомления идут от `ClaudeNotifier.App`, если ярлык есть (иначе — AUMID PowerShell), без действия по клику. Последствие «подпись Windows PowerShell» снято; переход к сессии — через окно «Сеансы» и «Историю».
