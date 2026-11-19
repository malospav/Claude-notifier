// claude-notifier: тихие звуки главного маскота — синтезируются в памяти (WAV 22 кГц, моно), без файлов.
//   purr — «мрр», когда гладят; boop — тык; boing — «ой», когда подкинули; grr — обиделся; yawn — проснулся и зевает.
// Высота у каждого маскота своя (динозаврик ниже, пчёлка выше). Молчат при «Без звука», в тихие часы
// (Muted ставит шторка из SetLimits) и при выключенной настройке «Звуки маскота» (Enabled).
using System;
using System.Collections.Generic;
using System.IO;
using System.Media;

namespace ClaudeNotifier.Ui {
    public static class MascotSound {
        public static volatile bool Enabled = true;
        public static volatile bool Muted;
        public static string LastPlayed;               // для тестов: последний звук ("purr:bee")
        public static int Played;
        public static bool Silent;                     // тесты: считать, но не играть
        const int Rate = 22050;
        static readonly Dictionary<string, byte[]> cache = new Dictionary<string, byte[]>();
        static readonly Dictionary<string, DateTime> lastAt = new Dictionary<string, DateTime>();
        static SoundPlayer player;
        static MemoryStream playing;

        public static float Pitch(string kind) {
            switch (kind) {
                case "dino": return 0.72f;
                case "reaper": return 0.8f;
                case "boxcat": case "cupcat": return 0.95f;
                case "penguin": case "frog": return 1.1f;
                case "kitty": case "mochi": case "onigiri": return 1.18f;
                case "fox": case "ghost": return 1.08f;
                case "bee": return 1.45f;
                case "leaf": return 0.9f;
                default: return 1f;
            }
        }

        public static void Reset() { lock (cache) lastAt.Clear(); LastPlayed = null; Played = 0; }

        // Сыграть, если можно; один и тот же звук — не чаще раза в 0,6 с (мурчание — 2,5 с). true — играет.
        public static bool Play(string name, string kind) {
            if (!Enabled || Muted || string.IsNullOrEmpty(name)) return false;
            DateTime now = DateTime.UtcNow, prev;
            double gap = name == "purr" ? 2.5 : 0.6;
            lock (cache) {
                if (lastAt.TryGetValue(name, out prev) && (now - prev).TotalSeconds < gap) return false;
                lastAt[name] = now;
            }
            LastPlayed = name + ":" + (kind ?? "");
            Played++;
            if (Silent) return true;
            try {
                byte[] wav = Wave(name, Pitch(kind));
                MemoryStream ms = new MemoryStream(wav, false);
                SoundPlayer p = new SoundPlayer(ms);
                p.Load();
                p.Play();   // асинхронно; новый звук прерывает прежний
                SoundPlayer old = player; MemoryStream oldMs = playing;
                player = p; playing = ms;
                if (old != null) try { old.Dispose(); } catch { }
                if (oldMs != null) try { oldMs.Dispose(); } catch { }
                return true;
            } catch { return false; }
        }

        public static byte[] Wave(string name, float pitch) {
            string key = name + "|" + pitch.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);
            byte[] b;
            lock (cache) { if (cache.TryGetValue(key, out b)) return b; }
            b = ToWav(Synth(name, pitch));
            lock (cache) cache[key] = b;
            return b;
        }

        static float[] Synth(string name, float p) {
            Random rnd = new Random(name.Length * 7919 + (int)(p * 100));
            double dur = name == "purr" ? 0.85 : name == "yawn" ? 0.9 : name == "boing" ? 0.38 : name == "grr" ? 0.35 : 0.12;
            int n = (int)(dur * Rate);
            float[] s = new float[n];
            double ph = 0, ph2 = 0, lp = 0;
            for (int i = 0; i < n; i++) {
                double t = (double)i / Rate, k = t / dur;
                double env = Math.Min(1, t / 0.015) * Math.Min(1, (dur - t) / 0.04);   // мягкие края без щелчков
                double v = 0, f;
                double noise = rnd.NextDouble() * 2 - 1;
                lp += (noise - lp) * 0.08;                                              // приглушённый шум
                switch (name) {
                    case "purr":
                        f = 70 * p;
                        ph += 2 * Math.PI * f / Rate;
                        double pulse = Math.Pow(Math.Max(0, Math.Sin(2 * Math.PI * 24 * t)), 3);   // 24 удара в секунду
                        v = (0.6 * Math.Sin(ph) + 0.4 * Math.Sin(ph * 2) + 1.2 * lp) * pulse * 0.35 * Math.Sin(Math.PI * k);
                        break;
                    case "boop":
                        f = 660 * p * (1 - 0.25 * k);
                        ph += 2 * Math.PI * f / Rate;
                        v = Math.Sin(ph) * Math.Exp(-k * 4) * 0.3;
                        break;
                    case "boing":
                        f = p * (k < 0.3 ? 320 + 600 * k / 0.3 : 920 - 640 * (k - 0.3) / 0.7) * (1 + 0.04 * Math.Sin(2 * Math.PI * 28 * t));
                        ph += 2 * Math.PI * f / Rate;
                        v = Math.Sin(ph) * (1 - k * 0.7) * 0.28;
                        break;
                    case "grr":
                        f = 105 * p;
                        ph += 2 * Math.PI * f / Rate;
                        double saw = (ph / Math.PI % 2) - 1;
                        v = (0.6 * saw + 0.5 * lp) * (0.6 + 0.4 * Math.Sin(2 * Math.PI * 17 * t)) * 0.22;
                        break;
                    case "yawn":
                        f = p * (k < 0.25 ? 380 + 160 * k / 0.25 : 540 - 300 * (k - 0.25) / 0.75);
                        ph += 2 * Math.PI * f / Rate;
                        ph2 += 2 * Math.PI * f * 2.01 / Rate;
                        v = (0.7 * Math.Sin(ph) + 0.2 * Math.Sin(ph2) + 0.8 * lp) * Math.Sin(Math.PI * k) * 0.22;
                        break;
                }
                s[i] = (float)(v * env);
            }
            return s;
        }

        // Набор «Маскот» для уведомлений: колокольчики (основной тон + неровные обертоны с затуханием).
        // done — две ноты вверх; permission — три ноты, зовёт; error — две вниз, минор; limit — низкий двойной.
        public static byte[] EventWave(string type) {
            double[][] notes;   // { частота, начало (с), длительность (с) }
            switch (type) {
                case "permission": notes = new double[][] { new double[] { 784, 0, 0.5 }, new double[] { 988, 0.12, 0.5 }, new double[] { 1175, 0.24, 0.7 } }; break;
                case "error": notes = new double[][] { new double[] { 659, 0, 0.5 }, new double[] { 523, 0.16, 0.8 } }; break;
                case "limit": notes = new double[][] { new double[] { 392, 0, 0.35 }, new double[] { 392, 0.22, 0.5 } }; break;
                default: notes = new double[][] { new double[] { 1047, 0, 0.6 }, new double[] { 1568, 0.13, 0.9 } }; break;
            }
            double total = 0;
            foreach (double[] nn in notes) total = Math.Max(total, nn[1] + nn[2]);
            int n = (int)((total + 0.05) * Rate);
            float[] s = new float[n];
            foreach (double[] nn in notes) {
                int start = (int)(nn[1] * Rate), len = (int)(nn[2] * Rate);
                for (int i = 0; i < len && start + i < n; i++) {
                    double t = (double)i / Rate;
                    double env = Math.Min(1, t / 0.004) * Math.Exp(-t * 6.5);
                    double v = Math.Sin(2 * Math.PI * nn[0] * t) + 0.35 * Math.Sin(2 * Math.PI * nn[0] * 2.76 * t) * Math.Exp(-t * 9) + 0.15 * Math.Sin(2 * Math.PI * nn[0] * 5.4 * t) * Math.Exp(-t * 14);
                    s[start + i] += (float)(v * env * 0.22);
                }
            }
            return ToWav(s);
        }

        static byte[] ToWav(float[] s) {
            using (MemoryStream ms = new MemoryStream())
            using (BinaryWriter w = new BinaryWriter(ms)) {
                int data = s.Length * 2;
                w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write(36 + data);
                w.Write(new char[] { 'W', 'A', 'V', 'E' });
                w.Write(new char[] { 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1);
                w.Write(Rate); w.Write(Rate * 2); w.Write((short)2); w.Write((short)16);
                w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write(data);
                foreach (float v in s) w.Write((short)Math.Max(-32767, Math.Min(32767, (int)(v * 32767))));
                w.Flush();
                return ms.ToArray();
            }
        }
    }
}
