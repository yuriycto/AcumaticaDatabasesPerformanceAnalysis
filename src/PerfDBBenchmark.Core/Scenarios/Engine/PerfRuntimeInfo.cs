using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Xml.Linq;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// Deployment and runtime facts of this AppDomain (SPEC §4.7). Every member is cheap after the first call and never throws:
/// failures read as "unavailable". No WMI and no snapshot reads.
/// </summary>
public static class PerfRuntimeInfo
{
    public const string Unavailable = "unavailable";

    /// <summary>Default of ThreadPoolOptions.ThreadPoolSize when web.config does not set it (DEC\arch\ThreadPoolOptions.cs:14).</summary>
    public const int DefaultThreadPoolSize = 15;

    private static readonly string _appDomainStartUtc;
    private static readonly Lazy<string> _dllSha256 = new Lazy<string>(ComputeDllSha256, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<string> _acumaticaBuild = new Lazy<string>(ComputeAcumaticaBuild, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly Lazy<PerfWebConfigFacts> _webConfig = new Lazy<PerfWebConfigFacts>(PerfWebConfigFacts.Read, LazyThreadSafetyMode.ExecutionAndPublication);
    private static readonly object DbmsSync = new object();
    private static string _dbmsVersionLabel;

    static PerfRuntimeInfo()
    {
        // Captured at type initialization: the first access after the AppDomain started (the graph constructor touches it).
        _appDomainStartUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
    }

    /// <summary>ISO "o" UTC time captured when this type was first used in the AppDomain (restart detection).</summary>
    public static string AppDomainStartUtc => _appDomainStartUtc;

    /// <summary>SHA-256 (64 lowercase hex chars) of this assembly's file.</summary>
    public static string DllSha256 => _dllSha256.Value;

    /// <summary>FileVersion of PX.Data.dll.</summary>
    public static string AcumaticaBuild => _acumaticaBuild.Value;

    /// <summary>DBMS version label from PX.DbServices (cached after the first success; "unavailable" on failure).</summary>
    public static string DbmsVersionLabel
    {
        get
        {
            var cached = Volatile.Read(ref _dbmsVersionLabel);
            if (cached != null) return cached;
            lock (DbmsSync)
            {
                if (_dbmsVersionLabel != null) return _dbmsVersionLabel;
                try
                {
                    var label = ReadDbmsVersionLabel();
                    if (string.IsNullOrWhiteSpace(label)) return Unavailable;
                    Volatile.Write(ref _dbmsVersionLabel, label.Trim());
                    return _dbmsVersionLabel;
                }
                catch
                {
                    // Includes type-load failures of PX.DbServices, which surface when ReadDbmsVersionLabel is compiled.
                    return Unavailable;
                }
            }
        }
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static string ReadDbmsVersionLabel()
    {
        var point = ((PXDatabaseProvider)PXDatabase.Provider).CreateDbServicesPoint(null);
        try
        {
            return point.DbmsVersionLabel;
        }
        finally
        {
            (point as IDisposable)?.Dispose();
        }
    }

    /// <summary>&lt;px.core&gt;&lt;ThreadPoolSize&gt; in the site's web.config, default 15.</summary>
    public static int ConfiguredThreadPoolSize => WebConfigFacts.ThreadPoolSize ?? DefaultThreadPoolSize;

    /// <summary>Parsed web.config facts used by ENV_CAPTURE and the pre-checks (cached per AppDomain; a web.config edit restarts it).</summary>
    internal static PerfWebConfigFacts WebConfigFacts => _webConfig.Value;

    /// <summary>Full type name of the database provider ("unavailable" on failure).</summary>
    public static string ProviderTypeName
    {
        get
        {
            try { return PXDatabase.Provider?.GetType().FullName ?? Unavailable; }
            catch { return Unavailable; }
        }
    }

    /// <summary>Site folder name (PerfSQL / PerfMySQL / PerfPG).</summary>
    public static string InstanceName
    {
        get
        {
            try
            {
                var root = AppDomain.CurrentDomain.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
                return new DirectoryInfo(root).Name;
            }
            catch
            {
                return "UnknownInstance";
            }
        }
    }

    private static string ComputeDllSha256()
    {
        try
        {
            var path = typeof(PerfRuntimeInfo).Assembly.Location;
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return Unavailable;
            using var sha = SHA256.Create();
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var hash = sha.ComputeHash(stream);
            var sb = new StringBuilder(hash.Length * 2);
            foreach (var b in hash) sb.Append(b.ToString("x2", CultureInfo.InvariantCulture));
            return sb.ToString();
        }
        catch
        {
            return Unavailable;
        }
    }

    private static string ComputeAcumaticaBuild()
    {
        try
        {
            var path = typeof(PXGraph).Assembly.Location;
            if (string.IsNullOrEmpty(path)) return Unavailable;
            var info = FileVersionInfo.GetVersionInfo(path);
            return string.IsNullOrWhiteSpace(info.FileVersion) ? Unavailable : info.FileVersion.Trim();
        }
        catch
        {
            return Unavailable;
        }
    }
}

/// <summary>
/// The web.config facts listed in SPEC §1.8 (webConfig section), read from AppDomain.CurrentDomain.BaseDirectory\web.config.
/// Connection strings are never read.
/// </summary>
internal sealed class PerfWebConfigFacts
{
    internal static readonly string[] AppSettingKeys =
    {
        "DisableScheduleProcessor",
        "ParallelProcessingDisabled",
        "ParallelProcessingMaxThreads",
        "ParallelProcessingBatchSize",
        "IsParallelProcessingSkipBatchExceptions",
        "EnableAutoNumberingInSeparateConnection",
        "CompilePages",
        "QueryCacheLevel"
    };

    public string Path { get; private set; }
    public string Error { get; private set; }
    public string CompilationDebug { get; private set; }
    public int? ThreadPoolSize { get; private set; }
    public string ThreadPoolSizeSource { get; private set; } = "default";
    public string QueryCacheLevel { get; private set; }
    public Dictionary<string, string> AppSettings { get; } = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    internal static PerfWebConfigFacts Read()
    {
        var facts = new PerfWebConfigFacts();
        try
        {
            facts.Path = System.IO.Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "web.config");
            if (!File.Exists(facts.Path))
            {
                facts.Error = "web.config not found";
                return facts;
            }

            var doc = XDocument.Load(facts.Path);

            foreach (var add in doc.Descendants().Where(e => e.Name.LocalName == "appSettings").Elements().Where(e => e.Name.LocalName == "add"))
            {
                var key = (string)add.Attribute("key");
                if (key == null) continue;
                if (AppSettingKeys.Contains(key, StringComparer.OrdinalIgnoreCase))
                {
                    facts.AppSettings[key] = (string)add.Attribute("value");
                }
            }

            var compilation = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "compilation");
            facts.CompilationDebug = (string)compilation?.Attribute("debug") ?? "(absent)";

            var pxCore = doc.Descendants().FirstOrDefault(e => e.Name.LocalName == "px.core");
            if (pxCore != null)
            {
                var poolElement = pxCore.Elements().FirstOrDefault(e => string.Equals(e.Name.LocalName, "ThreadPoolSize", StringComparison.OrdinalIgnoreCase));
                var poolText = poolElement?.Value;
                if (poolText == null)
                {
                    poolText = (string)pxCore.Attributes().FirstOrDefault(a => string.Equals(a.Name.LocalName, "ThreadPoolSize", StringComparison.OrdinalIgnoreCase));
                }

                if (!string.IsNullOrWhiteSpace(poolText) &&
                    int.TryParse(poolText.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var pool) && pool > 0)
                {
                    facts.ThreadPoolSize = pool;
                    facts.ThreadPoolSizeSource = "web.config";
                }
            }

            // QueryCacheLevel: an appSettings key or an attribute/element anywhere in the file; "(default graph)" when absent.
            if (facts.AppSettings.TryGetValue("QueryCacheLevel", out var qcl) && !string.IsNullOrWhiteSpace(qcl))
            {
                facts.QueryCacheLevel = qcl;
            }
            else
            {
                var attr = doc.Descendants().Attributes().FirstOrDefault(a => string.Equals(a.Name.LocalName, "QueryCacheLevel", StringComparison.OrdinalIgnoreCase));
                var elem = doc.Descendants().FirstOrDefault(e => string.Equals(e.Name.LocalName, "QueryCacheLevel", StringComparison.OrdinalIgnoreCase));
                facts.QueryCacheLevel = attr?.Value ?? elem?.Value ?? "(default graph)";
            }
        }
        catch (Exception ex)
        {
            facts.Error = ex.GetType().Name + ": " + ex.Message;
        }

        return facts;
    }

    /// <summary>The ResultJson env.webConfig section (SPEC §1.8).</summary>
    internal Dictionary<string, object> ToJson()
    {
        var map = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["compilationDebug"] = CompilationDebug ?? PerfRuntimeInfo.Unavailable
        };
        foreach (var key in AppSettingKeys)
        {
            if (key == "QueryCacheLevel") continue;
            map[key] = AppSettings.TryGetValue(key, out var v) ? v : "(absent)";
        }

        map["ThreadPoolSize"] = ThreadPoolSize ?? PerfRuntimeInfo.DefaultThreadPoolSize;
        map["ThreadPoolSizeSource"] = ThreadPoolSizeSource;
        map["QueryCacheLevel"] = QueryCacheLevel ?? "(default graph)";
        if (Error != null) map["error"] = Error;
        return map;
    }
}
