using System;
using PX.Data;
using PX.Data.BQL;
using PX.Objects.SO;

namespace PerfDBBenchmark.Core.Scenarios.Screens;

/// <summary>
/// Slim, non-aggregated, read-only projection over the SO lines (SPEC §1.5 card 3, Appendix B).
/// Queried with FBQL <c>AggregateTo&lt;GroupBy, Sum, Sum, Count&gt;</c>: <c>Count</c> (non-generic) is COUNT(*), read through
/// <c>PXResult.RowCount</c>, and the slim column list avoids Acumatica's MAX()-over-every-column behaviour of wide DACs.
/// </summary>
[Serializable]
[PXHidden]
[PXProjection(typeof(Select<SOLine, Where<SOLine.orderType, Equal<SOOrderTypeConstants.salesOrder>>>), Persistent = false)]
public sealed class PerfSOLineSlim : PXBqlTable, IBqlTable
{
    public abstract class orderType : BqlString.Field<orderType> { }
    [PXDBString(2, IsKey = true, IsFixed = true, BqlField = typeof(SOLine.orderType))]
    public string OrderType { get; set; }

    public abstract class orderNbr : BqlString.Field<orderNbr> { }
    [PXDBString(15, IsKey = true, IsUnicode = true, BqlField = typeof(SOLine.orderNbr))]
    public string OrderNbr { get; set; }

    public abstract class lineNbr : BqlInt.Field<lineNbr> { }
    [PXDBInt(IsKey = true, BqlField = typeof(SOLine.lineNbr))]
    public int? LineNbr { get; set; }

    public abstract class inventoryID : BqlInt.Field<inventoryID> { }
    [PXDBInt(BqlField = typeof(SOLine.inventoryID))]
    public int? InventoryID { get; set; }

    public abstract class orderQty : BqlDecimal.Field<orderQty> { }
    [PXDBDecimal(6, BqlField = typeof(SOLine.orderQty))]
    public decimal? OrderQty { get; set; }

    public abstract class curyLineAmt : BqlDecimal.Field<curyLineAmt> { }
    [PXDBDecimal(4, BqlField = typeof(SOLine.curyLineAmt))]
    public decimal? CuryLineAmt { get; set; }
}
