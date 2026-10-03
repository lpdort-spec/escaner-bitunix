# Datos de varias plataformas para el informe: operaciones grandes reales (Binance, Bybit, OKX, Coinbase), posicionamiento en derivados,
# fundamentales de cripto (CoinGecko), instituciones/analistas/short interest de acciones (Yahoo) y transferencias grandes de BTC (mempool).
# Regla: solo APIs públicas; cada plataforma se consulta por separado y el informe dice cuáles respondieron. Nada se estima sin avisarlo.
$script:PlatOK = @(); $script:PlatFail = @()
$script:PUA = @{ 'User-Agent' = 'AlertasBitunix-bot/1.0 (uso personal)'; 'Accept' = 'application/json' }

function Plat-Get($name, $url, [int]$timeout = 15) {            # GET con registro de éxito/fallo por plataforma (1 reintento)
    foreach ($try in 1..2) {
        try {
            $raw = (Invoke-WebRequest $url -UseBasicParsing -Headers $script:PUA -TimeoutSec $timeout).Content
            if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
            $raw = $raw -replace ',"M":(true|false)', ''
            $r = $raw | ConvertFrom-Json
            if ($name -notin $script:PlatOK) { $script:PlatOK += $name }; $script:PlatFail = @($script:PlatFail | Where-Object { $_ -ne $name }); return $r
        } catch { if ($try -eq 1) { Start-Sleep -Milliseconds 1500 } }
    }
    if ($name -notin $script:PlatOK -and $name -notin $script:PlatFail) { $script:PlatFail += $name }
    return $null
}
function Merge-Whale($rows, $minUsd) {                          # agrupa fills consecutivos del mismo lado en el mismo segundo (una orden grande barre varios niveles)
    $out = @(); $cur = $null
    foreach ($t in ($rows | Sort-Object ts)) {
        $sec = [Math]::Floor($t.ts / 1000)
        if ($cur -and $cur.side -eq $t.side -and $cur.sec -eq $sec) { $cur.usd += $t.usd; $cur.pxw += $t.px * $t.usd }
        else { if ($cur) { $out += $cur }; $cur = [pscustomobject]@{ ts = $t.ts; sec = $sec; side = $t.side; usd = $t.usd; pxw = $t.px * $t.usd; venue = $t.venue } }
    }
    if ($cur) { $out += $cur }
    foreach ($o in $out) { $o | Add-Member -NotePropertyName px -NotePropertyValue ($o.pxw / [Math]::Max(1, $o.usd)) -Force }
    return @($out)
}
function Get-BinanceTrades($base, $path, $venue, $sym, $pages = 5) {   # aggTrades: m=true => el comprador era maker => agresión VENDEDORA
    $name = if ($base -like '*fapi*') { "Binance Futuros" } else { "Binance Spot" }
    $all = @(); $r = Plat-Get $name "${base}${path}?symbol=${sym}USDT&limit=1000"
    if (-not $r -or $r.Count -eq 0) { return $null }
    $batch = @($r); $all += $batch
    for ($p = 1; $p -lt $pages; $p++) {
        $from = [long]$batch[0].a - 1000; if ($from -lt 0) { break }
        $b = Plat-Get $name "${base}${path}?symbol=${sym}USDT&fromId=$from&limit=1000"; if (-not $b -or $b.Count -eq 0) { break }
        $batch = @($b | Where-Object { [long]$_.a -lt [long]$all[0].a }); if ($batch.Count -eq 0) { break }
        $all = @($batch) + $all
    }
    $rows = $all | ForEach-Object { [pscustomobject]@{ ts = [long]$_.T; side = $(if ($_.m) { "VENTA" } else { "COMPRA" }); px = [double]$_.p; usd = [double]$_.p * [double]$_.q; venue = $venue } }
    return @{ venue = $venue; rows = @($rows); first = ($rows | Measure-Object ts -Minimum).Minimum; last = ($rows | Measure-Object ts -Maximum).Maximum }
}
function Get-BybitTrades($sym) {
    $r = Plat-Get "Bybit" "https://api.bybit.com/v5/market/recent-trade?category=linear&symbol=${sym}USDT&limit=1000"
    if (-not $r -or $r.retCode -ne 0 -or -not $r.result.list) { return $null }
    $rows = $r.result.list | ForEach-Object { [pscustomobject]@{ ts = [long]$_.time; side = $(if ($_.side -eq "Buy") { "COMPRA" } else { "VENTA" }); px = [double]$_.price; usd = [double]$_.price * [double]$_.size; venue = "Bybit Futuros" } }
    return @{ venue = "Bybit Futuros"; rows = @($rows); first = ($rows | Measure-Object ts -Minimum).Minimum; last = ($rows | Measure-Object ts -Maximum).Maximum }
}
function Get-OkxTrades($sym) {
    $ins = Plat-Get "OKX" "https://www.okx.com/api/v5/public/instruments?instType=SWAP&instId=${sym}-USDT-SWAP"
    if (-not $ins -or $ins.code -ne "0" -or -not $ins.data) { return $null }
    $ct = [double]$ins.data[0].ctVal
    $r = Plat-Get "OKX" "https://www.okx.com/api/v5/market/trades?instId=${sym}-USDT-SWAP&limit=500"
    if (-not $r -or $r.code -ne "0" -or -not $r.data) { return $null }
    $rows = $r.data | ForEach-Object { [pscustomobject]@{ ts = [long]$_.ts; side = $(if ($_.side -eq "buy") { "COMPRA" } else { "VENTA" }); px = [double]$_.px; usd = [double]$_.px * [double]$_.sz * $ct; venue = "OKX Futuros" } }
    return @{ venue = "OKX Futuros"; rows = @($rows); first = ($rows | Measure-Object ts -Minimum).Minimum; last = ($rows | Measure-Object ts -Maximum).Maximum }
}
function Get-CoinbaseTrades($sym) {                             # dirección no fiable en esta API: se cuenta solo el tamaño
    $r = Plat-Get "Coinbase" "https://api.exchange.coinbase.com/products/${sym}-USD/trades?limit=1000"
    if (-not $r -or $r.Count -eq 0) { return $null }
    $rows = $r | ForEach-Object { $t = [datetimeoffset]::Parse($_.time).ToUnixTimeMilliseconds(); [pscustomobject]@{ ts = $t; side = "n/d"; px = [double]$_.price; usd = [double]$_.price * [double]$_.size; venue = "Coinbase Spot" } }
    return @{ venue = "Coinbase Spot"; rows = @($rows); first = ($rows | Measure-Object ts -Minimum).Minimum; last = ($rows | Measure-Object ts -Maximum).Maximum }
}
function Get-WhaleSection($SYM, [double]$minUsd = 1000000) {
    $L = @(); $L += "🐋 BALLENAS · operaciones EJECUTADAS de más de 1 M USD (datos reales de varias plataformas)"
    $src = @()
    $src += Get-BinanceTrades "https://fapi.binance.com" "/fapi/v1/aggTrades" "Binance Futuros" $SYM
    $b = Get-BinanceTrades "https://api.binance.com" "/api/v3/aggTrades" "Binance Spot" $SYM
    if (-not $b) { $b = Get-BinanceTrades "https://data-api.binance.vision" "/api/v3/aggTrades" "Binance Spot" $SYM }
    $src += $b; $src += Get-BybitTrades $SYM; $src += Get-OkxTrades $SYM; $src += Get-CoinbaseTrades $SYM
    $src += Get-GateTrades $SYM; $src += Get-DeribitPerpTrades $SYM; $src += Get-BitgetTrades $SYM; $src += Get-KrakenFutTrades $SYM
    $src = @($src | Where-Object { $_ })
    if ($src.Count -eq 0) { $L += "• Ninguna plataforma devolvió operaciones para $SYM (no cotiza en ellas o no respondieron desde el servidor). No lo invento."; return $L }
    $big = @()
    foreach ($s in $src) {
        $mins = ($s.last - $s.first) / 60000.0
        $m = @(Merge-Whale $s.rows $minUsd | Where-Object { $_.usd -ge $minUsd }); $big += $m
        $vol = ($s.rows | Measure-Object usd -Sum).Sum
        $L += ("• {0}: {1:N0} operaciones, {2} de volumen en los últimos ~{3:N0} min; ≥1 M: {4}" -f $s.venue, $s.rows.Count, (Fm $vol), $mins, $m.Count)
    }
    if ($big.Count -eq 0) { $L += "• Ninguna operación individual alcanzó 1 M USD en esa ventana (en monedas pequeñas es lo normal; no significa que no operen ballenas fuera de ella)." }
    else {
        $buy = @($big | Where-Object side -eq "COMPRA"); $sell = @($big | Where-Object side -eq "VENTA"); $nd = @($big | Where-Object side -eq "n/d")
        $L += ("• Agresiones COMPRADORAS ≥1 M: {0} ({1} USD) · VENDEDORAS ≥1 M: {2} ({3} USD){4}" -f $buy.Count, (Fm ([double](($buy | Measure-Object usd -Sum).Sum))), $sell.Count, (Fm ([double](($sell | Measure-Object usd -Sum).Sum))), $(if ($nd.Count) { " · sin dirección fiable (Coinbase): $($nd.Count)" } else { "" }))
        foreach ($x in ($big | Sort-Object usd -Descending | Select-Object -First 6)) {
            $L += ("   - {0:HH:mm} UTC · {1} · {2} agresiva de {3} USD a ~{4}" -f [datetimeoffset]::FromUnixTimeMilliseconds($x.ts).UtcDateTime, $x.venue, $(if ($x.side -eq "n/d") { "operación" } else { $x.side.ToLower() }), (Fm $x.usd), (Fnum $x.px))
        }
    }
    $miss = @()
    if (-not ($src | Where-Object { $_.venue -eq 'Binance Futuros' })) { $miss += 'Binance Futuros' }
    if (-not ($src | Where-Object { $_.venue -eq 'Bybit Futuros' })) { $miss += 'Bybit' }
    if ($miss.Count) { $L += ("  ⚠️ Sin {0} (bloqueado desde el servidor del bot): el recuento de ballenas es PARCIAL, porque son de las plataformas con más volumen, y puede no reflejar el balance real de compras y ventas." -f ($miss -join ' ni ')) }
    $L += "  (Agresión compradora = la orden que ejecuta fue de compra a mercado. Es una ventana de minutos u horas, no un historial completo; ninguna plataforma gratuita da más atrás.)"
    return $L
}

# ---------- Derivados: interés abierto, funding y posicionamiento largo/corto por plataforma ----------
function Get-DerivSection($SYM) {
    $L = @(); $rows = @()
    $oi = Plat-Get "Binance Futuros" "https://fapi.binance.com/fapi/v1/openInterest?symbol=${SYM}USDT"
    $pi = Plat-Get "Binance Futuros" "https://fapi.binance.com/fapi/v1/premiumIndex?symbol=${SYM}USDT"
    if ($oi -and $pi) {
        $t = Plat-Get "Binance Futuros" "https://fapi.binance.com/futures/data/topLongShortPositionRatio?symbol=${SYM}USDT&period=1h&limit=1"
        $g = Plat-Get "Binance Futuros" "https://fapi.binance.com/futures/data/globalLongShortAccountRatio?symbol=${SYM}USDT&period=1h&limit=1"
        $x = "• Binance: interés abierto {0} USD · funding {1:N4}% por 8h" -f (Fm ([double]$oi.openInterest * [double]$pi.markPrice)), ([double]$pi.lastFundingRate * 100)
        if ($t) { $x += " · grandes traders (posiciones): {0:N0}% largos / {1:N0}% cortos" -f (100 * [double]$t[0].longAccount), (100 * [double]$t[0].shortAccount) }
        if ($g) { $x += " · todas las cuentas: {0:N0}% largos / {1:N0}% cortos" -f (100 * [double]$g[0].longAccount), (100 * [double]$g[0].shortAccount) }
        $rows += $x
    }
    $tk = Plat-Get "Bybit" "https://api.bybit.com/v5/market/tickers?category=linear&symbol=${SYM}USDT"
    if ($tk -and $tk.retCode -eq 0 -and $tk.result.list) {
        $e = $tk.result.list[0]; $ar = Plat-Get "Bybit" "https://api.bybit.com/v5/market/account-ratio?category=linear&symbol=${SYM}USDT&period=1h&limit=1"
        $x = "• Bybit: interés abierto {0} USD · funding {1:N4}% por 8h" -f (Fm ([double]$e.openInterestValue)), ([double]$e.fundingRate * 100)
        if ($ar -and $ar.result.list) { $x += " · cuentas: {0:N0}% largos / {1:N0}% cortos" -f (100 * [double]$ar.result.list[0].buyRatio), (100 * [double]$ar.result.list[0].sellRatio) }
        $rows += $x
    }
    $ok = Plat-Get "OKX" "https://www.okx.com/api/v5/public/open-interest?instType=SWAP&instId=${SYM}-USDT-SWAP"
    if ($ok -and $ok.code -eq "0" -and $ok.data) {
        $fr = Plat-Get "OKX" "https://www.okx.com/api/v5/public/funding-rate?instId=${SYM}-USDT-SWAP"
        $ls = Plat-Get "OKX" "https://www.okx.com/api/v5/rubik/stat/contracts/long-short-account-ratio?ccy=${SYM}&period=1H"
        $x = "• OKX: interés abierto {0} USD" -f (Fm ([double]$ok.data[0].oiUsd))
        if ($fr -and $fr.data) { $x += " · funding {0:N4}% por 8h" -f ([double]$fr.data[0].fundingRate * 100) }
        if ($ls -and $ls.data -and $ls.data.Count) { $rt = [double]$ls.data[0][1]; $x += " · cuentas: {0:N0}% largos / {1:N0}% cortos" -f (100 * $rt / (1 + $rt)), (100 / (1 + $rt)) }
        $rows += $x
    }
    try { $rows += @(Get-DerivBackupRows $SYM) } catch {}
    $L += "⚖️ POSICIONAMIENTO EN DERIVADOS (otras plataformas)"
    if ($rows.Count -eq 0) { $L += "• Sin datos: el activo no cotiza en Binance/Bybit/OKX o no respondieron."; return $L }
    $L += $rows
    $L += "  (Lectura: mucha mayoría en un solo lado + funding extremo suele preceder barridos de liquidez contra esa mayoría; es un contexto, no una señal por sí sola.)"
    return $L
}

# ---------- Cripto: fundamentales (CoinGecko) y sentimiento ----------
function Get-CryptoFundSection($SYM) {
    $L = @(); $L += "🪙 FUNDAMENTALES DE LA CRIPTO (CoinGecko)"
    $sr = Plat-Get "CoinGecko" "https://api.coingecko.com/api/v3/search?query=$SYM"
    $c = $null; if ($sr) { $c = @($sr.coins | Where-Object { $_.symbol -eq $SYM.ToUpper() -and $_.market_cap_rank } | Sort-Object market_cap_rank) | Select-Object -First 1 }
    if ($c) {
        $m = Plat-Get "CoinGecko" "https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&ids=$($c.id)"
        if ($m) {
            $d = @($m)[0]
            $L += ("• Ranking #{0} · capitalización {1} USD · volumen 24h {2} USD ({3:N1}% de la capitalización)" -f $d.market_cap_rank, (Fm $d.market_cap), (Fm $d.total_volume), (100 * $d.total_volume / [Math]::Max(1.0, [double]$d.market_cap)))
            $sup = "• Suministro circulante {0:N0}" -f $d.circulating_supply
            if ($d.max_supply) { $sup += " de un máximo de {0:N0} ({1:N0}% emitido)" -f $d.max_supply, (100 * $d.circulating_supply / $d.max_supply) } else { $sup += " (sin máximo fijado)" }
            if ($d.fully_diluted_valuation) { $sup += " · valoración totalmente diluida {0} USD" -f (Fm $d.fully_diluted_valuation) }
            $L += $sup
            $L += ("• Máximo histórico {0} USD ({1:N0}% desde entonces) · mínimo histórico {2} USD" -f (Fnum $d.ath), $d.ath_change_percentage, (Fnum $d.atl))
        } else { $L += "• CoinGecko no devolvió datos de mercado ahora." }
    } else { $L += "• No he podido identificar la moneda en CoinGecko con certeza." }
    return $L
}

# ---------- BTC: transferencias grandes pendientes en la red (mempool) ----------
function Get-BtcOnchainSection($px) {
    $L = @(); $L += "⛓️ BTC EN LA RED (transacciones grandes sin confirmar, blockchain.com)"
    $r = Plat-Get "Blockchain.com" "https://blockchain.info/unconfirmed-transactions?format=json" 30
    if (-not $r -or -not $r.txs) { $L += "• Sin datos ahora."; return $L }
    $big = @($r.txs | ForEach-Object { $v = ($_.out | Measure-Object value -Sum).Sum / 1e8; [pscustomobject]@{ btc = $v; usd = $v * $px; hash = $_.hash } } | Where-Object { $_.usd -ge 1e6 } | Sort-Object usd -Descending)
    if ($big.Count -eq 0) { $L += ("• Ninguna de las {0} transacciones pendientes ahora supera 1 M USD." -f $r.txs.Count) }
    else { $L += ("• {0} transacciones pendientes con más de 1 M USD de salidas (de {1} revisadas). Mayores: {2}" -f $big.Count, $r.txs.Count, (($big | Select-Object -First 3 | % { "{0:N0} BTC (~{1} USD)" -f $_.btc, (Fm $_.usd) }) -join " · ")) }
    $L += "  (Es una foto del momento, incluye el cambio que el emisor se devuelve a sí mismo y no indica si va a un exchange: no es por sí mismo señal de compra ni de venta.)"
    return $L
}

# ---------- Acciones: instituciones, short interest, analistas, resultados (Yahoo) ----------
function Get-StockInstSection($tkr) {
    $L = @(); $L += "🏦 INSTITUCIONES, ANALISTAS Y SHORT (Yahoo Finance)"
    if (-not (Get-YahooSession)) { $L += "• Yahoo no dio sesión ahora mismo. No lo invento."; return $L }
    try {
        $u = "https://query2.finance.yahoo.com/v10/finance/quoteSummary/" + [uri]::EscapeDataString($tkr) + "?modules=majorHoldersBreakdown,institutionOwnership,defaultKeyStatistics,recommendationTrend,upgradeDowngradeHistory,calendarEvents&crumb=" + [uri]::EscapeDataString($script:YCrumb)
        $q = (Invoke-RestMethod $u -WebSession $script:YSess -Headers $script:BrowserUA -TimeoutSec 25).quoteSummary.result[0]
        if ($script:PlatOK -notcontains "Yahoo Finance") { $script:PlatOK += "Yahoo Finance" }
    } catch { $L += "• Yahoo no devolvió estos módulos para $tkr."; return $L }
    $mh = $q.majorHoldersBreakdown
    if ($mh -and $mh.institutionsPercentHeld) { $L += ("• Propiedad: instituciones {0:N1}% de las acciones ({1:N0} instituciones) · insiders {2:N1}%" -f (100 * $mh.institutionsPercentHeld.raw), $mh.institutionsCount.raw, (100 * $mh.insidersPercentHeld.raw)) }
    $io = @($q.institutionOwnership.ownershipList | Select-Object -First 5)
    if ($io.Count) {
        $L += "• Mayores fondos y su variación en el último trimestre declarado (formularios 13F, con retraso de hasta 45 días):"
        foreach ($h in $io) { $L += ("   - {0}: {1:N2}% del capital · {2} USD · cambio de posición {3:+0.0;-0.0}% (a {4})" -f $h.organization, (100 * $h.pctHeld.raw), (Fm $h.value.raw), (100 * $h.pctChange.raw), $h.reportDate.fmt) }
    }
    $ks = $q.defaultKeyStatistics
    if ($ks -and $ks.shortPercentOfFloat.raw) { $L += ("• Posición corta (short interest): {0:N1}% del capital flotante · {1} acciones · {2:N1} días para cubrir (dato a {3})" -f (100 * $ks.shortPercentOfFloat.raw), (Fm $ks.sharesShort.raw), $ks.shortRatio.raw, $ks.dateShortInterest.fmt) }
    $rt = $q.recommendationTrend.trend | Select-Object -First 1
    if ($rt) { $L += ("• Recomendaciones de analistas este mes: {0} compra fuerte · {1} compra · {2} mantener · {3} venta · {4} venta fuerte" -f $rt.strongBuy, $rt.buy, $rt.hold, $rt.sell, $rt.strongSell) }
    $ud = @($q.upgradeDowngradeHistory.history | Select-Object -First 5)
    if ($ud.Count) { $L += "• Últimas revisiones: " + (($ud | % { "{0:yyyy-MM-dd} {1} ({2})" -f [datetimeoffset]::FromUnixTimeSeconds([long]$_.epochGradeDate).UtcDateTime, $_.firm, $(if ($_.fromGrade) { "$($_.fromGrade) → $($_.toGrade)" } else { "$($_.action) $($_.toGrade)" }) }) -join " · ") }
    $ed = $q.calendarEvents.earnings.earningsDate | Select-Object -First 1
    if ($ed) { $L += ("• Próximos resultados trimestrales (estimado por Yahoo): {0}" -f $ed.fmt) }
    if ($L.Count -le 1) { $L += "• Yahoo no tiene estos datos para este valor." }
    return $L
}

# ---------- Sección completa que se añade al informe ----------
function Build-Plataformas($s) {
    $script:PlatOK = @(); $script:PlatFail = @(); $L = @(); $sym = "$($s.sym)".ToUpper()
    $isCrypto = ($s.src -eq 'gecko' -or $s.src -eq 'bitunix' -or $s.kind -like '*cripto*')
    $sent = Get-MarketSentiment $isCrypto; if ($sent) { $L += "🌡️ " + $sent; $L += "" }
    if ($s.src -in 'bitunix', 'gecko' -and $s.kind -like '*cripto*' -or $s.src -eq 'gecko' -or ($s.src -eq 'bitunix' -and $s.kind -like '*futuro*')) {
        try { $L += Get-WhaleSection $sym } catch { $L += "🐋 BALLENAS: error al consultar las plataformas; no lo invento." }; $L += ""
        try { $L += Get-DerivSection $sym } catch { $L += "⚖️ DERIVADOS: error al consultar las plataformas." }; $L += ""
        try { $L += Get-CryptoFundSection $sym } catch { $L += "🪙 FUNDAMENTALES: error al consultar CoinGecko." }
        if ($sym -eq 'BTC') { $L += ""; try { $L += Get-BtcOnchainSection $s.price } catch { $L += "⛓️ BTC EN LA RED: sin datos." } }
    }
    elseif ($s.src -eq 'yahoo' -and $s.kind -in 'acción', 'ETF') {
        $L += Get-StockInstSection $sym
        $L += ""; $L += "🐋 BALLENAS EN BOLSA: los bloques y dark pools no son públicos al instante; lo verificable son los 13F de fondos (arriba, con retraso) y los formularios 4 de insiders."
    }
    if ($script:PlatOK.Count -or $script:PlatFail.Count) {
        $L += ""; $L += ("🔌 Plataformas consultadas: " + ((@($script:PlatOK | % { "$_ ✅" }) + @($script:PlatFail | % { "$_ ❌ (sin respuesta)" })) -join " · "))
    }
    return $L
}

# ---------- Sentimiento general de mercado (FOMO / FUD) ----------
function Get-SentimentLabel([double]$v) {
    if ($v -ge 75) { return "FOMO extremo (codicia extrema)" } elseif ($v -ge 56) { return "FOMO (codicia)" } elseif ($v -ge 45) { return "neutral" } elseif ($v -ge 25) { return "FUD (miedo)" } else { return "FUD extremo (miedo extremo)" }
}
function Get-MarketSentiment([bool]$crypto) {                  # devuelve una línea de texto o $null; caché 30 min
    $key = if ($crypto) { "c" } else { "s" }
    if (-not $script:SentCache) { $script:SentCache = @{} }
    if ($script:SentCache[$key] -and ((Get-Date) - $script:SentCache[$key].at).TotalMinutes -lt 30) { return $script:SentCache[$key].txt }
    $txt = $null
    if ($crypto) {
        $fg = Plat-Get "Alternative.me" "https://api.alternative.me/fng/?limit=8"
        if ($fg -and $fg.data) {
            $v = [double]$fg.data[0].value; $w = [double]$fg.data[-1].value
            $txt = ("Sentimiento del mercado cripto: {0:N0}/100 · {1} (ayer {2} · hace una semana {3:N0}). Índice Crypto Fear & Greed (Alternative.me)." -f $v, (Get-SentimentLabel $v), $fg.data[1].value, $w)
            if ($v -ge 75) { $txt += " Con codicia extrema los largos tardíos son los más vulnerables a correcciones." } elseif ($v -le 25) { $txt += " Con miedo extremo suele haber pánico vendedor; históricamente ha coincidido a menudo con zonas de suelo, sin garantía." }
        }
    } else {
        try {
            $H = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'; 'Accept' = 'application/json'; 'Referer' = 'https://edition.cnn.com/markets/fear-and-greed'; 'Origin' = 'https://edition.cnn.com' }
            $c = Invoke-RestMethod ("https://production.dataviz.cnn.io/index/fearandgreed/graphdata/" + (Get-Date).AddDays(-8).ToString("yyyy-MM-dd")) -Headers $H -TimeoutSec 20
            $v = [double]$c.fear_and_greed.score; $pw = [double]$c.fear_and_greed.previous_1_week
            $txt = ("Sentimiento de la bolsa de EE. UU.: {0:N0}/100 · {1} (hace una semana {2:N0}). Índice Fear & Greed de CNN." -f $v, (Get-SentimentLabel $v), $pw)
        } catch {}
        if (-not $txt) {
            try {
                $vx = [double](Invoke-RestMethod "https://query1.finance.yahoo.com/v8/finance/chart/%5EVIX?range=5d&interval=1d" -Headers @{ 'User-Agent' = 'Mozilla/5.0' } -TimeoutSec 15).chart.result[0].meta.regularMarketPrice
                $lab = if ($vx -lt 15) { "complacencia (tipo FOMO)" } elseif ($vx -lt 20) { "normal" } elseif ($vx -lt 30) { "nerviosismo (tipo FUD)" } else { "pánico (FUD extremo)" }
                $txt = ("Sentimiento de la bolsa de EE. UU. (el índice de CNN no respondió; uso el VIX): VIX {0:N1} · {1}." -f $vx, $lab)
            } catch {}
        }
    }
    $script:SentCache[$key] = @{ txt = $txt; at = Get-Date }
    return $txt
}

# ---------- Respaldo para futuros: plataformas que no bloquean los servidores de EE. UU. (Gate.io, Bitget, Deribit, Kraken Futures, Hyperliquid) ----------
function New-Venue($name, $rows) {
    $rows = @($rows | Where-Object { $_ }); if ($rows.Count -eq 0) { return $null }
    return @{ venue = $name; rows = $rows; first = ($rows | Measure-Object ts -Minimum).Minimum; last = ($rows | Measure-Object ts -Maximum).Maximum }
}
function Get-GateTrades($sym) {                                 # size>0: agresión compradora; contratos x multiplicador = monedas
    $c = Plat-Get "Gate.io" "https://api.gateio.ws/api/v4/futures/usdt/contracts/${sym}_USDT"
    if (-not $c -or -not $c.quanto_multiplier) { return $null }
    $mult = [double]$c.quanto_multiplier
    $r = Plat-Get "Gate.io" "https://api.gateio.ws/api/v4/futures/usdt/trades?contract=${sym}_USDT&limit=1000"
    if (-not $r) { return $null }
    $rows = @($r) | ForEach-Object { [pscustomobject]@{ ts = [long]([double]$_.create_time_ms * 1000); side = $(if ([double]$_.size -gt 0) { "COMPRA" } else { "VENTA" }); px = [double]$_.price; usd = [Math]::Abs([double]$_.size) * $mult * [double]$_.price; venue = "Gate.io Futuros" } }
    return (New-Venue "Gate.io Futuros" $rows)
}
function Get-DeribitPerpTrades($sym) {                          # perpetuo inverso: amount ya viene en USD
    if ($sym -notin 'BTC', 'ETH') { return $null }
    $r = Plat-Get "Deribit" "https://www.deribit.com/api/v2/public/get_last_trades_by_instrument?instrument_name=$sym-PERPETUAL&count=1000"
    if (-not $r -or -not $r.result.trades) { return $null }
    $rows = @($r.result.trades) | ForEach-Object { [pscustomobject]@{ ts = [long]$_.timestamp; side = $(if ($_.direction -eq "buy") { "COMPRA" } else { "VENTA" }); px = [double]$_.price; usd = [double]$_.amount; venue = "Deribit Perpetuo" } }
    return (New-Venue "Deribit Perpetuo" $rows)
}
function Get-BitgetTrades($sym) {
    $r = Plat-Get "Bitget" "https://api.bitget.com/api/v2/mix/market/fills?symbol=${sym}USDT&productType=USDT-FUTURES&limit=100"
    if (-not $r -or $r.code -ne "00000" -or -not $r.data) { return $null }
    $rows = @($r.data) | ForEach-Object { [pscustomobject]@{ ts = [long]$_.ts; side = $(if ($_.side -eq "buy") { "COMPRA" } else { "VENTA" }); px = [double]$_.price; usd = [double]$_.price * [double]$_.size; venue = "Bitget Futuros" } }
    return (New-Venue "Bitget Futuros" $rows)
}
function Get-KrakenFutTrades($sym) {
    $m = if ($sym -eq 'BTC') { 'XBT' } else { $sym }
    $r = Plat-Get "Kraken Futures" "https://futures.kraken.com/derivatives/api/v3/history?symbol=PF_${m}USD"
    if (-not $r -or $r.result -ne "success" -or -not $r.history) { return $null }
    $rows = @($r.history) | ForEach-Object { [pscustomobject]@{ ts = [datetimeoffset]::Parse($_.time, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds(); side = $(if ($_.side -eq "buy") { "COMPRA" } else { "VENTA" }); px = [double]$_.price; usd = [double]$_.price * [double]$_.size; venue = "Kraken Futuros" } }
    return (New-Venue "Kraken Futuros" $rows)
}
function Get-HyperliquidCtx($sym) {                             # interés abierto y funding (Hyperliquid cobra el funding cada hora)
    try {
        if (-not $script:HLCtx -or ((Get-Date) - $script:HLCtxAt).TotalSeconds -gt 90) {
            $script:HLCtx = Invoke-RestMethod -Uri "https://api.hyperliquid.xyz/info" -Method Post -ContentType "application/json" -Body '{"type":"metaAndAssetCtxs"}' -Headers $script:PUA -TimeoutSec 20; $script:HLCtxAt = Get-Date
        }
        $names = @($script:HLCtx[0].universe | ForEach-Object { $_.name })
        $i = [array]::IndexOf($names, $sym); if ($i -lt 0) { $i = [array]::IndexOf($names, "k$sym") }
        if ($i -lt 0) { return $null }
        if ("Hyperliquid" -notin $script:PlatOK) { $script:PlatOK += "Hyperliquid" }
        $c = $script:HLCtx[1][$i]
        return @{ oiUsd = [double]$c.openInterest * [double]$c.markPx; fund8h = [double]$c.funding * 8 * 100 }
    } catch { if ("Hyperliquid" -notin $script:PlatFail -and "Hyperliquid" -notin $script:PlatOK) { $script:PlatFail += "Hyperliquid" }; return $null }
}
function Get-DerivBackupRows($SYM) {
    $rows = @()
    $c = Plat-Get "Gate.io" "https://api.gateio.ws/api/v4/futures/usdt/contracts/${SYM}_USDT"
    $st = Plat-Get "Gate.io" "https://api.gateio.ws/api/v4/futures/usdt/contract_stats?contract=${SYM}_USDT&interval=1h&limit=2"
    if ($c -and $st) {
        $s = @($st | Sort-Object time)[-1]; $lsr = [double]$s.lsr_account; $top = [double]$s.top_lsr_size
        $x = "• Gate.io: interés abierto {0} USD · funding {1:N4}% por 8h · cuentas: {2:N0}% largos / {3:N0}% cortos · grandes traders (tamaño): {4:N0}% largos / {5:N0}% cortos" -f (Fm ([double]$s.open_interest_usd)), ([double]$c.funding_rate * 100), (100 * $lsr / (1 + $lsr)), (100 / (1 + $lsr)), (100 * $top / (1 + $top)), (100 / (1 + $top))
        $ll = [double]$s.long_liq_usd; $sl2 = [double]$s.short_liq_usd
        if ($ll + $sl2 -gt 0) { $x += " · liquidaciones en la última hora: largos {0} USD / cortos {1} USD" -f (Fm $ll), (Fm $sl2) }
        $rows += $x
    }
    $bo = Plat-Get "Bitget" "https://api.bitget.com/api/v2/mix/market/open-interest?symbol=${SYM}USDT&productType=USDT-FUTURES"
    $bl = Plat-Get "Bitget" "https://api.bitget.com/api/v2/mix/market/account-long-short?symbol=${SYM}USDT&period=1h"
    $bf = Plat-Get "Bitget" "https://api.bitget.com/api/v2/mix/market/current-fund-rate?symbol=${SYM}USDT&productType=USDT-FUTURES"
    if ($bo -and $bo.code -eq "00000" -and $bo.data.openInterestList) {
        $x = "• Bitget: interés abierto {0:N0} {1}" -f [double]$bo.data.openInterestList[0].size, $SYM
        if ($bf -and $bf.data) { $x += " · funding {0:N4}% por 8h" -f ([double]$bf.data[0].fundingRate * 100) }
        if ($bl -and $bl.data) { $l1 = @($bl.data | Sort-Object { [long]$_.ts })[-1]; $x += " · cuentas: {0:N0}% largos / {1:N0}% cortos" -f (100 * [double]$l1.longAccountRatio), (100 * [double]$l1.shortAccountRatio) }
        $rows += $x
    }
    $hl = Get-HyperliquidCtx $SYM
    if ($hl) { $rows += ("• Hyperliquid (DEX): interés abierto {0} USD · funding {1:N4}% por 8h equivalente" -f (Fm $hl.oiUsd), $hl.fund8h) }
    return $rows
}