// claude-notifier: элементы интерфейса в стиле Apple (WinForms + GDI+, C# 5 для csc из .NET Framework).
// Сгруппированные списки, сегментный переключатель, тумблер, кнопки-капсулы, ячейки кода, точка статуса для трея.
// Движение — по принципам Apple / Emil Kowalski: отклик на нажатие сразу, ease-out, прерываемые анимации
// с текущего значения, частые действия (обновление списка, клавиатура) не анимируются, «меньше движения» в Windows уважается.
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace ClaudeNotifier.Ui {
    // Нажатия кнопок в уведомлениях Windows: подписка на ToastNotification.Activated.
    // Windows PowerShell 5.1 не подписывается на события WinRT, а EventInfo.AddEventHandler для них не работает —
    // поэтому через WindowsRuntimeMarshal.AddEventHandler (mscorlib), собранный отражением. Аргументы нажатой
    // кнопки кладутся в очередь; трей разбирает её в своём таймере (UI-поток).
    public static class ToastHook {
        public static readonly System.Collections.Concurrent.ConcurrentQueue<string> Queue = new System.Collections.Concurrent.ConcurrentQueue<string>();

        public static void Attach(object toast) {
            System.Reflection.EventInfo ev = toast.GetType().GetEvent("Activated");
            Type handlerType = ev.EventHandlerType;
            System.Reflection.MethodInfo add = ev.GetAddMethod(), remove = ev.GetRemoveMethod();
            Type tokenType = add.ReturnType;
            Delegate addD = Delegate.CreateDelegate(typeof(Func<,>).MakeGenericType(handlerType, tokenType), toast, add);
            Delegate removeD = Delegate.CreateDelegate(typeof(Action<>).MakeGenericType(tokenType), toast, remove);
            System.Reflection.MethodInfo on = typeof(ToastHook).GetMethod("OnActivated", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
            Delegate handler = Delegate.CreateDelegate(handlerType, on);
            Type marshal = typeof(object).Assembly.GetType("System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeMarshal", true);
            foreach (System.Reflection.MethodInfo m in marshal.GetMethods(System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Static)) {
                if (m.Name == "AddEventHandler" && m.IsGenericMethodDefinition) {
                    m.MakeGenericMethod(handlerType).Invoke(null, new object[] { addD, removeD, handler });
                    return;
                }
            }
        }

        static void OnActivated(object sender, object args) {
            string a = "";
            try {
                Type t = Type.GetType("Windows.UI.Notifications.ToastActivatedEventArgs, Windows.UI.Notifications, ContentType=WindowsRuntime");
                a = (string)t.GetProperty("Arguments").GetValue(args, null);
            } catch { }
            Queue.Enqueue(a ?? "");
        }
    }
}
