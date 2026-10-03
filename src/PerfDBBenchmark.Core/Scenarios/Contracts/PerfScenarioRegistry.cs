using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Threading;
using PX.Data;

namespace PerfDBBenchmark.Core.Scenarios;

/// <summary>
/// The single server-side test catalog. Discovers every IPerfScenarioFactory, IPerfFingerprintContributor and IPerfLeftoverCleaner
/// in this assembly by reflection, so adding a family never edits a shared switch. Tolerates zero factories.
/// Never throws while loading: a failing type, an invalid descriptor or a duplicate code is skipped and listed in LoadErrors.
/// </summary>
public static class PerfScenarioRegistry
{
    private sealed class RegistryState
    {
        public List<PerfTestDescriptor> Descriptors = new List<PerfTestDescriptor>();
        public Dictionary<string, PerfTestDescriptor> ByCode = new Dictionary<string, PerfTestDescriptor>(StringComparer.OrdinalIgnoreCase);
        public Dictionary<string, IPerfScenarioFactory> FactoryByCode = new Dictionary<string, IPerfScenarioFactory>(StringComparer.OrdinalIgnoreCase);
        public List<IPerfFingerprintContributor> Contributors = new List<IPerfFingerprintContributor>();
        public List<IPerfLeftoverCleaner> Cleaners = new List<IPerfLeftoverCleaner>();
        public List<string> Errors = new List<string>();
    }

    private static readonly Lazy<RegistryState> State = new Lazy<RegistryState>(Build, LazyThreadSafetyMode.ExecutionAndPublication);

    /// <summary>All descriptors sorted by SortOrder then TestCode (ordinal).</summary>
    public static IReadOnlyList<PerfTestDescriptor> All => State.Value.Descriptors;

    public static IReadOnlyList<IPerfFingerprintContributor> FingerprintContributors => State.Value.Contributors;

    public static IReadOnlyList<IPerfLeftoverCleaner> LeftoverCleaners => State.Value.Cleaners;

    /// <summary>Problems found while loading (skipped types, invalid or duplicate descriptors). Empty when the catalog is healthy.</summary>
    public static IReadOnlyList<string> LoadErrors => State.Value.Errors;

    /// <summary>Accepts catalog codes and the 12 legacy codes (mapped through PerfLegacyAliases).</summary>
    public static bool TryGet(string testCode, out PerfTestDescriptor descriptor)
    {
        descriptor = null;
        if (string.IsNullOrWhiteSpace(testCode)) return false;
        return State.Value.ByCode.TryGetValue(PerfLegacyAliases.Map(testCode.Trim()), out descriptor);
    }

    public static PerfTestDescriptor Get(string testCode) =>
        TryGet(testCode, out var d) ? d : throw new PXException("Unknown benchmark test code: " + testCode + ".");

    /// <summary>Creates a new scenario instance for one run. Throws PXException for an unknown code.</summary>
    public static IPerfScenario Create(string testCode)
    {
        var code = PerfLegacyAliases.Map(testCode?.Trim());
        if (code == null || !State.Value.FactoryByCode.TryGetValue(code, out var factory))
            throw new PXException("Unknown benchmark test code: " + testCode + ".");
        return factory.Create(code) ?? throw new PXException("The factory for " + code + " returned no scenario.");
    }

    private static RegistryState Build()
    {
        var state = new RegistryState();
        try
        {
            foreach (var type in LoadableTypes(typeof(PerfScenarioRegistry).Assembly, state.Errors))
            {
                try
                {
                    if (type.IsAbstract || type.IsInterface || type.ContainsGenericParameters) continue;
                    if (type.GetConstructor(Type.EmptyTypes) == null) continue;

                    if (typeof(IPerfScenarioFactory).IsAssignableFrom(type))
                    {
                        var factory = (IPerfScenarioFactory)Activator.CreateInstance(type);
                        foreach (var d in factory.Descriptors ?? Enumerable.Empty<PerfTestDescriptor>())
                        {
                            var problem = Validate(d, type);
                            if (problem != null) { state.Errors.Add(problem); continue; }
                            if (state.ByCode.ContainsKey(d.TestCode))
                            {
                                state.Errors.Add("Duplicate benchmark TestCode " + d.TestCode + " (factory " + type.FullName + "); the first registration is kept.");
                                continue;
                            }
                            state.ByCode[d.TestCode] = d;
                            state.FactoryByCode[d.TestCode] = factory;
                        }
                    }

                    if (typeof(IPerfFingerprintContributor).IsAssignableFrom(type))
                    {
                        state.Contributors.Add((IPerfFingerprintContributor)Activator.CreateInstance(type));
                    }

                    if (typeof(IPerfLeftoverCleaner).IsAssignableFrom(type))
                    {
                        state.Cleaners.Add((IPerfLeftoverCleaner)Activator.CreateInstance(type));
                    }
                }
                catch (Exception ex)
                {
                    state.Errors.Add("Type " + type.FullName + " was skipped: " + (ex.InnerException ?? ex).Message);
                }
            }
        }
        catch (Exception ex)
        {
            state.Errors.Add("Registry scan failed: " + ex.Message);
        }

        state.Descriptors = state.ByCode.Values
            .OrderBy(d => d.SortOrder)
            .ThenBy(d => d.TestCode, StringComparer.Ordinal)
            .ToList();
        state.Contributors = state.Contributors.OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        state.Cleaners = state.Cleaners.OrderBy(c => c.Name, StringComparer.Ordinal).ToList();
        return state;
    }

    /// <summary>Returns null for a valid descriptor, otherwise the reason it is skipped.</summary>
    private static string Validate(PerfTestDescriptor d, Type factory)
    {
        string Fail(string what) => "Invalid descriptor " + (d?.TestCode ?? "(null)") + " from " + factory.FullName + ": " + what + "; skipped.";
        if (d == null || string.IsNullOrWhiteSpace(d.TestCode)) return Fail("TestCode is empty");
        if (d.TestCode.Length > 64) return Fail("TestCode longer than 64");
        if (string.IsNullOrWhiteSpace(d.DisplayName) || d.DisplayName.Length > 128) return Fail("DisplayName empty or longer than 128");
        if (d.ShortLabel != null && d.ShortLabel.Length > 16) return Fail("ShortLabel longer than 16");
        if (d.Users < 1) return Fail("Users < 1");
        if (d.OrderedChecksum && d.Users > 1) return Fail("OrderedChecksum requires Users == 1");
        if (d.HeadlineKind != PerfHeadlineKinds.MedianOpMs && d.HeadlineKind != PerfHeadlineKinds.MedianPassMs &&
            d.HeadlineKind != PerfHeadlineKinds.OpsPerMin && d.HeadlineKind != PerfHeadlineKinds.None)
            return Fail("unknown HeadlineKind " + d.HeadlineKind);
        return null;
    }

    private static IEnumerable<Type> LoadableTypes(Assembly assembly, List<string> errors)
    {
        try { return assembly.GetTypes(); }
        catch (ReflectionTypeLoadException ex)
        {
            foreach (var le in ex.LoaderExceptions ?? new Exception[0])
            {
                if (le != null) errors.Add("Type load: " + le.Message);
            }
            return ex.Types.Where(t => t != null);
        }
    }
}
