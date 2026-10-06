# /traders [SIMBOLO]  (chat privado y grupo Alertas Mercados): posicionamiento de los MEJORES TRADERS en un activo.
#  - Sin argumentos: BTC y ETH.
#  - Cripto: mejores traders y masa en Binance, OKX, Bybit y Gate.io (datos agregados oficiales) + ballenas de Hyperliquid (posiciones individuales públicas on-chain).
#  - Acciones de EE. UU.: perpetuos que replican la acción (Binance/OKX/Gate.io) + instituciones (13F, trimestral) + directivos (Form 4, casi en tiempo real) vía Yahoo Finance/SEC.
# Son datos de CONTEXTO: no son copy trading ni una señal validada. Las posiciones individuales de los exchanges centralizados no son públicas.
function Get-StockTraderLines($sym) {
    $L = @()
    try {
        if (-not (Get-YahooSession)) { return @("   No he podido abrir la sesión de Yahoo Finance ahora.") }
        $u = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/" + [uri]::EscapeDataString($sym) + "?modules=institutionOwnership,insiderTransactions,majorHoldersBreakdown,netSharePurchaseActivity,price&crumb=" + [uri]::EscapeDataString($script:YCrumb)
        $r = (Invoke-RestMethod $u -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 25).quoteSummary.result[0]
        $nm = $r.price.longName; if ($nm) { $L += "   $nm" }
        $mh = $r.majorHoldersBreakdown; if ($mh) { $L += ("🏛️ Quién la tiene: instituciones {0} · directivos e insiders {1}" -f $mh.institutionsPercentHeld.fmt, $mh.insidersPercentHeld.fmt) }
        $own = @($r.institutionOwnership.ownershipList | Select-Object -First 6)
        if ($own.Count) { $L += "   Mayores instituciones (informe 13F, trimestral; el «cambio» es frente al trimestre anterior):"; foreach ($o in $own) { $L += ("   • {0}: {1} del capital · cambio {2}" -f $o.organization, $o.pctHeld.fmt, $o.pctChange.fmt) } }
        $ns = $r.netSharePurchaseActivity; if ($ns -and $ns.period) { $L += ("👔 Directivos (últimos {0}): {1} compras ({2} acciones) · {3} ventas ({4} acciones) · neto {5} ({6} de lo que poseen)" -f $ns.period, $ns.buyInfoCount.fmt, $ns.buyInfoShares.fmt, $ns.sellInfoCount.fmt, $ns.sellInfoShares.fmt, $ns.netInfoShares.fmt, $ns.netPercentInsiderShares.fmt) }
        $tx = @($r.insiderTransactions.transactions | Where-Object { $_.transactionText } | Select-Object -First 5)
        if ($tx.Count) { $L += "   Últimas operaciones de directivos (Form 4):"; foreach ($t in $tx) { $L += ("   • {0} · {1} · {2}{3}" -f $t.startDate.fmt, $t.filerName, $t.transactionText, $(if ($t.value.fmt) { " · " + $t.value.fmt + " USD" } else { "" })) } }
        if (-not $own.Count -and -not $tx.Count) { $L += "   Yahoo Finance no tiene datos de instituciones ni directivos de este valor." }
    } catch { $L += "   No he podido leer los datos de instituciones y directivos ahora." }
    return $L
}
function Get-CryptoTraderLines($c) {
    $L = @(); $sm = @(Get-SmartMoneyLines $c); if ($sm.Count) { $L += $sm } else { $L += "   Sin datos de posicionamiento agregado para $c en Binance/OKX/Bybit/Gate.io." }
    try { $pos = @((Get-BallPositions 2000000).Values); $hl = if ($c -like '1000*') { 'k' + $c.Substring(4) } else { $c }; $x = @($pos | Where-Object { $_.coin -ieq $hl })
        if ($x.Count) { $sl = (@($x | Where-Object { $_.side -eq 'L' }) | Measure-Object usd -Sum).Sum; $ss = (@($x | Where-Object { $_.side -eq 'S' }) | Measure-Object usd -Sum).Sum; if (-not $sl) { $sl = 0 }; if (-not $ss) { $ss = 0 }
            $L += ("🐋 Ballenas en Hyperliquid (posiciones públicas de 2 M USD o más): {0:N0} M largo ({1} carteras) · {2:N0} M corto ({3} carteras) → {4}" -f ($sl / 1e6), @($x | Where-Object { $_.side -eq 'L' }).Count, ($ss / 1e6), @($x | Where-Object { $_.side -eq 'S' }).Count, $(if ($sl -ge 1.5 * $ss) { "sesgo LARGO" } elseif ($ss -ge 1.5 * $sl) { "sesgo CORTO" } else { "equilibrado" }))
            foreach ($p in ($x | Sort-Object usd -Descending | Select-Object -First 3)) { $L += ("   {0} {1:N0} M · x{2} · PnL no real. {3:+0.0;-0.0} M" -f $(if ($p.side -eq 'L') { "🟢 LARGO" } else { "🔴 CORTO" }), ($p.usd / 1e6), $p.lev, ($p.upl / 1e6)) } }
        else { $L += "🐋 Hyperliquid: ninguna de las mayores carteras tiene ahora una posición de 2 M USD o más en $c." } } catch {}
    return $L
}
function Handle-Traders($ra) {
    $words = @($ra | ForEach-Object { "$_" } | Where-Object { $_ -match '^[A-Za-z0-9.\-]{1,12}$' }); $hora = (Get-Date).ToString('dd/MM HH:mm')
    $syms = if ($words.Count) { @($words[0].ToUpper() -replace 'USDT$', '') } else { @('BTC', 'ETH') }
    $L = @("🏆 MEJORES TRADERS · {0} (hora de España)" -f $hora); $L += ""
    $cryptoMajors = 'BTC', 'ETH', 'SOL', 'XRP', 'BNB', 'DOGE', 'ADA', 'AVAX', 'LINK', 'LTC', 'HYPE', 'SUI', 'NEAR', 'FET', 'API3', 'WLD', 'TAO', 'PEPE', 'ENA', 'ARB', 'OP', 'INJ', 'APT', 'DOT', 'AAVE', 'UNI', 'ZEC', 'TRX', 'BCH', 'TON'
    foreach ($s in $syms) {
        if ($s -in $cryptoMajors) { $L += "━━ $s (cripto)"; $L += (Get-CryptoTraderLines $s) }
        else { $L += "━━ $s (acción de EE. UU.)"
            $perp = @(Get-SmartMoneyLines $s); if ($perp.Count) { $L += "📊 Perpetuo que replica la acción (mejores traders de los exchanges cripto que lo cotizan):"; $L += ($perp | Where-Object { $_ -notlike '*Datos oficiales*' }) }
            $L += (Get-StockTraderLines $s); $L += "   ⏱️ Los informes 13F de instituciones llegan con hasta 45 días de retraso; las operaciones de directivos (Form 4) en 2 días hábiles." }
        $L += ""
    }
    $L += "ℹ️ Datos de CONTEXTO de fuentes oficiales y públicas; no son copy trading ni una señal validada. En los exchanges centralizados las posiciones individuales no son públicas (solo datos agregados); las posiciones individuales visibles son las de Hyperliquid."
    return ($L -join "`n")
}
