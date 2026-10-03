using System;
using PX.Data;
using PX.Data.BQL;
using PX.Objects.AR;
using PX.Objects.CR;

namespace PerfDBBenchmark.Core.Scenarios.Reports;

/// <summary>
/// Slim, non-aggregated, read-only projection over released AR invoice/memo/cash-sale lines joined to the customer's
/// business account (SPEC §1.5 card 5, Appendix B). Queried with FBQL
/// <c>AggregateTo&lt;GroupBy, GroupBy, GroupBy, Sum, Sum, Count&gt;</c>; <c>Count</c> (non-generic) is COUNT(*), read through
/// <c>PXResult.RowCount</c>. ARTran has no index on FinPeriodID, so every report scans the lines (realistic).
/// </summary>
[Serializable]
[PXHidden]
[PXProjection(typeof(Select2<ARTran,
    InnerJoin<BAccount, On<BAccount.bAccountID, Equal<ARTran.customerID>>>,
    Where<ARTran.released, Equal<True>,
        And<ARTran.tranType, In3<ARDocType.invoice, ARDocType.creditMemo, ARDocType.debitMemo, ARDocType.cashSale>>>>), Persistent = false)]
public sealed class PerfARTranSales : PXBqlTable, IBqlTable
{
    public abstract class tranType : BqlString.Field<tranType> { }
    [PXDBString(3, IsKey = true, IsFixed = true, BqlField = typeof(ARTran.tranType))]
    public string TranType { get; set; }

    public abstract class refNbr : BqlString.Field<refNbr> { }
    [PXDBString(15, IsKey = true, IsUnicode = true, BqlField = typeof(ARTran.refNbr))]
    public string RefNbr { get; set; }

    public abstract class lineNbr : BqlInt.Field<lineNbr> { }
    [PXDBInt(IsKey = true, BqlField = typeof(ARTran.lineNbr))]
    public int? LineNbr { get; set; }

    public abstract class customerID : BqlInt.Field<customerID> { }
    [PXDBInt(BqlField = typeof(ARTran.customerID))]
    public int? CustomerID { get; set; }

    public abstract class acctCD : BqlString.Field<acctCD> { }
    [PXDBString(30, IsUnicode = true, BqlField = typeof(BAccount.acctCD))]
    public string AcctCD { get; set; }

    public abstract class finPeriodID : BqlString.Field<finPeriodID> { }
    [PXDBString(6, IsFixed = true, BqlField = typeof(ARTran.finPeriodID))]
    public string FinPeriodID { get; set; }

    public abstract class tranAmt : BqlDecimal.Field<tranAmt> { }
    [PXDBDecimal(4, BqlField = typeof(ARTran.tranAmt))]
    public decimal? TranAmt { get; set; }

    public abstract class qty : BqlDecimal.Field<qty> { }
    [PXDBDecimal(6, BqlField = typeof(ARTran.qty))]
    public decimal? Qty { get; set; }
}
