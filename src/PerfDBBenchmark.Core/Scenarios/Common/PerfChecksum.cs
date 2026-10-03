using System;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>Order-insensitive multiset checksum: sum of FNV-1a-64 over canonical rows. Thread-unsafe; one per worker, merged by the engine.</summary>
public sealed class PerfChecksum
{
    private ulong _sum;
    private long _count;

    public long Count => _count;

    public void Add(params object[] parts)
    {
        var h = Fnv1a64(CanonicalRow(parts));
        unchecked { _sum += h; }
        _count++;
    }

    public void Merge(PerfChecksum other)
    {
        if (other == null) return;
        unchecked { _sum += other._sum; }
        _count += other._count;
    }

    /// <summary>"count:16hex".</summary>
    public override string ToString() =>
        _count.ToString(CultureInfo.InvariantCulture) + ":" + _sum.ToString("x16", CultureInfo.InvariantCulture);

    public static string CanonicalRow(object[] parts)
    {
        if (parts == null || parts.Length == 0) return string.Empty;
        var sb = new StringBuilder();
        for (var i = 0; i < parts.Length; i++)
        {
            if (i > 0) sb.Append('|');
            sb.Append(Canonical(parts[i]));
        }
        return sb.ToString();
    }

    /// <summary>Normalization shared by every checksum, invariant and parity value (SPEC §1.5).</summary>
    public static string Canonical(object value)
    {
        switch (value)
        {
            case null: return "\0";
            case string s: return s.TrimEnd();
            case decimal d: return decimal.Round(d, 4, MidpointRounding.AwayFromZero).ToString("0.####", CultureInfo.InvariantCulture);
            case double x: return Math.Round(x, 4, MidpointRounding.AwayFromZero).ToString("0.####", CultureInfo.InvariantCulture);
            case float f: return Math.Round((double)f, 4, MidpointRounding.AwayFromZero).ToString("0.####", CultureInfo.InvariantCulture);
            case DateTime dt: return dt.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture);
            case Guid g: return g.ToString("D");
            case bool b: return b ? "1" : "0";
            case IFormattable fmt: return fmt.ToString(null, CultureInfo.InvariantCulture);
            default: return value.ToString();
        }
    }

    internal static ulong Fnv1a64(string s)
    {
        unchecked
        {
            var h = 14695981039346656037UL;
            foreach (var c in s)
            {
                h ^= c;
                h *= 1099511628211UL;
            }
            return h;
        }
    }
}

/// <summary>Order-sensitive checksum: SHA-256 over canonical rows joined by '\n'.
/// Use only when Users == 1 and the ORDER BY ends in a unique, collation-safe key.</summary>
public sealed class PerfOrderedChecksum
{
    private readonly StringBuilder _text = new StringBuilder();
    private long _count;

    public long Count => _count;

    public void Add(params object[] parts)
    {
        _text.Append(PerfChecksum.CanonicalRow(parts)).Append('\n');
        _count++;
    }

    /// <summary>Appends another ordered checksum's rows after this one's (the engine folds measured passes in pass order; SPEC §1.3.7).</summary>
    public void Append(PerfOrderedChecksum other)
    {
        if (other == null || ReferenceEquals(other, this)) return;
        _text.Append(other._text);
        _count += other._count;
    }

    /// <summary>"count:16hex".</summary>
    public override string ToString() =>
        _count.ToString(CultureInfo.InvariantCulture) + ":" + PerfStatistics.Sha256Hex(_text.ToString(), 16);
}
