using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.Linq;
using System.Security.Cryptography;
using System.Text;

namespace PerfDBBenchmark.Core.Scenarios;

public static class PerfStatistics
{
    public static double TicksToMs(long ticks) => ticks * 1000.0 / Stopwatch.Frequency;

    /// <summary>Linear interpolation between closest ranks (Excel PERCENTILE.INC). Input must be sorted ascending. p in [0,100].</summary>
    public static double Percentile(IReadOnlyList<double> sortedAscending, double p)
    {
        var n = sortedAscending?.Count ?? 0;
        if (n == 0) return 0;
        if (n == 1) return sortedAscending[0];
        var rank = Math.Max(0, Math.Min(100, p)) / 100.0 * (n - 1);
        var lo = (int)Math.Floor(rank);
        var hi = (int)Math.Ceiling(rank);
        return sortedAscending[lo] + (sortedAscending[hi] - sortedAscending[lo]) * (rank - lo);
    }

    public static double Median(IEnumerable<double> values)
    {
        var a = (values ?? Enumerable.Empty<double>()).OrderBy(x => x).ToArray();
        return Percentile(a, 50);
    }

    /// <summary>Robust CV in percent: 100 * 1.4826 * MAD / median.</summary>
    public static double RobustCvPct(IEnumerable<double> values)
    {
        var a = (values ?? Enumerable.Empty<double>()).ToArray();
        if (a.Length == 0) return 0;
        var med = Median(a);
        if (med == 0) return 0;
        var mad = Median(a.Select(x => Math.Abs(x - med)));
        return 100.0 * 1.4826 * mad / med;
    }

    /// <summary>First 'hexChars' lowercase hex chars of SHA-256(UTF-8(text)).</summary>
    public static string Sha256Hex(string text, int hexChars = 16)
    {
        using var sha = SHA256.Create();
        var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(text ?? string.Empty));
        var sb = new StringBuilder(hash.Length * 2);
        foreach (var b in hash) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
        return sb.ToString(0, Math.Min(hexChars, sb.Length));
    }
}

/// <summary>Deterministic, engine-independent selection helpers (never use Random or DB order for sampling).</summary>
public static class PerfDeterministic
{
    /// <summary>Contiguous block assignment used by the engine when PerfRunPlan.AssignWorker is null:
    /// worker w gets ops [floor(w*n/W), floor((w+1)*n/W)).</summary>
    public static int ContiguousWorker(int opIndex, int opsPerPass, int users)
    {
        if (users <= 1 || opsPerPass <= 0) return 0;
        return (int)Math.Min(users - 1, (long)opIndex * users / opsPerPass);
    }

    /// <summary>Every k-th element of an ordinally sorted list: indexes 0, step, 2*step … (count items).</summary>
    public static IReadOnlyList<T> EveryKth<T>(IReadOnlyList<T> sorted, int step, int count)
    {
        if (sorted == null) throw new ArgumentNullException(nameof(sorted));
        if (step < 1) throw new ArgumentOutOfRangeException(nameof(step));
        var result = new List<T>(count);
        for (var i = 0; i < sorted.Count && result.Count < count; i += step) result.Add(sorted[i]);
        return result;
    }

    /// <summary>Hash over (ID, TrimEnd(CD)) pairs sorted ordinally by CD then ID: "count:16hex" (master-data fingerprint).</summary>
    public static string PairsFingerprint(IEnumerable<KeyValuePair<int, string>> idCdPairs)
    {
        var rows = (idCdPairs ?? Enumerable.Empty<KeyValuePair<int, string>>())
            .Select(p => new KeyValuePair<int, string>(p.Key, (p.Value ?? string.Empty).TrimEnd()))
            .OrderBy(p => p.Value, StringComparer.Ordinal)
            .ThenBy(p => p.Key)
            .ToList();
        var oc = new PerfOrderedChecksum();
        foreach (var r in rows) oc.Add(r.Key, r.Value);
        return oc.ToString();
    }
}

/// <summary>Canonical JSON for ParamsJson (sorted keys, invariant culture, no whitespace) and ParamsHash.</summary>
public static class PerfJson
{
    public static string Canonical(IDictionary<string, object> values)
    {
        var sb = new StringBuilder();
        WriteValue(sb, values);
        return sb.ToString();
    }

    /// <summary>First 16 hex chars of SHA-256(UTF-8(Canonical(values))).</summary>
    public static string Hash(IDictionary<string, object> values) => PerfStatistics.Sha256Hex(Canonical(values), 16);

    private static void WriteValue(StringBuilder sb, object v)
    {
        switch (v)
        {
            case null: sb.Append("null"); return;
            case string s: WriteString(sb, s); return;
            case bool b: sb.Append(b ? "true" : "false"); return;
            case decimal d: sb.Append(PerfChecksum.Canonical(d)); return;
            case double x: sb.Append(PerfChecksum.Canonical(x)); return;
            case float f: sb.Append(PerfChecksum.Canonical(f)); return;
            case DateTime dt: WriteString(sb, PerfChecksum.Canonical(dt)); return;
            case Guid g: WriteString(sb, g.ToString("D")); return;
            case IDictionary<string, object> map:
                sb.Append('{');
                var first = true;
                foreach (var kv in map.OrderBy(k => k.Key, StringComparer.Ordinal))
                {
                    if (!first) sb.Append(',');
                    first = false;
                    WriteString(sb, kv.Key);
                    sb.Append(':');
                    WriteValue(sb, kv.Value);
                }
                sb.Append('}');
                return;
            case IEnumerable seq:
                sb.Append('[');
                var firstItem = true;
                foreach (var item in seq)
                {
                    if (!firstItem) sb.Append(',');
                    firstItem = false;
                    WriteValue(sb, item);
                }
                sb.Append(']');
                return;
            case IFormattable fmt: sb.Append(fmt.ToString(null, CultureInfo.InvariantCulture)); return;
            default: WriteString(sb, v.ToString()); return;
        }
    }

    private static void WriteString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var c in s)
        {
            switch (c)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (c < 0x20) sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(c);
                    break;
            }
        }
        sb.Append('"');
    }
}
