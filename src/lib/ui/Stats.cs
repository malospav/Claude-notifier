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
        public static volatile float CpuTemp = -1, GpuTemp = -1;   // °C; < 0 — температура недоступна
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
                // Температура — реже (раз в ~6 с): меняется медленно.
                if (tempTick++ % 3 == 0) {
                    try { GpuTemp = ReadGpuTemp(); } catch { GpuTemp = -1; }
                    try { CpuTemp = ReadCpuTemp(); } catch { CpuTemp = -1; }
                }
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

        // --- Температура ---
        static int tempTick;

        // ГП NVIDIA: nvml.dll из драйвера (System32) — без запуска nvidia-smi. Несколько видеокарт — самая горячая.
        [DllImport("nvml.dll", EntryPoint = "nvmlInit_v2")] static extern int NvmlInit();
        [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetCount_v2")] static extern int NvmlCount(out uint count);
        [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetHandleByIndex_v2")] static extern int NvmlHandle(uint index, out IntPtr device);
        [DllImport("nvml.dll", EntryPoint = "nvmlDeviceGetTemperature")] static extern int NvmlTemp(IntPtr device, int sensor, out uint temp);
        static int nvml;   // 0 — не пробовали, 1 — работает, -1 — нет NVIDIA или драйвера

        static float ReadGpuTemp() {
            if (nvml < 0) return -1;
            try {
                if (nvml == 0) { nvml = NvmlInit() == 0 ? 1 : -1; if (nvml < 0) return -1; }
                uint n;
                if (NvmlCount(out n) != 0 || n == 0) return -1;
                float max = -1;
                for (uint i = 0; i < n && i < 8; i++) {
                    IntPtr d; uint t;
                    if (NvmlHandle(i, out d) == 0 && NvmlTemp(d, 0, out t) == 0 && t > 0 && t < 130) max = Math.Max(max, t);
                }
                return max;
            }
            catch (DllNotFoundException) { nvml = -1; return -1; }
            catch (EntryPointNotFoundException) { nvml = -1; return -1; }
        }

        // ЦП: по очереди — счётчик «Thermal Zone Information» (ACPI, без прав администратора), запущенный
        // LibreHardwareMonitor / OpenHardwareMonitor (их WMI), MSAcpi_ThermalZoneTemperature. Что сработало, то и
        // опрашивается дальше; ничего — повторная попытка раз в минуту (монитор могли запустить позже).
        static string cpuSource;   // null — не искали, "" — не нашли, иначе имя источника
        static DateTime cpuRetry;

        static float ReadCpuTemp() {
            if (cpuSource == "" && DateTime.UtcNow < cpuRetry) return -1;
            string[] order = cpuSource != null && cpuSource != "" ? new string[] { cpuSource } : new string[] { "zone", "lhm", "web", "ohm", "acpi" };
            foreach (string src in order) {
                float v = -1;
                try { v = ReadCpuTempFrom(src); } catch { v = -1; }
                if (v > 0 && v < 130) { cpuSource = src; return v; }
            }
            cpuSource = ""; cpuRetry = DateTime.UtcNow.AddMinutes(1);
            return -1;
        }

        static float ReadCpuTempFrom(string src) {
            if (src == "zone") {
                PerformanceCounterCategory cat = new PerformanceCounterCategory("Thermal Zone Information");
                float max = -1;
                foreach (string inst in cat.GetInstanceNames()) {
                    float k = -1;
                    try { using (PerformanceCounter c = new PerformanceCounter("Thermal Zone Information", "High Precision Temperature", inst, true)) k = c.NextValue() / 10f; }
                    catch { using (PerformanceCounter c = new PerformanceCounter("Thermal Zone Information", "Temperature", inst, true)) k = c.NextValue(); }
                    if (k > 200) max = Math.Max(max, k - 273.15f);   // кельвины
                }
                return max;
            }
            if (src == "lhm" || src == "ohm") {
                string ns = src == "lhm" ? @"root\LibreHardwareMonitor" : @"root\OpenHardwareMonitor";
                float best = -1, any = -1;
                using (System.Management.ManagementObjectSearcher q = new System.Management.ManagementObjectSearcher(ns, "SELECT Name, Value, Identifier FROM Sensor WHERE SensorType='Temperature'"))
                    foreach (System.Management.ManagementObject o in q.Get()) {
                        string id = Convert.ToString(o["Identifier"]) ?? "", name = Convert.ToString(o["Name"]) ?? "";
                        if (id.IndexOf("cpu", StringComparison.OrdinalIgnoreCase) < 0) continue;
                        float v = Convert.ToSingle(o["Value"]);
                        // Предпочтительно — «пакет» или Tctl/Tdie (как показывают мониторы), иначе самый горячий датчик ЦП.
                        if (name.IndexOf("Package", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Tctl", StringComparison.OrdinalIgnoreCase) >= 0 || name.IndexOf("Tdie", StringComparison.OrdinalIgnoreCase) >= 0) best = Math.Max(best, v);
                        any = Math.Max(any, v);
                    }
                return best > 0 ? best : any;
            }
            if (src == "web") {
                // Веб-сервер LibreHardwareMonitor («Options → Remote Web Server → Run», порт 8085) — если WMI у него выключен.
                System.Net.HttpWebRequest rq = (System.Net.HttpWebRequest)System.Net.WebRequest.Create("http://127.0.0.1:8085/data.json");
                rq.Timeout = 600; rq.ReadWriteTimeout = 600; rq.Proxy = null;
                string json;
                using (System.Net.WebResponse rs = rq.GetResponse())
                using (System.IO.StreamReader sr = new System.IO.StreamReader(rs.GetResponseStream(), System.Text.Encoding.UTF8)) json = sr.ReadToEnd();
                float best = -1;
                foreach (System.Text.RegularExpressions.Match m in System.Text.RegularExpressions.Regex.Matches(json,
                    "\"Text\"\\s*:\\s*\"(?<n>[^\"]*(?:Tctl|Tdie|Package)[^\"]*)\"[^{}]*?\"Value\"\\s*:\\s*\"(?<v>[0-9]+(?:[.,][0-9]+)?)\\s*(?:°|\\\\u00[Bb]0)C\"")) {   // градус бывает записан как °
                    float v;
                    if (float.TryParse(m.Groups["v"].Value.Replace(',', '.'), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out v)) best = Math.Max(best, v);
                }
                return best;
            }
            if (src == "acpi") {
                float max = -1;
                using (System.Management.ManagementObjectSearcher q = new System.Management.ManagementObjectSearcher(@"root\wmi", "SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature"))
                    foreach (System.Management.ManagementObject o in q.Get()) max = Math.Max(max, Convert.ToSingle(o["CurrentTemperature"]) / 10f - 273.15f);
                return max;
            }
            return -1;
        }
    }
}
