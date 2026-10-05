# Universo de activos del grupo "Alertas Mercado": acciones líquidas, ETFs, materias primas y cripto vía ETF/acciones relacionadas, y valores del IBEX.
# Solo activos con mucha liquidez (el volumen es la base de la táctica). Los símbolos son los de Yahoo Finance.
$script:UniAcciones = @(
    'AAPL','MSFT','NVDA','AMZN','GOOGL','META','TSLA','AVGO','ORCL','NFLX','AMD','ADBE','CRM','INTC','CSCO','QCOM','TXN','MU','AMAT','IBM',
    'JPM','BAC','WFC','GS','MS','V','MA','AXP','BRK-B','C','PYPL','COIN','SCHW',
    'UNH','LLY','JNJ','PFE','MRK','ABBV','TMO','ABT','AMGN','GILD','MRNA',
    'XOM','CVX','COP','OXY','SLB','CAT','DE','BA','GE','HON','LMT','RTX','UPS','FDX',
    'WMT','COST','HD','LOW','MCD','SBUX','NKE','DIS','KO','PEP','PG','TGT','PLTR','UBER','SHOP','SNOW','MSTR','IREN','RIOT','MARA',
    'SAN.MC','BBVA.MC','ITX.MC','IBE.MC','TEF.MC','REP.MC','AMS.MC','CABK.MC','FER.MC','ELE.MC'
)
$script:UniAcciones += @(
    'NOW','INTU','PANW','CRWD','FTNT','ANET','KLAC','LRCX','ADI','MCHP','NXPI','ON','SNPS','CDNS','WDAY','TEAM','DDOG','ZS','NET','MDB','TTD','ROKU','ABNB','BKNG','EXPE','EBAY','ETSY','DASH','PINS','SNAP','SPOT','HPQ','DELL','HPE','WDC','STX','SMCI','ARM','TSM','ASML','SAP',
    'BLK','SPGI','MCO','CME','ICE','PGR','CB','MMC','AON','TRV','ALL','AIG','MET','PRU','USB','PNC','TFC','COF','BK','STT','KKR','BX','APO','HOOD','SOFI','AFRM',
    'ISRG','VRTX','REGN','BMY','CVS','CI','HUM','ELV','DHR','SYK','MDT','BSX','ZTS','BDX','EW','IDXX','DXCM','HCA','BIIB','NVO',
    'MMM','EMR','ETN','ITW','PH','CMI','PCAR','NSC','UNP','CSX','WM','RSG','GD','NOC','LHX','TDG','URI','FAST',
    'TJX','ROST','DG','DLTR','MAR','HLT','CMG','YUM','DRI','LULU','DECK','ULTA','EL','CL','KMB','MDLZ','KHC','GIS','HSY','MO','PM','TSN',
    'EOG','PSX','VLO','MPC','KMI','WMB','OKE','HAL','FCX','NEM','LIN','APD','SHW','ECL','DOW','NEE','DUK','SO','D','AEP','XEL',
    'T','VZ','TMUS','CMCSA','CHTR','AMT','PLD','CCI','EQIX','SPG','O',
    'F','GM','RIVN','NIO','BABA','JD','PDD','TM','SONY','RBLX','U','PATH','ENPH','FSLR','CCL','RCL','DAL','UAL','AAL'
)
$script:UniETF = @(
    'SPY','QQQ','IWM','DIA','VTI','VOO','EFA','EEM','FXI','EWJ','EWZ','VGK',
    'XLK','XLF','XLE','XLV','XLY','XLP','XLI','XLU','XLB','XLRE','XLC','SMH','SOXX','ARKK','XBI','KRE','IBB',
    'GLD','SLV','GDX','USO','UNG','DBC','CPER',
    'TLT','IEF','SHY','HYG','LQD','TIP',
    'UUP','FXE','FXY','VNQ',
    'IBIT','ETHA','BITO',
    'IYR','XME','ITB','XHB','JETS','TAN','ICLN','LIT','URA','IWD','IWF','MTUM','QUAL','VUG','VTV','SCHD','DVY','SDY','VYM','IJH','IJR','MDY','RSP','EWG','EWU','EWY','EWT','INDA','KWEB','VWO','ACWI','VT','AGG','BND','MBB'
)
$script:UniTodos = @($script:UniAcciones + $script:UniETF | Select-Object -Unique)
function Get-AssetKind($tkr) {
    if ($tkr -in $script:UniETF) { return "ETF" }
    if ($tkr -like '*.MC') { return "acción española (BME)" }
    return "acción"
}
