using System;
using PX.Data;
using PX.Data.BQL;
using PX.Objects.AR;
using PX.Objects.GL;
using PX.Objects.IN;
using PX.Objects.SO;

namespace PerfDBBenchmark.Core.Scenarios.Environment;

// Slim, non-persistent projections for the ENV_CAPTURE data fingerprint sums (SPEC §1.8). Each one is queried with
// AggregateTo<Sum<…>, Sum<…>, Count> and no GroupBy, so the database returns one row with the totals.

[Serializable]
[PXHidden]
[PXProjection(typeof(Select<GLTran>), Persistent = false)]
public sealed class EnvGLTranSums : PXBqlTable, IBqlTable
{
    public abstract class module : BqlString.Field<module> { }
    [PXDBString(2, IsKey = true, IsFixed = true, BqlField = typeof(GLTran.module))]
    public string Module { get; set; }

    public abstract class batchNbr : BqlString.Field<batchNbr> { }
    [PXDBString(15, IsKey = true, IsUnicode = true, BqlField = typeof(GLTran.batchNbr))]
    public string BatchNbr { get; set; }

    public abstract class lineNbr : BqlInt.Field<lineNbr> { }
    [PXDBInt(IsKey = true, BqlField = typeof(GLTran.lineNbr))]
    public int? LineNbr { get; set; }

    public abstract class debitAmt : BqlDecimal.Field<debitAmt> { }
    [PXDBDecimal(4, BqlField = typeof(GLTran.debitAmt))]
    public decimal? DebitAmt { get; set; }

    public abstract class creditAmt : BqlDecimal.Field<creditAmt> { }
    [PXDBDecimal(4, BqlField = typeof(GLTran.creditAmt))]
    public decimal? CreditAmt { get; set; }
}

[Serializable]
[PXHidden]
[PXProjection(typeof(Select<ARTran>), Persistent = false)]
public sealed class EnvARTranSums : PXBqlTable, IBqlTable
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

    public abstract class tranAmt : BqlDecimal.Field<tranAmt> { }
    [PXDBDecimal(4, BqlField = typeof(ARTran.tranAmt))]
    public decimal? TranAmt { get; set; }
}

[Serializable]
[PXHidden]
[PXProjection(typeof(Select<SOOrder>), Persistent = false)]
public sealed class EnvSOOrderSums : PXBqlTable, IBqlTable
{
    public abstract class orderType : BqlString.Field<orderType> { }
    [PXDBString(2, IsKey = true, IsFixed = true, BqlField = typeof(SOOrder.orderType))]
    public string OrderType { get; set; }

    public abstract class orderNbr : BqlString.Field<orderNbr> { }
    [PXDBString(15, IsKey = true, IsUnicode = true, BqlField = typeof(SOOrder.orderNbr))]
    public string OrderNbr { get; set; }

    public abstract class curyOrderTotal : BqlDecimal.Field<curyOrderTotal> { }
    [PXDBDecimal(4, BqlField = typeof(SOOrder.curyOrderTotal))]
    public decimal? CuryOrderTotal { get; set; }
}

[Serializable]
[PXHidden]
[PXProjection(typeof(Select<INSiteStatusByCostCenter>), Persistent = false)]
public sealed class EnvSiteStatusSums : PXBqlTable, IBqlTable
{
    public abstract class inventoryID : BqlInt.Field<inventoryID> { }
    [PXDBInt(IsKey = true, BqlField = typeof(INSiteStatusByCostCenter.inventoryID))]
    public int? InventoryID { get; set; }

    public abstract class subItemID : BqlInt.Field<subItemID> { }
    [PXDBInt(IsKey = true, BqlField = typeof(INSiteStatusByCostCenter.subItemID))]
    public int? SubItemID { get; set; }

    public abstract class siteID : BqlInt.Field<siteID> { }
    [PXDBInt(IsKey = true, BqlField = typeof(INSiteStatusByCostCenter.siteID))]
    public int? SiteID { get; set; }

    public abstract class costCenterID : BqlInt.Field<costCenterID> { }
    [PXDBInt(IsKey = true, BqlField = typeof(INSiteStatusByCostCenter.costCenterID))]
    public int? CostCenterID { get; set; }

    public abstract class qtyOnHand : BqlDecimal.Field<qtyOnHand> { }
    [PXDBDecimal(6, BqlField = typeof(INSiteStatusByCostCenter.qtyOnHand))]
    public decimal? QtyOnHand { get; set; }

    public abstract class qtyAvail : BqlDecimal.Field<qtyAvail> { }
    [PXDBDecimal(6, BqlField = typeof(INSiteStatusByCostCenter.qtyAvail))]
    public decimal? QtyAvail { get; set; }
}
