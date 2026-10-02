// Token statistics for the usage widget, read from the Claude Code transcripts on this PC
// (~/.claude/projects/**/*.jsonl). Scans on a background thread, only reads what was
// appended since the last scan, keeps the last 7 days and publishes a ready-made snapshot.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

public class TokRow { public string Name; public long Tokens; public double Cost; }

public class TokSnap {
    // today
    public long In, Out, CacheRead, CacheWrite;
    public int Messages;
    public double Cost;
    public TokRow[] Models = new TokRow[0];
    public TokRow[] Sessions = new TokRow[0];
    public long SubTokens, MainTokens;
    public double SubCost, MainCost;
    // last 7 days, oldest first, today last
    public TokRow[] Days = new TokRow[0];
    // since the weekly limit window opened
    public long WeekTokens; public double WeekCost;
    // last 60 minutes
    public long HourTokens; public double HourCost;
}

public static class TokenScan {
    class Rec {
        public DateTime T; public string Model, Session; public bool Sub;
        public long In, Out, Cw, Cr; public double Cost;
    }

    const int Chunk = 16 * 1024 * 1024;
    static readonly Dictionary<string, long> offsets = new Dictionary<string, long>();
    static readonly Dictionary<string, Rec> msgs = new Dictionary<string, Rec>();
    static readonly Dictionary<string, string> titles = new Dictionary<string, string>();
    static readonly Regex msgRx = new Regex("\"model\":\"([^\"]*)\",\"id\":\"(msg_[^\"]+)\"");
    static readonly Regex idRx = new Regex("\"id\":\"(msg_[^\"]+)\"");
    static readonly Regex tsRx = new Regex("\"timestamp\":\"([^\"]+)\"", RegexOptions.RightToLeft);
    static readonly Regex titleRx = new Regex("\"aiTitle\":\"((?:[^\"\\\\]|\\\\.)*)\",\"sessionId\":\"([^\"]+)\"");
    static int busy;

    public static DateTime WeekStart = DateTime.MinValue;   // local time, set by the widget
    public static volatile TokSnap Snap;

    public static void Start(string root) {
        if (Interlocked.CompareExchange(ref busy, 1, 0) != 0) return;
        ThreadPool.QueueUserWorkItem(delegate {
            try { Scan(root); } catch { } finally { busy = 0; }
        });
    }

    // USD per million tokens: input, output, cache read. Cache writes are billed at
    // 1.25x input (5-minute cache) or 2x input (1-hour cache).
    static double[] Price(string m) {
        if (m.Contains("fable") || m.Contains("mythos")) return new double[] { 10, 50, 0.25 };
        if (m.Contains("opus-5-5")) return new double[] { 4, 20, 0.20 };
        if (m.Contains("opus")) return new double[] { 5, 25, 0.50 };
        if (m.Contains("sonnet-5") || m == "sonnet") return new double[] { 2, 10, 0.20 };
        if (m.Contains("sonnet")) return new double[] { 3, 15, 0.30 };
        if (m.Contains("haiku")) return new double[] { 1, 5, 0.10 };
        return new double[] { 4, 20, 0.20 };
    }

    static long Num(string s, int from, string key) {
        int i = s.IndexOf(key, from, StringComparison.Ordinal);
        if (i < 0) return 0;
        i += key.Length;
        long n = 0;
        while (i < s.Length && s[i] >= '0' && s[i] <= '9') { n = n * 10 + (s[i] - '0'); i++; }
        return n;
    }

    static void Line(string line, string session, bool subFile, DateTime cut) {
        if (line.StartsWith("{\"type\":\"ai-title\"", StringComparison.Ordinal)) {
            Match tm = titleRx.Match(line);
            if (tm.Success) {
                string title = tm.Groups[1].Value;
                try { title = Regex.Unescape(title); } catch { }
                titles[tm.Groups[2].Value] = title;
            }
            return;
        }
        int u = line.IndexOf("\"usage\":{", StringComparison.Ordinal);
        if (u < 0) return;
        string model = "unknown", id;
        Match m = msgRx.Match(line);
        if (m.Success) { model = m.Groups[1].Value; id = m.Groups[2].Value; }
        else { m = idRx.Match(line); if (!m.Success) return; id = m.Groups[1].Value; }
        if (model.StartsWith("<")) return;                    // synthetic entries, no real request
        Match ts = tsRx.Match(line);
        DateTime t;
        if (!ts.Success || !DateTime.TryParse(ts.Groups[1].Value, null, System.Globalization.DateTimeStyles.RoundtripKind, out t)) return;
        t = t.ToLocalTime();
        if (t < cut) return;
        Rec r = new Rec();
        r.T = t; r.Model = model; r.Session = session;
        r.Sub = subFile || line.IndexOf("\"isSidechain\":true", StringComparison.Ordinal) >= 0;
        r.In = Num(line, u, "\"input_tokens\":");
        r.Out = Num(line, u, "\"output_tokens\":");
        r.Cw = Num(line, u, "\"cache_creation_input_tokens\":");
        r.Cr = Num(line, u, "\"cache_read_input_tokens\":");
        long w1 = Num(line, u, "\"ephemeral_1h_input_tokens\":");
        long w5 = Num(line, u, "\"ephemeral_5m_input_tokens\":");
        if (w1 + w5 == 0) w5 = r.Cw;
        double[] p = Price(model);
        r.Cost = (r.In * p[0] + r.Out * p[1] + r.Cr * p[2] + w5 * p[0] * 1.25 + w1 * p[0] * 2) / 1e6;
        msgs[id] = r;      // the same message is logged once per content block - keep one entry per id
    }

    static void Scan(string root) {
        DateTime today = DateTime.Today;
        DateTime cut = today.AddDays(-7);
        if (Directory.Exists(root)) {
            foreach (string f in Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories)) {
                try {
                    FileInfo fi = new FileInfo(f);
                    if (fi.LastWriteTime < cut) continue;
                    long off; offsets.TryGetValue(f, out off);
                    if (fi.Length < off) off = 0;
                    if (fi.Length == off) continue;
                    // subagent transcripts live in <session id>/subagents/ and count towards that session
                    string dir = Path.GetDirectoryName(f);
                    bool subFile = string.Equals(Path.GetFileName(dir), "subagents", StringComparison.OrdinalIgnoreCase);
                    string session = subFile ? Path.GetFileName(Path.GetDirectoryName(dir)) : Path.GetFileNameWithoutExtension(f);
                    using (FileStream fs = new FileStream(f, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete)) {
                        fs.Seek(off, SeekOrigin.Begin);
                        byte[] buf = new byte[(int)Math.Min(Chunk, fi.Length - off + 1)];
                        int have = 0;
                        while (true) {
                            int r = fs.Read(buf, have, buf.Length - have);
                            if (r <= 0) break;
                            have += r;
                            int end = Array.LastIndexOf(buf, (byte)'\n', have - 1, have);
                            if (end < 0) {                       // one line longer than the buffer
                                if (have == buf.Length) Array.Resize(ref buf, buf.Length * 2);
                                continue;
                            }
                            foreach (string line in Encoding.UTF8.GetString(buf, 0, end).Split('\n')) Line(line, session, subFile, cut);
                            off += end + 1;
                            int rest = have - end - 1;
                            Buffer.BlockCopy(buf, end + 1, buf, 0, rest);
                            have = rest;
                            if (have == buf.Length) Array.Resize(ref buf, buf.Length * 2);
                        }
                    }
                    offsets[f] = off;
                } catch { }
            }
        }
        Publish(today, cut);
    }

    static TokRow Bump(Dictionary<string, TokRow> d, string key) {
        TokRow row;
        if (!d.TryGetValue(key, out row)) { row = new TokRow(); row.Name = key; d[key] = row; }
        return row;
    }

    static TokRow[] Sorted(Dictionary<string, TokRow> d) {
        List<TokRow> l = new List<TokRow>(d.Values);
        l.Sort(delegate(TokRow a, TokRow b) { return b.Cost.CompareTo(a.Cost); });
        return l.ToArray();
    }

    static void Publish(DateTime today, DateTime cut) {
        TokSnap s = new TokSnap();
        DateTime hourAgo = DateTime.Now.AddHours(-1);
        DateTime first = today.AddDays(-6);
        s.Days = new TokRow[7];
        for (int i = 0; i < 7; i++) {
            s.Days[i] = new TokRow();
            s.Days[i].Name = first.AddDays(i).ToString("ddd d MMM", System.Globalization.CultureInfo.InvariantCulture);
        }
        Dictionary<string, TokRow> models = new Dictionary<string, TokRow>();
        Dictionary<string, TokRow> sessions = new Dictionary<string, TokRow>();
        List<string> old = new List<string>();
        foreach (KeyValuePair<string, Rec> kv in msgs) {
            Rec r = kv.Value;
            if (r.T < cut) { old.Add(kv.Key); continue; }
            long tok = r.In + r.Out;
            int di = (r.T.Date - first).Days;
            if (di >= 0 && di < 7) { s.Days[di].Tokens += tok; s.Days[di].Cost += r.Cost; }
            if (r.T >= WeekStart) { s.WeekTokens += tok; s.WeekCost += r.Cost; }
            if (r.T >= hourAgo) { s.HourTokens += tok; s.HourCost += r.Cost; }
            if (r.T < today) continue;
            s.In += r.In; s.Out += r.Out; s.CacheRead += r.Cr; s.CacheWrite += r.Cw; s.Cost += r.Cost; s.Messages++;
            if (r.Sub) { s.SubTokens += tok; s.SubCost += r.Cost; } else { s.MainTokens += tok; s.MainCost += r.Cost; }
            TokRow a = Bump(models, r.Model); a.Tokens += tok; a.Cost += r.Cost;
            TokRow b = Bump(sessions, r.Session); b.Tokens += tok; b.Cost += r.Cost;
        }
        foreach (string k in old) msgs.Remove(k);
        s.Models = Sorted(models);
        s.Sessions = Sorted(sessions);
        foreach (TokRow row in s.Sessions) {
            string title;
            row.Name = titles.TryGetValue(row.Name, out title) ? title : "Untitled " + row.Name.Substring(0, Math.Min(8, row.Name.Length));
        }
        Snap = s;
    }
}
