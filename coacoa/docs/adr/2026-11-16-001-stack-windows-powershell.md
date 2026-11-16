---
adr_id: "2026-11-16-001"
title: "Стек: Windows PowerShell 5.1 + .NET Framework"
status: "Proposed"
deciders: ["architect", "pm", "user"]
date: "2026-11-16"
supersedes: []
---

# Context
На целевом ПК включён Smart App Control. При установке CoaCoA он заблокировал неподписанную DLL `pydantic_core`. Нужны трей, toast WinRT, звук и Win32-фокус окон. В `tech_preferences.md` нет правил для десктопных Windows-утилит.

# Decision
Используем только компоненты Windows: `powershell.exe` 5.1, .NET Framework (WinForms `NotifyIcon`, `System.IO.Pipes`, `System.Media.SoundPlayer`), WinRT через `ContentType=WindowsRuntime`, Win32 через `Add-Type`. Всё это проверено на ПК при включённом SAC 2026-11-16. Это осознанное отступление от `tech_preferences.md`: в нём нет подходящего стека.

# Consequences
+ Ничего не нужно устанавливать, и нет риска, что SAC заблокирует бинарники.
+ Код открыт и правится без сборки.
− Старт процесса ≈ 130 мс, что медленнее Python (≈ 50 мс). Это компенсирует `async` (ADR-002).
− Нужна дисциплина: UTF-8 с BOM и синтаксис PowerShell 5.1.

# Alternatives
- **Python 3.12 + pystray/winotify:** у этих пакетов нативные DLL без подписи, которые SAC может заблокировать (прецедент — `pydantic_core`).
- **C#/.NET 8 exe:** собранный локально неподписанный exe может заблокировать SAC; плюс нужен SDK.
- **Node.js + node-notifier:** тянет сторонний SnoreToast.exe; та же проблема с SAC.
