// claude-notifier: загрузка ПК для свёрнутой шторки — ЦП, ГП и занятая память, как в диспетчере задач.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace ClaudeNotifier.Ui {
    // Фоновый поток с пониженным приоритетом опрашивает счётчики раз в 2 с — и только пока показатели кому-то нужны:
    // шторка зовёт Want() из таймера анимации, пока они видны. Не звали 6 с (раскрыта, вас нет, экран заблокирован) —
    // поток спит и ничего не считает. Значение < 0 — нет данных (счётчик недоступен).
    public static class SysStats {
        public static volatile float Cpu = -1, Gpu = -1, MemUsedGb = -1, MemTotalGb = -1;
        public static int Version;            // растёт с каждым новым замером — шторке понятно, когда перерисовать
        public static double LastSampleMs;    // сколько занял последний замер (для проверки нагрузки)
        static long wantedUntil;
        static Thread thread;
        static readonly object gate = new object();

        public static void Want() {
            Interlocked.Exchange(ref wantedUntil, DateTime.UtcNow.AddSeconds(6).Ticks);
            lock (gate) {
                if (thread != null) return;
                thread = new Thread(Loop);
                thread.IsBackground = true;
                thread.Priority = ThreadPriority.BelowNormal;
                thread.Name = "SysStats";
                thread.Start();
            }
        }

        public static bool Wanted { get { return DateTime.UtcNow.Ticks <= Interlocked.Read(ref wantedUntil); } }

        static void Loop() {
            PerformanceCounter cpu = null;
            bool cpuPrimed = false;
            while (true) {
                if (!Wanted) { Thread.Sleep(1000); continue; }
                Stopwatch sw = Stopwatch.StartNew();
                // ЦП: «% загруженности процессора» (как в диспетчере задач), иначе классическое «% времени процессора».
                try {
                    if (cpu == null) { cpu = CreateCpu(); cpuPrimed = false; }
                    float v = cpu.NextValue();   // первый замер всегда 0 — нужен второй
                    if (cpuPrimed) Cpu = Clamp(v); else cpuPrimed = true;
                } catch { Cpu = -1; if (cpu != null) { try { cpu.Dispose(); } catch { } cpu = null; } }
                try { ReadMemory(); } catch { MemUsedGb = -1; }
                try { Gpu = ReadGpu(); } catch { Gpu = -1; }
                LastSampleMs = sw.Elapsed.TotalMilliseconds;
                Interlocked.Increment(ref Version);
                Thread.Sleep(2000);
            }
        }

        static float Clamp(float v) { return float.IsNaN(v) ? 0 : Math.Max(0, Math.Min(100, v)); }

        static PerformanceCounter CreateCpu() {
            try {
                PerformanceCounter c = new PerformanceCounter("Processor Information", "% Processor Utility", "_Total", true);
                c.NextValue();
                return c;
            } catch {
                return new PerformanceCounter("Processor", "% Processor Time", "_Total", true);
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        struct MEMORYSTATUSEX {
            public uint dwLength, dwMemoryLoad;
            public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);

        static void ReadMemory() {
            MEMORYSTATUSEX m = new MEMORYSTATUSEX();
            m.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
            if (!GlobalMemoryStatusEx(ref m)) { MemUsedGb = -1; return; }
            const double gb = 1024.0 * 1024 * 1024;
            MemTotalGb = (float)(m.ullTotalPhys / gb);
            MemUsedGb = (float)((m.ullTotalPhys - m.ullAvailPhys) / gb);
        }

        // ГП: как в диспетчере задач — загрузка каждого движка (3D, копирование, видео…) суммируется по процессам,
        // берётся самый загруженный движок. Счётчики «GPU Engine» читаются одним вызовом за все экземпляры.
        static bool gpuMissing;
        static Dictionary<string, CounterSample> gpuPrev = new Dictionary<string, CounterSample>();

        static float ReadGpu() {
            if (gpuMissing) return -1;
            InstanceDataCollection util;
            try {
                PerformanceCounterCategory cat = new PerformanceCounterCategory("GPU Engine");
                util = cat.ReadCategory()["Utilization Percentage"];
            } catch (InvalidOperationException) { gpuMissing = true; return -1; }
            if (util == null) return -1;
            Dictionary<string, CounterSample> next = new Dictionary<string, CounterSample>();
            Dictionary<string, float> engines = new Dictionary<string, float>();
            bool any = false;
            foreach (InstanceData d in util.Values) {
                string name = d.InstanceName;
                CounterSample s = d.Sample;
                next[name] = s;
                CounterSample p;
                if (!gpuPrev.TryGetValue(name, out p)) continue;
                float v = CounterSample.Calculate(p, s);
                if (float.IsNaN(v) || v < 0) continue;
                int k = name.IndexOf("_luid_", StringComparison.OrdinalIgnoreCase);
                string key = k >= 0 ? name.Substring(k) : name;
                float sum;
                engines.TryGetValue(key, out sum);
                engines[key] = sum + v;
                any = true;
            }
            bool first = gpuPrev.Count == 0;
            gpuPrev = next;
            if (first) return Gpu;   // первый замер — только запомнить
            if (!any) return 0;
            float max = 0;
            foreach (float v in engines.Values) if (v > max) max = v;
            return Clamp(max);
        }
    }
}
