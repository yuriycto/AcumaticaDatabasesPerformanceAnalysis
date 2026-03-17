using System;
using System.Collections.Generic;
using System.Linq;
using System.Web;
using PX.Data;
using PX.Data.BQL;
using PX.Data.BQL.Fluent;
using PX.SM;

[assembly: PreApplicationStartMethod(typeof(PerfDBBenchmark.Core.Support.PerfAccessRightsBootstrap), "Start")]

namespace PerfDBBenchmark.Core.Support;

public static class PerfAccessRightsBootstrap
{
    private static readonly string[] TargetScreenIds =
    {
        "AC301000",
        "AC301001"
    };
    private const string SessionKey = "PerfDBBenchmark.AccessRightsBootstrap.v2";
    private static readonly string[] ReferenceScreenIds =
    {
        "DB000031",
        "SM204505",
        "SM200520",
        "SM201020"
    };

    private static readonly object SyncRoot = new();

    public static void Start()
    {
        HttpApplication.RegisterModule(typeof(PerfAccessRightsBootstrapModule));
    }

    internal static void EnsureForAuthenticatedRequest()
    {
        if (HttpContext.Current?.User?.Identity?.IsAuthenticated != true)
        {
            return;
        }

        var session = HttpContext.Current?.Session;
        if (session != null && session[SessionKey] is true)
        {
            return;
        }

        lock (SyncRoot)
        {
            if (session != null && session[SessionKey] is true)
            {
                return;
            }

            try
            {
                if (EnsureCompanyRights())
                {
                    if (session != null)
                    {
                        session[SessionKey] = true;
                    }
                }
            }
            catch
            {
            }
        }
    }

    private static bool EnsureCompanyRights()
    {
        var referenceRights = LoadReferenceRights();
        if (referenceRights.Count == 0)
        {
            return false;
        }

        var insertedAny = false;

        foreach (var targetScreenId in TargetScreenIds)
        {
            var targetRoleKeys = LoadRoleKeys(targetScreenId);

            foreach (var referenceRight in referenceRights)
            {
                var targetKey = BuildRoleKey(referenceRight.RoleName, referenceRight.ApplicationName);
                if (targetRoleKeys.Contains(targetKey))
                {
                    continue;
                }

                if (InsertTargetRight(targetScreenId, referenceRight))
                {
                    insertedAny = true;
                    targetRoleKeys.Add(targetKey);
                }
            }
        }

        return insertedAny || TargetScreenIds.Any(screenId => LoadRoleKeys(screenId).Count > 0);
    }

    private static List<ScreenRoleRight> LoadReferenceRights()
    {
        foreach (var referenceScreenId in ReferenceScreenIds)
        {
            var rights = LoadRights(referenceScreenId);
            if (rights.Count > 0)
            {
                return rights;
            }
        }

        return new List<ScreenRoleRight>();
    }

    private static List<ScreenRoleRight> LoadRights(string screenId)
    {
        var graph = PXGraph.CreateInstance<PXGraph>();

        return SelectFrom<RolesInGraph>
            .Where<RolesInGraph.screenID.IsEqual<@P.AsString>>
            .View
            .ReadOnly
            .Select(graph, screenId)
            .RowCast<RolesInGraph>()
            .Where(row => !string.IsNullOrWhiteSpace(row.Rolename))
            .Select(row => new ScreenRoleRight
            {
                RoleName = row.Rolename.Trim(),
                ApplicationName = NormalizeApplicationName(row.ApplicationName),
                AccessRights = row.Accessrights ?? 0,
                CreatedById = row.CreatedByID,
                CreatedByScreenId = row.CreatedByScreenID,
                CreatedDateTime = row.CreatedDateTime,
                LastModifiedById = row.LastModifiedByID,
                LastModifiedByScreenId = row.LastModifiedByScreenID,
                LastModifiedDateTime = row.LastModifiedDateTime
            })
            .GroupBy(x => BuildRoleKey(x.RoleName, x.ApplicationName), StringComparer.OrdinalIgnoreCase)
            .Select(x => x.First())
            .ToList();
    }

    private static HashSet<string> LoadRoleKeys(string screenId)
    {
        return LoadRights(screenId)
            .Select(x => BuildRoleKey(x.RoleName, x.ApplicationName))
            .Where(x => !string.IsNullOrWhiteSpace(x))
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
    }

    private static bool InsertTargetRight(string targetScreenId, ScreenRoleRight referenceRight)
    {
        // Copying rights from stock Acumatica screens keeps benchmark screens publishable
        // without relying on a separate SQL patch for each benchmark instance.
        return PXDatabase.Insert<RolesInGraph>(
            new PXDataFieldAssign(nameof(RolesInGraph.ScreenID), targetScreenId),
            new PXDataFieldAssign(nameof(RolesInGraph.Rolename), referenceRight.RoleName),
            new PXDataFieldAssign(nameof(RolesInGraph.ApplicationName), referenceRight.ApplicationName),
            new PXDataFieldAssign(nameof(RolesInGraph.Accessrights), referenceRight.AccessRights),
            new PXDataFieldAssign(nameof(RolesInGraph.CreatedByID), referenceRight.CreatedById),
            new PXDataFieldAssign(nameof(RolesInGraph.CreatedByScreenID), referenceRight.CreatedByScreenId),
            new PXDataFieldAssign(nameof(RolesInGraph.CreatedDateTime), referenceRight.CreatedDateTime),
            new PXDataFieldAssign(nameof(RolesInGraph.LastModifiedByID), referenceRight.LastModifiedById),
            new PXDataFieldAssign(nameof(RolesInGraph.LastModifiedByScreenID), referenceRight.LastModifiedByScreenId),
            new PXDataFieldAssign(nameof(RolesInGraph.LastModifiedDateTime), referenceRight.LastModifiedDateTime));
    }

    private static string BuildRoleKey(string roleName, string applicationName)
    {
        if (string.IsNullOrWhiteSpace(roleName))
        {
            return string.Empty;
        }

        return roleName.Trim() + "|" + NormalizeApplicationName(applicationName);
    }

    private static string NormalizeApplicationName(string applicationName)
        => string.IsNullOrWhiteSpace(applicationName)
            ? "/"
            : applicationName.Trim();

    private sealed class ScreenRoleRight
    {
        public string RoleName { get; init; }
        public string ApplicationName { get; init; }
        public short AccessRights { get; init; }
        public Guid? CreatedById { get; init; }
        public string CreatedByScreenId { get; init; }
        public DateTime? CreatedDateTime { get; init; }
        public Guid? LastModifiedById { get; init; }
        public string LastModifiedByScreenId { get; init; }
        public DateTime? LastModifiedDateTime { get; init; }
    }
}

public sealed class PerfAccessRightsBootstrapModule : IHttpModule
{
    public void Init(HttpApplication context)
    {
        context.AcquireRequestState += HandleAcquireRequestState;
    }

    public void Dispose()
    {
    }

    private static void HandleAcquireRequestState(object sender, EventArgs e)
    {
        PerfAccessRightsBootstrap.EnsureForAuthenticatedRequest();
    }
}
