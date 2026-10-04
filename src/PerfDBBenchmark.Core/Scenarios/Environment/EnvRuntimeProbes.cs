using System;
using System.Collections.Generic;
using System.Configuration;
using System.Diagnostics;
using System.Globalization;
using System.Reflection;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios.Environment;

/// <summary>
/// ENV_CAPTURE runtime proofs (cross-owner contract C1): env.app.sqlThrottling and env.app.processAffinity.
/// Called only from <see cref="EnvCaptureCollector"/> (ENV_CAPTURE Prepare, untimed), so nothing here runs during a measured
/// pass. Everything is best effort and never throws: a value that cannot be read is null and the reason is in "error".
/// </summary>
internal static class EnvRuntimeProbes
{
    /// <summary>
    /// The web.config appSettings key that Set-PerfEnvironment writes (decision E14). Acumatica's CompositionRoot copies the
    /// appSettings into IConfiguration ("sqlThrottling:Enabled" is the path Enabled of section "sqlThrottling"), and
    /// PX.Data ServiceRegistration binds that section to SqlThrottlingOptions (BindFromConfiguration, ~line 254).
    /// </summary>
    internal const string SqlThrottlingConfigKey = "sqlThrottling:Enabled";

    private const string OptionsTypeName = "PX.Data.Database.Throttling.SqlThrottlingOptions";
    private const string ThrottlingInterfaceName = "PX.Data.Database.Throttling.IPXSqlThrottling";
    private const string LeakyBucketTypeName = "PX.Data.Database.Throttling.LeakyBucketSqlThrottling";
    private const string IOptionsOpenTypeName = "Microsoft.Extensions.Options.IOptions`1";
    private const BindingFlags InstanceDeclared = BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.DeclaredOnly;
    private const BindingFlags StaticAny = BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic;
    private const int MaxTextLength = 600;

    /// <summary>
    /// env.app.sqlThrottling = { configValue, optionsEnabled, started, source, error }.
    /// <list type="bullet">
    /// <item>configValue: ConfigurationManager.AppSettings["sqlThrottling:Enabled"], raw text, null when the key is absent.</item>
    /// <item>optionsEnabled: SqlThrottlingOptions.Enabled in effect in this app domain, read two ways: (1) IOptions&lt;SqlThrottlingOptions&gt;.Value
    /// resolved from Acumatica's CommonServiceLocator (the singleton the DI container hands out), and (2) the _options field of the
    /// IPXSqlThrottling singleton the data layer calls (PXDatabaseProvider.SqlThrottling, LeakyBucketSqlThrottling); CheckThrottling
    /// tests exactly that field. One successful reading is enough; if both succeed and disagree the value is null (no proof).</item>
    /// <item>started: LeakyBucketSqlThrottling._started (true only after StartupDelay when Enabled and the site is not on-premises).</item>
    /// <item>source: which readings succeeded (a failed secondary reading is noted here, not in error).</item>
    /// <item>error: null whenever optionsEnabled was established; otherwise every failure. So error != null exactly when
    /// optionsEnabled is null, and a reader can treat "optionsEnabled === false" alone as the proof.</item>
    /// </list>
    /// </summary>
    public static Dictionary<string, object> SqlThrottling()
    {
        var result = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["configValue"] = null,
            ["optionsEnabled"] = null,
            ["started"] = null,
            ["source"] = null,
            ["error"] = null
        };
        var failures = new List<string>();
        var sources = new List<string>();
        bool? fromOptions = null;
        bool? fromThrottler = null;

        try
        {
            try
            {
                result["configValue"] = ConfigurationManager.AppSettings[SqlThrottlingConfigKey];
            }
            catch (Exception ex)
            {
                failures.Add("configValue: " + Describe(ex));
            }

            var pxData = typeof(PXGraph).Assembly;
            var optionsType = pxData.GetType(OptionsTypeName, throwOnError: false);

            // (1) the bound options as the DI container hands them out
            try
            {
                fromOptions = ReadEnabledFromIOptions(pxData, optionsType);
                sources.Add("IOptions<SqlThrottlingOptions>.Value via ServiceLocator");
            }
            catch (Exception ex)
            {
                failures.Add("IOptions<SqlThrottlingOptions>: " + Describe(ex));
            }

            // (2) the singleton the data layer calls on every record read (PXDataRecord -> provider.SqlThrottling.CheckThrottling)
            try
            {
                var throttler = ResolveThrottler(pxData, out var throttlerSource);
                var typeName = throttler.GetType().FullName;
                var label = string.Equals(typeName, LeakyBucketTypeName, StringComparison.Ordinal) ? "LeakyBucketSqlThrottling" : typeName;
                try
                {
                    fromThrottler = ReadEnabled(ReadField(throttler, "_options"));
                    sources.Add(label + "._options via " + throttlerSource);
                }
                catch (Exception ex)
                {
                    failures.Add(label + "._options: " + Describe(ex));
                }

                try
                {
                    if (ReadField(throttler, "_started") is bool started) result["started"] = started;
                    else failures.Add(label + "._started: not a bool");
                }
                catch (Exception ex)
                {
                    failures.Add(label + "._started: " + Describe(ex));
                }
            }
            catch (Exception ex)
            {
                failures.Add("IPXSqlThrottling: " + Describe(ex));
            }

            if (fromOptions.HasValue && fromThrottler.HasValue && fromOptions.Value != fromThrottler.Value)
            {
                failures.Insert(0, "the readings disagree: IOptions<SqlThrottlingOptions>.Value.Enabled=" + Bool(fromOptions.Value)
                                   + ", LeakyBucketSqlThrottling._options.Enabled=" + Bool(fromThrottler.Value));
            }
            else
            {
                var enabled = fromOptions ?? fromThrottler;
                if (enabled.HasValue) result["optionsEnabled"] = enabled.Value;
            }
        }
        catch (Exception ex)
        {
            failures.Add(Describe(ex));
        }

        var source = sources.Count > 0 ? string.Join("; ", sources) : "none";
        if (result["optionsEnabled"] == null)
        {
            result["error"] = Cut(failures.Count > 0 ? string.Join(" | ", failures) : "SqlThrottlingOptions.Enabled could not be read");
        }
        else if (failures.Count > 0)
        {
            source += " (partial: " + string.Join(" | ", failures) + ")";
        }

        result["source"] = Cut(source);
        return result;
    }

    /// <summary>
    /// env.app.processAffinity = { maskHex, bits, processorCount, error } (informational; kept as shipped, disclosed only).
    /// A snapshot of this w3wp's affinity at capture time, never the core count of a run: on an unlicensed site Acumatica changes
    /// the mask on its own, and a snapshot can legitimately show any of these shapes (decompiled 26 R2):
    /// <list type="bullet">
    /// <item>2 bits, the steady state: ResourceGovernor SetProcessAffinity (ResourceConfig.SetProcessAffinity="True" in
    /// Bin\PX.ResourceGovernor.config) pins the process to RuntimeInfo.GetLicenseProcessors() = 2 cores when unlicensed, drawn at
    /// random every 60 s and kept exclusive of the cores other Acumatica w3wp processes hold (acumatica_core_* named mutexes).</item>
    /// <item>4 bits for up to 60 s: LicenseObserverService.CheckLicense:164 calls SetAffinity(ProcessorsAllowed = 4 when unlicensed)
    /// 100-500 s after start and then every 5-30 min; the next ResourceGovernor tick narrows it back to 2.</item>
    /// <item>every CPU (0xFFFFFF, 24 bits on this PC) during the first 2 minutes of a new w3wp process, before the first
    /// ResourceGovernor tick (ResourceGovernorModule.cs:67: due time 2 min, period 1 min); also briefly while a full GC runs
    /// (CheckFullGCEvents and RunGCToReduceMemory.AllProcessors, both True: GCMonitor restores the original mask for the GC).
    /// After an AppDomain restart inside the same w3wp (web.config or Bin change) the old mask stays until that first tick.</item>
    /// </list>
    /// Read it together with env.app.appDomainStartUtc and env.capturedAtUtc: appDomainStartUtc is taken when this DLL is first
    /// used, after ResourceGovernor started, so capturedAtUtc - appDomainStartUtc &gt;= 2 min means the first ResourceGovernor tick
    /// has been due; a shorter gap leaves the all-CPU window possible. processorCount is Environment.ProcessorCount (logical
    /// processors of the machine on .NET Framework, not affinity-limited).
    /// </summary>
    public static Dictionary<string, object> ProcessAffinity()
    {
        var result = new Dictionary<string, object>(StringComparer.Ordinal)
        {
            ["maskHex"] = null,
            ["bits"] = null,
            ["processorCount"] = null,
            ["error"] = null
        };
        var failures = new List<string>();
        var processorCount = 0;

        try
        {
            processorCount = System.Environment.ProcessorCount;
            result["processorCount"] = processorCount;
        }
        catch (Exception ex)
        {
            failures.Add("processorCount: " + Describe(ex));
        }

        try
        {
            using (var process = Process.GetCurrentProcess())
            {
                var mask = unchecked((ulong)process.ProcessorAffinity.ToInt64());
                var bits = 0;
                for (var m = mask; m != 0; m &= m - 1) bits++;
                var digits = Math.Max(1, (Math.Max(processorCount, 1) + 3) / 4);
                result["maskHex"] = "0x" + mask.ToString("X" + digits.ToString(CultureInfo.InvariantCulture), CultureInfo.InvariantCulture);
                result["bits"] = bits;
            }
        }
        catch (Exception ex)
        {
            failures.Add("ProcessorAffinity: " + Describe(ex));
        }

        if (failures.Count > 0) result["error"] = Cut(string.Join(" | ", failures));
        return result;
    }

    // ------------------------------------------------------------------ helpers

    private static bool ReadEnabledFromIOptions(Assembly pxData, Type optionsType)
    {
        if (optionsType == null) throw new InvalidOperationException(OptionsTypeName + " was not found in PX.Data.");
        var closed = FindIOptionsOpenType(pxData).MakeGenericType(optionsType);
        var instance = Resolve(CurrentServiceLocator(), closed);
        if (instance == null) throw new InvalidOperationException("the service locator returned null.");
        var valueProperty = closed.GetProperty("Value", BindingFlags.Instance | BindingFlags.Public)
                            ?? throw new MissingMemberException(closed.FullName, "Value");
        return ReadEnabled(valueProperty.GetValue(instance, null));
    }

    /// <summary>IOptions&lt;&gt; as LeakyBucketSqlThrottling's constructor references it (same assembly identity), else by name.</summary>
    private static Type FindIOptionsOpenType(Assembly pxData)
    {
        var leaky = pxData.GetType(LeakyBucketTypeName, throwOnError: false);
        if (leaky != null)
        {
            foreach (var ctor in leaky.GetConstructors(BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic))
            {
                foreach (var p in ctor.GetParameters())
                {
                    var t = p.ParameterType;
                    if (t.IsGenericType && string.Equals(t.GetGenericTypeDefinition().FullName, IOptionsOpenTypeName, StringComparison.Ordinal))
                        return t.GetGenericTypeDefinition();
                }
            }
        }

        return FindLoadedType(IOptionsOpenTypeName, "Microsoft.Extensions.Options")
               ?? throw new InvalidOperationException(IOptionsOpenTypeName + " was not found.");
    }

    /// <summary>CommonServiceLocator.ServiceLocator.Current (set by Acumatica's CompositionRoot to an AutofacServiceLocator).</summary>
    private static object CurrentServiceLocator()
    {
        var locatorType = FindLoadedType("CommonServiceLocator.ServiceLocator", "CommonServiceLocator")
                          ?? FindLoadedType("Microsoft.Practices.ServiceLocation.ServiceLocator", "Microsoft.Practices.ServiceLocation")
                          ?? throw new InvalidOperationException("CommonServiceLocator.ServiceLocator was not found.");
        var isSet = locatorType.GetProperty("IsLocationProviderSet", StaticAny);
        if (isSet != null && isSet.GetValue(null, null) is bool set && !set)
            throw new InvalidOperationException("ServiceLocator.IsLocationProviderSet is false.");
        return locatorType.GetProperty("Current", StaticAny)?.GetValue(null, null)
               ?? throw new InvalidOperationException("ServiceLocator.Current is null.");
    }

    private static object Resolve(object locator, Type serviceType)
    {
        if (locator is IServiceProvider provider) return provider.GetService(serviceType);
        var getInstance = locator.GetType().GetMethod("GetInstance", new[] { typeof(Type) })
                          ?? throw new MissingMethodException(locator.GetType().FullName, "GetInstance(Type)");
        return getInstance.Invoke(locator, new object[] { serviceType });
    }

    /// <summary>The IPXSqlThrottling instance PXDatabaseProvider uses (internal property SqlThrottling), else the DI singleton.</summary>
    private static object ResolveThrottler(Assembly pxData, out string source)
    {
        var provider = PXDatabase.Provider;
        if (provider != null)
        {
            var property = FindProperty(provider.GetType(), "SqlThrottling");
            var instance = property?.GetValue(provider, null);
            if (instance != null)
            {
                source = "PXDatabaseProvider.SqlThrottling";
                return instance;
            }
        }

        var iface = pxData.GetType(ThrottlingInterfaceName, throwOnError: false)
                    ?? throw new InvalidOperationException(ThrottlingInterfaceName + " was not found in PX.Data.");
        var resolved = Resolve(CurrentServiceLocator(), iface)
                       ?? throw new InvalidOperationException("no IPXSqlThrottling instance.");
        source = "IPXSqlThrottling via ServiceLocator";
        return resolved;
    }

    private static bool ReadEnabled(object options)
    {
        if (options == null) throw new InvalidOperationException("the options instance is null.");
        var property = options.GetType().GetProperty("Enabled", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
                       ?? throw new MissingMemberException(options.GetType().FullName, "Enabled");
        var value = property.GetValue(options, null);
        if (value is bool b) return b;
        throw new InvalidCastException("Enabled is " + (value?.GetType().Name ?? "null") + ".");
    }

    private static object ReadField(object instance, string name)
    {
        for (var t = instance.GetType(); t != null; t = t.BaseType)
        {
            var field = t.GetField(name, InstanceDeclared);
            if (field != null) return field.GetValue(instance);
        }

        throw new MissingFieldException(instance.GetType().FullName, name);
    }

    private static PropertyInfo FindProperty(Type type, string name)
    {
        for (var t = type; t != null; t = t.BaseType)
        {
            var property = t.GetProperty(name, InstanceDeclared);
            if (property != null && property.GetIndexParameters().Length == 0) return property;
        }

        return null;
    }

    private static Type FindLoadedType(string fullName, string assemblyName)
    {
        foreach (var assembly in AppDomain.CurrentDomain.GetAssemblies())
        {
            try
            {
                if (!string.Equals(assembly.GetName().Name, assemblyName, StringComparison.OrdinalIgnoreCase)) continue;
                var type = assembly.GetType(fullName, throwOnError: false);
                if (type != null) return type;
            }
            catch
            {
                // a broken or dynamic assembly: skip it
            }
        }

        try { return Type.GetType(fullName + ", " + assemblyName, throwOnError: false); }
        catch { return null; }
    }

    private static string Describe(Exception ex)
    {
        while (ex is TargetInvocationException && ex.InnerException != null) ex = ex.InnerException;
        return ex.GetType().Name + ": " + ex.Message;
    }

    private static string Bool(bool value) => value ? "True" : "False";

    private static string Cut(string value) =>
        value == null || value.Length <= MaxTextLength ? value : value.Substring(0, MaxTextLength) + "...";
}
