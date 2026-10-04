using PX.Common;

namespace PerfDBBenchmark.Core.Scenarios.Business;

/// <summary>
/// The current branch of the business families' Acumatica session (SPEC §1.6, §1.7). Untimed; never called from ExecuteOperation.
/// <para>
/// A signed-in clerk always works in a current branch. The login stores it in the session context
/// (PXLogin.InitWithDefaultBranch → PXContext.SetBranchID), and every graph copies it into AccessInfo.BranchID and
/// AccessInfo.BaseCuryID when its AccessInfo is built (PXGraph.InitScopedAccessInfoProperties), again after every
/// Clear(ClearAll). Document defaults read those fields: SOOrder.CuryID and ARRegister.CuryID default to
/// Current&lt;AccessInfo.baseCuryID&gt;, CurrencyInfo.BaseCuryID and CurrencyInfo.CuryID to AccessInfo.baseCuryID, and
/// SOOrder.BranchID / ARInvoice.BranchID to AccessInfo.branchID.
/// </para>
/// <para>
/// The benchmark's REST login (admin) has no branch: every SalesDemo branch is restricted to a branch role that admin does not
/// have, so SMAccessPersonalMaint.GetDefaultBranchId returns null and the long operation and its worker threads inherit no
/// branch (long operations copy the session context). These helpers give the run the branch a PRODWHOLE clerk has, the same
/// way Acumatica's scheduler does for scheduled processing (ScheduleProcessor: PXContext.SetBranchID before the work starts).
/// </para>
/// </summary>
public static class PerfBranchContext
{
    /// <summary>
    /// Makes branchId the current branch of the calling thread's session context and returns the previous one (put it back
    /// with Restore). Graphs whose AccessInfo is built afterwards on this thread see the branch, and so do worker threads
    /// started afterwards from this thread, because a long operation clones the caller's session context.
    /// </summary>
    public static int? Enter(int branchId)
    {
        var previous = PXContext.GetBranchID();
        Ensure(branchId);
        return previous;
    }

    /// <summary>
    /// Re-asserts branchId on the calling thread. Worker threads call it in BeforeOperation, before Clear(ClearAll) rebuilds
    /// the graph's AccessInfo. Does nothing when the branch is already current.
    /// </summary>
    public static void Ensure(int branchId)
    {
        if (PXContext.GetBranchID() != branchId) PXContext.SetBranchID(branchId);
    }

    /// <summary>Puts back the branch that Enter replaced (on the thread that called Enter).</summary>
    public static void Restore(int? previous)
    {
        if (PXContext.GetBranchID() != previous) PXContext.SetBranchID(previous);
    }
}
