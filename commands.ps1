# Comandos del bot de Telegram: informes técnicos bajo demanda de cualquier cripto o acción.
# Regla de oro: solo cifras calculadas a partir de datos de mercado reales y citando la fuente. Lo que no se puede obtener, se dice.
# Fuentes: Bitunix (futuros cripto, API pública), Yahoo Finance (cotizaciones de bolsa), CoinGecko (otras criptos).
try { [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo("es-ES") } catch {}   # formato español también en la nube (2.664,24)
$script:CmdBase = "https://fapi.bitunix.com/api/v1/futures/market"
$script:LastCmd = @{}
$script:UA = @{ 'User-Agent' = 'Mozilla/5.0 (compatible; AlertasBitunix/1.0)' }

function Fnum($x) {
    if ($null -eq $x) { return "n/d" }
    $a = [Math]::Abs($x)
    if ($a -ge 1000) { return ("{0:N0}" -f $x) } elseif ($a -ge 1) { return ("{0:N2}" -f $x) } elseif ($a -ge 0.01) { return ("{0:N4}" -f $x) } else { return $x.ToString("0.00000000").TrimEnd('0') }
}
function Fpct($x) { if ($null -eq $x) { return "n/d" } else { return ("{0:+0.0;-0.0;0.0}%" -f $x) } }
function Ema-Of($v, $n) { $k = 2.0 / ($n + 1); $e = $v[0]; for ($i = 1; $i -lt $v.Count; $i++) { $e = $v[$i] * $k + $e * (1 - $k) }; return $e }
function Rsi-Of($c, $n = 14) {
    if ($c.Count -le $n + 1) { return $null }
    $g = 0.0; $l = 0.0
    for ($i = 1; $i -le $n; $i++) { $d = $c[$i] - $c[$i-1]; if ($d -gt 0) { $g += $d } else { $l -= $d } }
    $g /= $n; $l /= $n
    for ($i = $n + 1; $i -lt $c.Count; $i++) { $d = $c[$i] - $c[$i-1]; $g = ($g * ($n - 1) + [Math]::Max($d, 0)) / $n; $l = ($l * ($n - 1) + [Math]::Max(-$d, 0)) / $n }
    if ($l -eq 0) { return 100 }; return 100 - 100 / (1 + $g / $l)
}

# ---------- Fuentes de datos ----------
function Get-BitunixSeries($sym) {
    $tk = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "${sym}USDT"
    if (-not $tk) { return $null }
    $all = @{}; $end = $null
    for ($p = 0; $p -lt 3; $p++) {
        $u = "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1d&limit=200"; if ($end) { $u += "&endTime=$end" }
        $d = (Invoke-RestMethod $u).data; if (-not $d) { break }
        $mn = [long]::MaxValue; foreach ($c in $d) { $all[[string]$c.time] = $c; if ([long]$c.time -lt $mn) { $mn = [long]$c.time } }; $end = $mn - 1
    }
    $s = @($all.Values | Sort-Object { [long]$_.time }); $s = @($s[0..($s.Count - 2)])        # sin la vela en curso
    if ($s.Count -lt 30) { return $null }
    $fund = ((Invoke-RestMethod "$($script:CmdBase)/funding_rate/batch").data | Where-Object symbol -eq "${sym}USDT").fundingRate
    $bk = (Invoke-RestMethod "$($script:CmdBase)/depth?symbol=${sym}USDT&limit=50").data
    $bv = ($bk.bids | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum; $av = ($bk.asks | ForEach-Object { [double]$_[0] * [double]$_[1] } | Measure-Object -Sum).Sum
    return @{
        src = 'bitunix'; sym = $sym; kind = "futuro perpetuo de Bitunix (cripto o activo tokenizado)"; name = "${sym}/USDT"; source = "Bitunix (API pública de futuros)"; currency = "USDT"
        price = [double]$tk.lastPrice; priceNote = "precio en vivo"
        c = @($s | ForEach-Object { [double]$_.close }); h = @($s | ForEach-Object { [double]$_.high }); l = @($s | ForEach-Object { [double]$_.low }); v = @($s | ForEach-Object { [double]$_.quoteVol })
        lastDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$s[-1].time).UtcDateTime.AddDays(1).ToString("yyyy-MM-dd")
        extra = @{ vol24 = [double]$tk.quoteVol; funding = [double]$fund; bookBuy = if (($av + $bv) -gt 0) { 100 * $bv / ($av + $bv) } else { $null } }
    }
}
function Get-YahooSeries($tkr) {
    try { $r = Invoke-RestMethod -Uri ("https://query1.finance.yahoo.com/v8/finance/chart/" + [uri]::EscapeDataString($tkr) + "?range=2y&interval=1d") -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $res = $r.chart.result; if (-not $res) { return $null }
    $res = $res[0]; $m = $res.meta; $q = $res.indicators.quote[0]; $ts = $res.timestamp
    if (-not $ts -or $ts.Count -lt 30) { return $null }
    $rows = for ($i = 0; $i -lt $ts.Count; $i++) { if ($null -ne $q.close[$i]) { [pscustomobject]@{ t = $ts[$i]; c = [double]$q.close[$i]; h = [double]$q.high[$i]; l = [double]$q.low[$i]; v = $(if ($null -ne $q.volume[$i]) { [double]$q.volume[$i] } else { 0.0 }) } } }
    $rows = @($rows); if ($rows.Count -lt 30) { return $null }
    $kind = switch ($m.instrumentType) { "EQUITY" { "acción" } "ETF" { "ETF" } "CRYPTOCURRENCY" { "cripto" } "INDEX" { "índice" } default { "valor ($($m.instrumentType))" } }
    $name = if ($m.longName) { "$($m.longName) ($($m.symbol))" } elseif ($m.shortName) { "$($m.shortName) ($($m.symbol))" } else { $m.symbol }
    return @{
        src = 'yahoo'; exch = "$($m.fullExchangeName)"; sym = $tkr; kind = $kind; name = $name; source = "Yahoo Finance ($($m.fullExchangeName); puede llevar retraso)"; currency = $m.currency
        price = [double]$m.regularMarketPrice; priceNote = "último precio de mercado"
        c = @($rows | % { $_.c }); h = @($rows | % { $_.h }); l = @($rows | % { $_.l }); v = @($rows | % { $_.v })
        lastDate = [DateTimeOffset]::FromUnixTimeSeconds([long]$m.regularMarketTime).UtcDateTime.ToString("yyyy-MM-dd HH:mm") + " UTC"
        extra = @{ hi52 = $m.fiftyTwoWeekHigh; lo52 = $m.fiftyTwoWeekLow }
    }
}
function Get-GeckoSeries($q) {
    try { $s = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($q))" -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $cand = @($s.coins | Where-Object { $_.symbol -eq $q.ToUpper() } | Sort-Object { if ($_.market_cap_rank) { [int]$_.market_cap_rank } else { 999999 } })
    if ($cand.Count -eq 0) { return $null }
    $coin = $cand[0]
    try { $d = Invoke-RestMethod "https://api.coingecko.com/api/v3/coins/$($coin.id)/market_chart?vs_currency=usd&days=365&interval=daily" -Headers $script:UA -TimeoutSec 25 } catch { return $null }
    $pr = @($d.prices | ForEach-Object { [double]$_[1] }); $vo = @($d.total_volumes | ForEach-Object { [double]$_[1] })
    if ($pr.Count -lt 30) { return $null }
    $pr = @($pr[0..($pr.Count - 2)]) ; $vo = @($vo[0..($vo.Count - 2)])                       # el último punto es del día en curso
    return @{
        src = 'gecko'; id = $coin.id; sym = $coin.symbol; kind = "cripto (sin par directo en Bitunix con este símbolo)"; name = "$($coin.name) ($($coin.symbol))"; source = "CoinGecko (precios diarios agregados)"; currency = "USD"
        price = $pr[-1]; priceNote = "último cierre diario"; c = $pr; h = $null; l = $null; v = $vo
        lastDate = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$d.prices[-2][0]).UtcDateTime.ToString("yyyy-MM-dd"); extra = @{ rank = $coin.market_cap_rank }
    }
}

# ---------- Informe ----------
function Build-Report($s) {
    $c = $s.c; $n = $c.Count; $px = $s.price
    $ret = { param($d) if ($n -gt $d) { ($px / $c[$n - 1 - $d] - 1) * 100 } else { $null } }
    $r1 = & $ret 1; $r7 = & $ret 7; $r30 = & $ret 30; $r90 = & $ret 90; $r365 = & $ret 364
    $win = [Math]::Min($n, 252); $seg = $c[($n - $win)..($n - 1)]
    $hi52 = if ($s.extra.hi52) { [double]$s.extra.hi52 } else { ($seg | Measure-Object -Maximum).Maximum }
    $lo52 = if ($s.extra.lo52) { [double]$s.extra.lo52 } else { ($seg | Measure-Object -Minimum).Minimum }
    $e21 = Ema-Of $c 21; $e50 = Ema-Of $c 50; $e200 = if ($n -ge 200) { Ema-Of $c 200 } else { $null }
    $rsi = Rsi-Of $c
    $tr = if ($px -gt $e21 -and $e21 -gt $e50) { "alcista" } elseif ($px -lt $e21 -and $e21 -lt $e50) { "bajista" } else { "mixta/lateral" }
    $rets = for ($i = [Math]::Max(1, $n - 30); $i -lt $n; $i++) { [Math]::Log($c[$i] / $c[$i-1]) }
    $mean = ($rets | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($rets | % { ($_ - $mean) * ($_ - $mean) } | Measure-Object -Sum).Sum) / ([Math]::Max(1, $rets.Count - 1)))
    $annual = $sd * [Math]::Sqrt(365) * 100
    $atr = $null; if ($s.h) { $sum = 0.0; for ($i = $n - 14; $i -lt $n; $i++) { $sum += [Math]::Max($s.h[$i] - $s.l[$i], [Math]::Max([Math]::Abs($s.h[$i] - $c[$i-1]), [Math]::Abs($s.l[$i] - $c[$i-1]))) }; $atr = $sum / 14 / $c[-1] * 100 }
    # pivotes (máximos/mínimos locales de 5 velas a cada lado)
    $hs = if ($s.h) { $s.h } else { $c }; $ls = if ($s.l) { $s.l } else { $c }; $res = @(); $sup = @()
    for ($i = $n - 200; $i -lt $n - 5; $i++) { if ($i -lt 5) { continue }; $isH = $true; $isL = $true; for ($j = $i - 5; $j -le $i + 5; $j++) { if ($hs[$j] -gt $hs[$i]) { $isH = $false }; if ($ls[$j] -lt $ls[$i]) { $isL = $false } }; if ($isH -and $hs[$i] -gt $px) { $res += $hs[$i] }; if ($isL -and $ls[$i] -lt $px) { $sup += $ls[$i] } }
    $res = @($res | Sort-Object | Select-Object -First 3); $sup = @($sup | Sort-Object -Descending | Select-Object -First 3)
    $vtxt = ""
    if ($s.v -and ($s.v | Measure-Object -Sum).Sum -gt 0 -and $n -ge 22) { $vr = $s.v[-1] / (($s.v[($n-21)..($n-2)] | Measure-Object -Average).Average); $vtxt = "Volumen de la última sesión: x{0:N1} la media de 20 sesiones." -f $vr }
    $L = @()
    $L += "📊 INFORME · $($s.name)"
    $L += "Tipo: $($s.kind) | Fuente: $($s.source)"
    $L += "Datos hasta: $($s.lastDate) ($($s.priceNote))"
    $L += ""
    $L += ("💵 Precio: {0} {1}" -f (Fnum $px), $s.currency)
    $L += ("Rentabilidad: 1d {0} · 7d {1} · 30d {2} · 90d {3} · 1 año {4}" -f (Fpct $r1), (Fpct $r7), (Fpct $r30), (Fpct $r90), (Fpct $r365))
    $rl = if ($n -ge 252 -or $s.extra.hi52) { "Rango de 52 semanas" } else { "Rango del historial disponible ($n días; el activo tiene menos de 1 año de datos)" }
    $L += ("{0}: {1} - {2} (a {3:N0}% del máximo; {4} sobre el mínimo)" -f $rl, (Fnum $lo52), (Fnum $hi52), ($px / $hi52 * 100), (Fpct (($px / $lo52 - 1) * 100)))
    $L += ""
    $L += "📈 TENDENCIA (diaria): $tr"
    $m = "Medias: EMA21 {0} · EMA50 {1}" -f (Fnum $e21), (Fnum $e50); if ($e200) { $m += " · EMA200 {0} (precio {1} la EMA200)" -f (Fnum $e200), $(if ($px -gt $e200) { "SOBRE" } else { "BAJO" }) } else { $m += " · EMA200 no calculable (historial corto)" }
    $L += $m
    if ($rsi) { $rt = if ($rsi -ge 70) { "sobrecompra" } elseif ($rsi -ge 65) { "cerca de sobrecompra" } elseif ($rsi -le 30) { "sobreventa" } elseif ($rsi -le 35) { "cerca de sobreventa" } else { "zona neutra" }; $L += ("RSI(14) diario: {0:N0} ({1})" -f $rsi, $rt) }
    $v = ("Volatilidad: desviación anualizada {0:N0}% (30 sesiones)" -f $annual); if ($atr) { $v += (" · ATR diario {0:N1}%" -f $atr) }; $L += $v
    if ($res.Count) { $L += "Resistencias cercanas (máximos locales): " + (($res | % { Fnum $_ }) -join " · ") }
    if ($sup.Count) { $L += "Soportes cercanos (mínimos locales): " + (($sup | % { Fnum $_ }) -join " · ") }
    if ($vtxt) { $L += $vtxt }
    if ($s.extra.funding -ne $null) { $vv = if ($s.extra.vol24 -ge 1e6) { "{0:N1} M USDT" -f ($s.extra.vol24 / 1e6) } else { "{0:N0} USDT" -f $s.extra.vol24 }
    $L += ("⚖️ Derivados Bitunix: funding {0:N4}% por 8h · volumen 24h {1} · libro de órdenes {2:N0}% compradores" -f $s.extra.funding, $vv, $s.extra.bookBuy) }
    if ($s.extra.rank) { $L += "Ranking por capitalización (CoinGecko): #$($s.extra.rank)" }
    $L += ""
    $L += "Es información técnica calculada con datos públicos; no es asesoramiento ni garantía."
    return ($L -join "`n")
}

function Resolve-Report($raw, $mode) {
    $rsR = Resolve-SymbolText $raw; $raw = $rsR.sym; $symNote = $rsR.note
    $q = ($raw -replace '[^A-Za-z0-9.\-\^=]', '').ToUpper()
    if (-not $q -or $q.Length -gt 15) { return "No he entendido el símbolo. Ejemplos: /informe BTC · /informe ETH · /informe AAPL · /informe IREN · /informe SAN.MC" }
    $s = $null; $note = ""; $base = $q -replace 'USDT$', ''
    # ¿es una cripto conocida? (CoinGecko: coincidencia exacta de símbolo y capitalización entre las 300 primeras)
    $isCrypto = $false
    if ($mode -eq "cripto" -or $q -like '*USDT') { $isCrypto = $true }
    elseif ($mode -ne "accion") {
        try { $g = Invoke-RestMethod "https://api.coingecko.com/api/v3/search?query=$([uri]::EscapeDataString($base))" -Headers $script:UA -TimeoutSec 20
              $hit = @($g.coins | Where-Object { $_.symbol -eq $base -and $_.market_cap_rank -and [int]$_.market_cap_rank -le 300 }); if ($hit.Count) { $isCrypto = $true } } catch {}
    }
    if ($isCrypto) {
        try { $s = Get-BitunixSeries $base } catch {}
        if (-not $s) { try { $s = Get-GeckoSeries $base } catch {} }
        if (-not $s -and $mode -ne "cripto") { try { $s = Get-YahooSeries $q } catch {} }
    } else {
        try { $s = Get-YahooSeries $q } catch {}
        if ($s) { try { $bx = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "${base}USDT"; if ($bx) { $note = "ℹ️ Además, en Bitunix existe el futuro perpetuo ${base}/USDT (precio {0} USDT, en vivo)." -f (Fnum ([double]$bx.lastPrice)) } } catch {} }
        if (-not $s -and $mode -ne "accion") { try { $s = Get-BitunixSeries $base } catch {} }
        if (-not $s -and $mode -ne "accion") { try { $s = Get-GeckoSeries $base } catch {} }
    }
    if (-not $s -and -not $script:InSearch) { $rs2 = Resolve-SymbolText $q -Force; if ($rs2.sym -and $rs2.sym -ne $q) { $script:InSearch = $true; try { $r2 = Resolve-Report $rs2.sym $mode } finally { $script:InSearch = $false }; return ($(if ($rs2.note) { $rs2.note + "`n`n" } else { "" }) + $r2) } }
    if (-not $s) { return "No he podido obtener datos fiables de '$q'. Prueba con el símbolo bursátil exacto (AAPL, MSFT, IREN, SAN.MC para España) o el ticker de la cripto (BTC, SOL). Si el símbolo es correcto, puede que la fuente esté caída: inténtalo más tarde. No voy a inventar datos." }
    try { $rep = Build-Report $s; if ($symNote) { $rep = $symNote + "`n`n" + $rep }; if ($note) { $rep += "`n" + $note }; try { $rep += "`n`n" + (Build-Extra $s) } catch { $rep += "`n`n(Las secciones de objetivos, insiders, opciones y volumen no se han podido generar ahora; no envío datos dudosos.)" }; try { $rep += "`n`n" + (Get-FundamentalsSection $s) } catch { $rep += "`n`n(La sección de resultados y fundamentales no se ha podido generar ahora.)" }; try { $rep += "`n`n" + (Get-NewsSection $s.sym $s.name ($s.src -ne 'yahoo')) } catch { $rep += "`n`n(La sección de noticias no se ha podido generar ahora.)" }; return $rep } catch { return "Tengo datos de '$q' pero ha fallado el cálculo del informe. No envío cifras dudosas." }
}

# ---------- Telegram ----------
function Send-Tg($token, $chat, $text, $replyTo = $null) {
    foreach ($part in ([regex]::Matches($text, '(?s).{1,3800}(?:\n|$)') | ForEach-Object { $_.Value })) {
        $b = @{ chat_id = $chat; text = $part; disable_web_page_preview = $true }; if ($replyTo) { $b.reply_to_message_id = $replyTo; $b.allow_sending_without_reply = $true }
        try { Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/sendMessage" -Method Post -ContentType "application/json; charset=utf-8" -Body ([Text.Encoding]::UTF8.GetBytes(($b | ConvertTo-Json -Compress))) | Out-Null } catch {}
    }
}
$script:HelpText = @"
🤖 Bot de Alertas Bitunix · comandos
/informe SIMBOLO (o NOMBRE o ISIN) · informe completo de cualquier cripto, acción, ETF, índice, materia prima o divisa (EE. UU. y Europa) (técnico, charting, Fibonacci, Bollinger, TradingView, sentimiento FOMO/FUD, objetivos a 1-3-5 años, insiders, put/call, zonas de volumen, ballenas, derivados, instituciones)
   Ejemplos: /informe BTC · /informe AAPL · /informe SAN.MC · /informe SAP.DE · /informe VWCE.DE · /informe Inditex · /informe ES0148396007 · /informe ^IBEX · /informe GC=F
   Si hay confusión: /informe COIN accion  o  /informe ARB cripto
/precio SIMBOLO · precio rápido
/riesgo PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO · analiza el riesgo/beneficio de tu operación (R:B, acierto mínimo, comisiones, liquidación, estado actual) y su lectura técnica (soportes/resistencias, Fibonacci, TradingView)
   Ejemplo: /riesgo ETH LARGO 2664.24 2638 2723 135 20
/momento SIMBOLO [largo|corto] · ¿es buen momento para abrir una operación en ese activo (acción, ETF, cripto...)? Puntúa largo y corto con reglas fijas y propone un plan orientativo
   Ejemplos: /momento AAPL · /momento BTC · /momento SAN.MC corto
/opinion LARGO|CORTO SIMBOLO [PRECIO] · te doy mi opinión sobre una idea (sin SL, TP ni apalancamiento; no es una alerta). Ej.: /opinion largo BTC 85500 · /opinion corto TSLA 250
/traders [SIMBOLO] · posicionamiento de los mejores traders: BTC y ETH sin argumentos; también cripto o acciones de EE. UU. (ej.: /traders TSLA)
/ballenas [MONEDA] · posiciones de las mayores carteras de Hyperliquid (únicas públicas): cuánto hay en largo y en corto y las mayores posiciones. Ej.: /ballenas BTC
/ayuda · esta ayuda
/id · muestra el identificador del chat

En el grupo escribe / y elige el comando del menú del bot (así Telegram añade el nombre del bot solo).
Qué datos usa: Bitunix, TradingView (lectura pública de su escáner técnico), Binance, Bybit, OKX, Coinbase, Deribit, CoinGecko, Yahoo Finance, SEC EDGAR, CNN y Alternative.me (índices de miedo/codicia). Cada informe cita sus fuentes y dice cuáles respondieron.
Qué hace además: resultados trimestrales, valoración, comunicados de la SEC y de la empresa, noticias y calendario macro. Qué NO hace: valorar si una noticia es buena o mala, resultados fundamentales, recomendaciones de compra o venta. Los objetivos a 3 y 5 años son escenarios matemáticos, no pronósticos. Si no hay dato fiable, lo dice.
"@

# ---------- /riesgo: análisis riesgo/beneficio de una operación con los datos que da el usuario ----------
function Fpx($x) { if ($x -ge 100) { return ("{0:N2}" -f $x) } elseif ($x -ge 1) { return ("{0:N4}" -f $x) } else { return ("{0:G5}" -f $x) } }
function Build-RiskReport($ra) {
    $uso = "Uso: /riesgo PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO`nEjemplo: /riesgo ETH LARGO 2664.24 2638 2723 135 20"
    if ($ra.Count -lt 7) { return $uso }
    $symR = (($ra[0] -replace '[^A-Za-z0-9]', '').ToUpper()) -replace 'USDT$', ''
    $w = $ra[1].ToLower(); $sg = 0
    if ($w -in 'largo', 'long', 'buy', 'compra') { $sg = 1 } elseif ($w -in 'corto', 'short', 'sell', 'venta') { $sg = -1 }
    if ($sg -eq 0) { return "Indica LARGO o CORTO.`n$uso" }
    $nums = @()
    foreach ($i in 2..6) {
        $s1 = (($ra[$i] -replace ',', '.') -replace '[^0-9.]', ''); $dv = 0.0
        if (-not [double]::TryParse($s1, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dv) -or $dv -le 0) { return "No entiendo el valor '$($ra[$i])'.`n$uso" }
        $nums += $dv
    }
    $en = $nums[0]; $sl = $nums[1]; $tp = $nums[2]; $mg = $nums[3]; $lv = $nums[4]
    if ($lv -gt 125) { return "Apalancamiento fuera de rango (máx. 125).`n$uso" }
    if ($sg * ($tp - $en) -le 0) { return "El TP debe estar " + $(if ($sg -eq 1) { "por encima" } else { "por debajo" }) + " de la entrada en una operación " + $(if ($sg -eq 1) { "LARGA" } else { "CORTA" }) + "." }
    if ($sg * ($sl - $en) -ge $sg * ($tp - $en)) { return "El SL queda más allá del TP; revisa los datos.`n$uso" }
    $notional = $mg * $lv; $qty = $notional / $en
    $pSl = $sg * ($sl - $en) * $qty; $pTp = $sg * ($tp - $en) * $qty
    $feeUsd = $notional * 0.001                                        # estimación 0,10% ida y vuelta
    $risk = [Math]::Max(0.0, -$pSl)
    $L = @(); $dirTxt = $(if ($sg -eq 1) { "LARGO" } else { "CORTO" })
    $L += "📐 ANÁLISIS DE RIESGO/BENEFICIO · $symR $dirTxt x$([Math]::Round($lv, 1))"
    $L += ("Entrada {0} · SL {1} · TP {2}" -f (Fpx $en), (Fpx $sl), (Fpx $tp))
    $L += ("Margen {0:N2} USDT · posición {1:N2} USDT · cantidad {2:N4}" -f $mg, $notional, $qty)
    $L += ""
    if ($pSl -lt 0) {
        $mxSl = Get-SlMaxPct; $okSl = if ($risk / $mg * 100 -le $mxSl) { "✅ dentro del {0:N0}% del margen (tu regla)" -f $mxSl } else { "⚠️ supera el {0:N0}% del margen (tu regla)" -f $mxSl }
        $L += ("🛑 Si salta el SL: -{0:N2} USDT = {1:N1}% del margen ({2:N2}% de movimiento). {3}" -f $risk, ($risk / $mg * 100), ([Math]::Abs($sl - $en) / $en * 100), $okSl)
    } else { $L += ("🛑 El SL está en zona de beneficio: si salta, ganas +{0:N2} USDT (+{1:N1}% del margen). Riesgo inicial nulo." -f $pSl, ($pSl / $mg * 100)) }
    $L += ("🎯 Si llega al TP: +{0:N2} USDT = +{1:N1}% del margen ({2:N2}% de movimiento)" -f $pTp, ($pTp / $mg * 100), ([Math]::Abs($tp - $en) / $en * 100))
    if ($risk -gt 0) {
        $rb = $pTp / $risk; $pBe = ($risk + $feeUsd) / ($pTp + $risk) * 100
        $L += ("⚖️ Riesgo/beneficio: 1 : {0:N2} · acierto mínimo para no perder (comisiones incluidas): {1:N0}%" -f $rb, $pBe)
        $L += $(if ($rb -ge 2) { "   Lectura: R:B de 2 o más es una estructura sana." } elseif ($rb -ge 1.5) { "   Lectura: aceptable, pero exige acertar con más frecuencia." } else { "   Lectura: ⚠️ R:B bajo; necesitas acertar mucho para compensar." })
    } else { $L += "⚖️ Riesgo/beneficio: sin riesgo de pérdida con el SL actual (queda el riesgo de ejecución/hueco de precio)." }
    $L += ("💸 Comisiones estimadas (0,10% ida y vuelta; las reales dependen de tu nivel y de usar limit o mercado): {0:N2} USDT = {1:N0}% de la ganancia en TP" -f $feeUsd, ($feeUsd / $pTp * 100))
    $L += ("🔁 SL a breakeven (cubre comisiones): ~{0}" -f (Fpx ($en + $sg * $feeUsd / $qty)))
    if ($lv -gt 1) {
        $liq = $en * (1 - $sg * (1 / $lv - 0.003)); $liqD = [Math]::Abs($en - $liq) / $en * 100
        $slOk = ($sg * ($sl - $liq) -gt 0)
        $L += ("☠️ Liquidación aprox.: {0} ({1:N1}% desde la entrada, margen aislado) · {2}" -f (Fpx $liq), $liqD, $(if ($slOk) { "el SL salta antes ✅" } else { "⚠️ el SL queda DESPUÉS de la liquidación: te liquidarían antes" }))
    }
    $px = $null
    try { $tk = (Invoke-RestMethod "$($script:CmdBase)/tickers?symbols=${symR}USDT" -TimeoutSec 15).data; if ($tk) { $px = [double]@($tk)[0].lastPrice } } catch {}
    if ($px) {
        $unr = $sg * ($px - $en) * $qty; $toTp = $sg * ($tp - $px) * $qty; $toSl = $sg * ($px - $sl) * $qty
        $prog = ($px - $en) / ($tp - $en) * 100
        $L += ""
        $L += ("📍 Ahora (Bitunix {0}): {1} · resultado latente {2:+0.00;-0.00} USDT ({3:+0.0;-0.0}% del margen) · recorrido hacia el TP {4:N0}%" -f "${symR}USDT", (Fpx $px), $unr, ($unr / $mg * 100), $prog)
        if ($toSl -le 0) { $L += "   ⚠️ El precio ya está más allá del SL." }
        elseif ($toTp -le 0) { $L += "   El precio ya alcanzó el TP." }
        else {
            $rr = $toTp / $toSl
            $L += ("   Desde aquí: puedes ganar {0:N2} USDT más o ceder {1:N2} USDT hasta el SL → R:B restante 1 : {2:N2}" -f $toTp, $toSl, $rr)
            if ($rr -lt 1 -and $unr -gt 0) { $L += "   ⚠️ El R:B restante es desfavorable. Valora subir el SL a la entrada o por encima (breakeven arriba) para proteger lo ganado; el coste es que el ruido normal te saque antes." }
        }
    }
    if ($px -and (Get-Command Get-TradeTechNote -ErrorAction SilentlyContinue)) { $L += ""; try { $L += @(Get-TradeTechNote $symR $sg $en $sl $tp) } catch { $L += "🧮 Análisis técnico: no disponible ahora." } }
    $L += ""
    $L += "Gestión del sistema: parcial en TP1 (1R), SL a la entrada tras TP1, resto hacia TP2/TP3. Cálculo matemático con los datos que has dado; la liquidación es aproximada (depende del margen de mantenimiento de Bitunix). No es asesoramiento ni garantía."
    return ($L -join "`n")
}

# ---------- /operacion y /cerrar: registrar o cerrar una operación manual en el seguimiento (solo chat privado) ----------
function Register-ManualFromArgs($ra) {
    $uso = "Uso: /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO`nEjemplo: /operacion ETH LARGO 2664.24 2638 2723 135 20`nTambién vale con etiquetas y en cualquier orden: /operacion FET largo entrada 0,2449 sl 0,2379 tp 0,2534 margen 148,47 x11`nSi ya hay una operación abierta de ese par, solo se actualizan SL y TP."
    if (-not (Get-Command Register-ManualTrade -ErrorAction SilentlyContinue)) { return "El seguimiento de operaciones manuales no está disponible en este entorno." }
    # lectura tolerante: acepta etiquetas (entrada, SL, TP, margen, xN) en cualquier orden y números con coma o punto; sin etiquetas, el orden es ENTRADA SL TP MARGEN APALANCAMIENTO
    $symR = $null; $sg = 0; $slots = @{}; $order = @('en', 'sl', 'tp', 'mg', 'lv'); $pend = $null; $unl = @()
    foreach ($tok in @($ra | ForEach-Object { "$_" })) {
        $t0 = $tok.Trim().ToLower(); if (-not $t0) { continue }
        if ($t0 -in 'largo', 'long', 'compra') { $sg = 1; continue }; if ($t0 -in 'corto', 'short', 'venta') { $sg = -1; continue }
        if ($symR -and $t0 -match '^(sl|stop|stoploss)[:=]?([0-9][0-9.,]*)?$') { if ($Matches[2]) { $t0 = $Matches[2]; $pend = 'sl' } else { $pend = 'sl'; continue } }
        elseif ($symR -and $t0 -match '^(tp|takeprofit|objetivo)[:=]?([0-9][0-9.,]*)?$') { if ($Matches[2]) { $t0 = $Matches[2]; $pend = 'tp' } else { $pend = 'tp'; continue } }
        elseif ($symR -and $t0 -match '^(entrada|entry|precio|en)[:=]?([0-9][0-9.,]*)?$') { if ($Matches[2]) { $t0 = $Matches[2]; $pend = 'en' } else { $pend = 'en'; continue } }
        elseif ($symR -and $t0 -match '^(margen|margin)[:=]?([0-9][0-9.,]*)?$') { if ($Matches[2]) { $t0 = $Matches[2]; $pend = 'mg' } else { $pend = 'mg'; continue } }
        elseif ($symR -and $t0 -match '^(apalancamiento|lev|leverage)[:=]?([0-9][0-9.,]*)?$') { if ($Matches[2]) { $t0 = $Matches[2]; $pend = 'lv' } else { $pend = 'lv'; continue } }
        if ($t0 -in 'usdt', 'aislado', 'isolated', 'cruzado', 'con', 'a', 'de', 'y', 'x') { continue }
        if ($t0 -match '^x(\d+)$' -or $t0 -match '^(\d+)x$') { $slots['lv'] = [double]$Matches[1]; $pend = $null; continue }
        if ($t0 -match '^[0-9][0-9.,]*$') { $s1 = ($t0 -replace ',', '.'); $dv = 0.0; if ([double]::TryParse($s1, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dv) -and $dv -gt 0) { if ($pend) { $slots[$pend] = $dv; $pend = $null } else { $unl += $dv } }; continue }
        if (-not $symR -and $t0 -match '^[a-z0-9]{2,15}$') { $symR = ($t0.ToUpper() -replace 'USDT$', ''); continue }
    }
    foreach ($v in $unl) { foreach ($k in $order) { if (-not $slots.ContainsKey($k)) { $slots[$k] = $v; break } } }
    if (-not $symR) { return $uso }; if ($sg -eq 0) { return "Indica LARGO o CORTO.`n$uso" }
    $faltan = @($order | Where-Object { -not $slots.ContainsKey($_) }); if ($faltan.Count) { $nombres = @{ en = 'ENTRADA'; sl = 'SL'; tp = 'TP'; mg = 'MARGEN'; lv = 'APALANCAMIENTO' }; return ("Me falta: {0}.`n{1}" -f (($faltan | ForEach-Object { $nombres[$_] }) -join ', '), $uso) }
    $en = $slots['en']; $sl = $slots['sl']; $tp = $slots['tp']; $mg = $slots['mg']; $lv = $slots['lv']
    if ($sg * ($tp - $en) -le 0) { return "El TP debe estar " + $(if ($sg -eq 1) { "por encima" } else { "por debajo" }) + " de la entrada." }
    if ($sg * ($sl - $en) -ge $sg * ($tp - $en)) { return "El SL queda más allá del TP; revisa los datos." }
    $ok = $false; try { $ok = [bool](Invoke-RestMethod "$($script:CmdBase)/tickers?symbols=${symR}USDT" -TimeoutSec 15).data } catch {}
    if (-not $ok) { return "No encuentro ${symR}USDT en Bitunix, y el seguimiento usa sus velas. No registro la operación." }
    $chk = ""; try { if (Get-Command Get-RiskCheck -ErrorAction SilentlyContinue) { $chk = "`n`n" + (Get-RiskCheck $symR $sg $en $sl $tp $mg $lv) } } catch {}
    $r = Register-ManualTrade $symR $sg $en $sl $tp $mg $lv
    $live = ""; try { if (Get-Command Add-LiveOrder -ErrorAction SilentlyContinue) { Add-LiveOrder $symR $sg $en $sl $tp $mg $lv "operacion" "Luis"; $live = "`n👁️ La vigilo además EN VIVO (cada ~40 s): te aviso de TP1/TP2/TP final, cercanía al SL y cambios de lectura." } } catch {}
    return ("✅ Operación {0}: {1} {2} x{3:N0} · entrada {4} · SL {5} · TP {6} · margen {7:N2} USDT.`nQueda en el seguimiento: te aviso EN VIVO con el precio y la lectura de 15m, 1h, 4h, 1D, 1S y 1M; el resultado definitivo (SL o TP) se confirma con los máximos y mínimos de las velas de 1h para no perder ningún toque, y saldrá en el informe diario y semanal. Si la cierras a mano, avísame con /cerrar {1} PRECIO." -f $r.action, $symR, $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), $lv, (Fpx $en), (Fpx $sl), (Fpx $tp), $mg) + $live + $chk
}
function Close-ManualFromArgs($ra) {
    $uso = "Uso: /cerrar PAR PRECIO_DE_SALIDA`nEjemplo: /cerrar ETH 2690.5"
    if (-not (Get-Command Close-ManualTrade -ErrorAction SilentlyContinue)) { return "El seguimiento de operaciones manuales no está disponible en este entorno." }
    if ($ra.Count -lt 2) { return $uso }
    $symR = (($ra[0] -replace '[^A-Za-z0-9]', '').ToUpper()) -replace 'USDT$', ''
    $dv = 0.0; if (-not [double]::TryParse((($ra[1] -replace ',', '.') -replace '[^0-9.]', ''), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dv) -or $dv -le 0) { return "No entiendo el precio '$($ra[1])'.`n$uso" }
    $r = Close-ManualTrade $symR $dv
    if (-not $r) { return "No hay ninguna operación manual abierta de ${symR}USDT en el seguimiento." }
    return ("✅ Cerrada {0}: salida {1} · resultado {2:+0.00;-0.00} USDT ({3:+0.0;-0.0}% del margen, comisiones estimadas al 0,10%) · {4:+0.00;-0.00}R." -f $symR, (Fpx $dv), [double]$r.pnlUsd, ([double]$r.pnlUsd / [double]$r.margin * 100), [double]$r.net)
}

function Handle-Commands($token, $allowedChats, $offsetFile) {
    $off = 0; if (Test-Path $offsetFile) { try { $off = [long](Get-Content $offsetFile -Raw).Trim() } catch {} }
    try { $u = Invoke-RestMethod -Uri "https://api.telegram.org/bot$token/getUpdates?offset=$off&timeout=0&allowed_updates=%5B%22message%22%5D" -TimeoutSec 25 } catch { return }
    foreach ($up in $u.result) {
        Set-Content $offsetFile ([string]($up.update_id + 1))
        $m = $up.message; if (-not $m) { continue }
        $chat = "$($m.chat.id)"
        # captura de pantalla (solo chat privado de Luis): el bot lee la posición y la analiza
        if (-not $m.text -and ($m.photo -or ($m.document -and "$($m.document.mime_type)" -like 'image/*'))) {
            if ($chat -notin $allowedChats -or ($script:PrivateChats -and $chat -notin $script:PrivateChats)) { continue }
            if (-not (Get-Command Handle-Screenshot -ErrorAction SilentlyContinue)) { continue }
            Send-Tg $token $chat "⏳ Leyendo la captura y analizando la operación..." $m.message_id
            $rep = try { Handle-Screenshot $token $m $chat } catch { "No he podido analizar la captura: $($_.Exception.Message)" }
            Send-Tg $token $chat $rep $null; continue
        }
        if (-not $m.text) { continue }
        if ($m.text.Trim().ToLower() -match '^/id(@\w+)?$') { Send-Tg $token $chat ("🆔 Identificador de este chat: {0} (tipo: {1}). Si quieres que el bot envíe aquí las señales, díselo a Luis." -f $chat, $m.chat.type) $m.message_id; continue }
        if ($chat -notin $allowedChats) { continue }
        $t = $m.text.Trim()
        if (-not $t.StartsWith("/")) {      # frases libres: solo en el chat privado de Luis; se traducen a /consulta o /ampliar por palabras clave (el bot no es una IA conversacional)
            if (($script:PrivateChats -and $chat -notin $script:PrivateChats) -or -not (Get-Command Handle-FreeText -ErrorAction SilentlyContinue)) { continue }
            $kf = "$chat"; if ($script:LastCmd[$kf] -and ((Get-Date) - $script:LastCmd[$kf]).TotalSeconds -lt 12) { Send-Tg $token $chat "Un momento, voy con una petición cada pocos segundos. Repite en unos segundos." $m.message_id; continue }
            $script:LastCmd[$kf] = Get-Date
            Send-Tg $token $chat "⏳ Un momento, lo miro..." $m.message_id
            $rep = try { Handle-FreeText $t } catch { "No he podido completar la consulta ahora: $($_.Exception.Message)" }
            if ($rep) { Send-Tg $token $chat $rep $null }; continue
        }
        $parts = $t -split '\s+'; $cmd = ($parts[0] -replace '@.*$', '').ToLower(); $args1 = @($parts | Select-Object -Skip 1)
        $key = "$chat"; if ($script:LastCmd[$key] -and ((Get-Date) - $script:LastCmd[$key]).TotalSeconds -lt 12) { Send-Tg $token $chat "Un momento, voy con una petición cada pocos segundos. Repite en unos segundos." $m.message_id; continue }
        $script:LastCmd[$key] = Get-Date
        switch ($cmd) {
            { $_ -in "/ayuda", "/start", "/help" } {
                $h = $script:HelpText; if (-not $script:PrivateChats -or $chat -in $script:PrivateChats) { $h = $h.Replace("/ayuda · esta ayuda", "/resultados · informe diario sencillo (señales + tus operaciones manuales); también llega solo cada día a las 22:00 (hora de España)`n/semanal · informe semanal profundo con análisis de los fallos; también llega solo los domingos a las 22:00`n/operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO · registra una operación tuya en el seguimiento y la pasa por tu control de riesgo (margen, coste del SL, lectura del mercado, reentradas)`n/mercado · prueba en seco del escáner de acciones/ETFs (no envía nada al grupo)`n/cerrar PAR PRECIO · registra el cierre manual de una operación tuya`n/señal tomada [PAR] PRECIO [xAPAL] · me dices que tomaste una señal mía a ese precio: la valoro y la vigilo (cerrar, subir SL/TP, cierre parcial)`n/señal cerrada PAR [PRECIO] · dejo de vigilar esa operación`n/consulta SIMBOLO [largo|corto] · te digo si abrir ahora, esperar o no abrir una cripto de Bitunix, con plan de SL, parciales y apalancamiento (aislado)`n/ampliar PAR [MARGEN_TOTAL] [PRECIO] · calcula el precio medio nuevo y el riesgo si amplías una posición abierta hasta X USDT de margen y si te conviene (ej.: /ampliar FET 200)`nTambién puedes escribirme frases sencillas: «cómo ves SOL», «puedo ampliar FET hasta 200» (no soy una IA: reconozco palabras clave)`n(estos 8 comandos solo funcionan en este chat privado)`n/ayuda · esta ayuda") }
                Send-Tg $token $chat $h $m.message_id
            }
            { $_ -in "/señal", "/senal" } {
                if ($script:PrivateChats -and $chat -notin $script:PrivateChats -and "$chat" -ne "$($script:MktChat)") { Send-Tg $token $chat "Este comando solo está disponible en el chat privado de Luis y en el grupo Alertas Mercados." $m.message_id; break }
                $who = ""; try { $who = "$($m.from.first_name)" } catch {}
                Send-Tg $token $chat (Handle-SenalTomada $args1 $chat $who) $m.message_id
            }
            { $_ -in "/resultados", "/semanal", "/operacion", "/cerrar", "/mercado", "/consulta", "/ampliar" } {
                if ($script:PrivateChats -and $chat -notin $script:PrivateChats) { Send-Tg $token $chat "Este comando solo está disponible en el chat privado de Luis. Aquí puedes usar /informe, /precio y /riesgo." $m.message_id; break }
                switch ($cmd) {
                    "/resultados" { $rep = try { if (Get-Command Get-DailyReport -ErrorAction SilentlyContinue) { Get-DailyReport } else { Get-Report } } catch { "Aún no hay resultados registrados." }; Send-Tg $token $chat $rep $m.message_id }
                    "/semanal" {
                        Send-Tg $token $chat "⏳ Preparando el informe semanal profundo (puede tardar un minuto)..." $m.message_id
                        $rep = try { Get-WeeklyDeepReport } catch { "No he podido generar el informe semanal ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
                    }
                    "/mercado" {
                        if (-not (Get-Command Scan-Market -ErrorAction SilentlyContinue)) { Send-Tg $token $chat "El escáner de mercado no está disponible en este entorno." $m.message_id; break }
                        Send-Tg $token $chat "⏳ Prueba en seco del escáner de mercado (velas diarias, ~350 activos): puede tardar 2-3 minutos. NADA se envía al grupo ni se registra." $m.message_id
                        $script:MktDryOut = @(); $nF = 0; try { $nF = Scan-Market -Dry } catch { Send-Tg $token $chat "Fallo en la prueba: $($_.Exception.Message)" $null }
                        if ($script:MktDryOut.Count -eq 0) { Send-Tg $token $chat "🧪 Ahora mismo ningún activo cumple todas las reglas en la última sesión cerrada (es lo habitual: la táctica es exigente y no fuerza operaciones)." $null }
                        foreach ($d in $script:MktDryOut) { Send-Tg $token $chat ("🧪 PRUEBA (no enviada al grupo)`n`n" + $d[1]) $null }
                    }
                    "/operacion" { Send-Tg $token $chat (Register-ManualFromArgs $args1) $m.message_id }
                    "/cerrar" { Send-Tg $token $chat (Close-ManualFromArgs $args1) $m.message_id }
                    "/ampliar" {
                        Send-Tg $token $chat "⏳ Calculando el precio medio y el riesgo..." $m.message_id
                        $rep = try { Handle-Ampliar $args1 } catch { "No he podido completar el cálculo ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
                    }
                    "/consulta" {
                        Send-Tg $token $chat "⏳ Analizando la cripto (1d, 4h y 1h)..." $m.message_id
                        $rep = try { Handle-Consulta $args1 } catch { "No he podido completar la consulta ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
                    }                }
            }
            "/precio" {
                if (-not $args1) { Send-Tg $token $chat "Uso: /precio SIMBOLO (ej. /precio BTC o /precio AAPL)" $m.message_id; break }
                $rsP = Resolve-SymbolText ($args1 -join ' '); $q = ($rsP.sym -replace '[^A-Za-z0-9.\-\^=]', '').ToUpper(); $out = $null
                try { $tk = (Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq "$($q -replace 'USDT$','')USDT"; if ($tk) { $out = "{0}/USDT: {1} USDT ({2:+0.00;-0.00}% en 24h). Fuente: Bitunix, en vivo." -f ($q -replace 'USDT$',''), (Fnum ([double]$tk.lastPrice)), ((([double]$tk.lastPrice - [double]$tk.open) / [double]$tk.open) * 100) } } catch {}
                if (-not $out) { $y = Get-YahooSeries $q; if ($y) { $out = "{0}: {1} {2}. Fuente: Yahoo Finance ({3}); puede llevar retraso." -f $y.name, (Fnum $y.price), $y.currency, $y.lastDate } }
                if (-not $out) { $out = "No he podido obtener un precio fiable de '$q'. No voy a inventarlo." }
                elseif (Get-Command Resolve-TvTarget -ErrorAction SilentlyContinue) {
                    try { $isBx = $out -like '*Bitunix*'; $tvT = Resolve-TvTarget $(if ($isBx) { 'bitunix' } else { 'yahoo' }) ($q -replace 'USDT$', '') $null; $out += "`n" + ((Get-TvLines $tvT -Short) -join "`n") } catch {}
                }
                if ($rsP.note -and $out -notlike 'No he podido*') { $out = $rsP.note + "`n" + $out }
                Send-Tg $token $chat $out $m.message_id
            }
            "/momento" {
                if (-not $args1) { Send-Tg $token $chat "Uso: /momento SIMBOLO [largo|corto]`nEjemplos: /momento AAPL · /momento BTC · /momento SAN.MC corto`nTe digo, con reglas fijas y visibles, si es buen momento para abrir un largo o un corto en ese activo." $m.message_id; break }
                $mode = ""; $side = ""; $qw = Get-QueryWords $args1 @("largo", "long", "compra", "corto", "short", "venta", "accion", "acción", "bolsa", "stock", "cripto", "crypto")
                foreach ($w1 in $qw.kw) { if ($w1 -in 'largo', 'long', 'compra') { $side = 'largo' } elseif ($w1 -in 'corto', 'short', 'venta') { $side = 'corto' } elseif ($w1 -in 'accion', 'acción', 'bolsa', 'stock') { $mode = 'accion' } elseif ($w1 -in 'cripto', 'crypto') { $mode = 'cripto' } }
                Send-Tg $token $chat "⏳ Analizando el momento de $($qw.text.ToUpper())..." $m.message_id
                $rep = try { Get-MomentoReport $qw.text $mode $side } catch { "No he podido completar el análisis ahora: $($_.Exception.Message)" }
                Send-Tg $token $chat $rep $null
            }
            "/informe" {
                if (-not $args1) { Send-Tg $token $chat "Uso: /informe SIMBOLO (ej. /informe BTC, /informe AAPL, /informe IREN)" $m.message_id; break }
                $qw = Get-QueryWords $args1 @("accion", "acción", "bolsa", "stock", "cripto", "crypto"); $mode = ""; foreach ($w in $qw.kw) { if ($w -in "accion", "acción", "bolsa", "stock") { $mode = "accion" } elseif ($w -in "cripto", "crypto") { $mode = "cripto" } }
                Send-Tg $token $chat "⏳ Preparando el informe de $($qw.text.ToUpper())..." $m.message_id
                Send-Tg $token $chat (Resolve-Report $qw.text $mode) $null
            }
            "/riesgo" { Send-Tg $token $chat (Build-RiskReport $args1) $m.message_id }
            "/opinion" {
                if (-not (Get-Command Handle-Opinion -ErrorAction SilentlyContinue)) { Send-Tg $token $chat "El módulo de opinión no está disponible en este entorno." $m.message_id; break }
                Send-Tg $token $chat "⏳ Valorando la idea (≈30 s)..." $m.message_id
                $rep = try { Handle-Opinion $args1 } catch { "No he podido completar la opinión ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
            }
            "/traders" {
                if (-not (Get-Command Handle-Traders -ErrorAction SilentlyContinue)) { Send-Tg $token $chat "El módulo de mejores traders no está disponible en este entorno." $m.message_id; break }
                Send-Tg $token $chat "⏳ Reuniendo el posicionamiento de los mejores traders (≈30 s)..." $m.message_id
                $rep = try { Handle-Traders $args1 } catch { "No he podido completar la consulta ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
            }
            "/ballenas" {
                if (-not (Get-Command Handle-Ballenas -ErrorAction SilentlyContinue)) { Send-Tg $token $chat "El módulo de ballenas no está disponible en este entorno." $m.message_id; break }
                Send-Tg $token $chat "⏳ Leyendo las posiciones de las mayores carteras de Hyperliquid (≈20 s)..." $m.message_id
                $rep = try { Handle-Ballenas $args1 } catch { "No he podido leer las posiciones ahora: $($_.Exception.Message)" }; Send-Tg $token $chat $rep $null
            }
            default { }
        }
    }
}

if (Test-Path (Join-Path $PSScriptRoot "analisis-tecnico.ps1")) { . (Join-Path $PSScriptRoot "analisis-tecnico.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "momento.ps1")) { . (Join-Path $PSScriptRoot "momento.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "timing-1h.ps1")) { . (Join-Path $PSScriptRoot "timing-1h.ps1") }
if ((Test-Path (Join-Path $PSScriptRoot "avisos-momento.ps1")) -and -not (Get-Command Get-OrderLevels -ErrorAction SilentlyContinue)) { . (Join-Path $PSScriptRoot "avisos-momento.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "consulta.ps1")) { . (Join-Path $PSScriptRoot "consulta.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "ampliar.ps1")) { . (Join-Path $PSScriptRoot "ampliar.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "traduccion.ps1")) { . (Join-Path $PSScriptRoot "traduccion.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "sl-estructura.ps1")) { . (Join-Path $PSScriptRoot "sl-estructura.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "dinero-inteligente.ps1")) { . (Join-Path $PSScriptRoot "dinero-inteligente.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "ballenas.ps1")) { . (Join-Path $PSScriptRoot "ballenas.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "traders.ps1")) { . (Join-Path $PSScriptRoot "traders.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "opinion.ps1")) { . (Join-Path $PSScriptRoot "opinion.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "informes-extra.ps1")) { . (Join-Path $PSScriptRoot "informes-extra.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "senal-compacta.ps1")) { . (Join-Path $PSScriptRoot "senal-compacta.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "control-riesgo.ps1")) { . (Join-Path $PSScriptRoot "control-riesgo.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "senal-tomada.ps1")) { . (Join-Path $PSScriptRoot "senal-tomada.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "ocr.ps1")) { . (Join-Path $PSScriptRoot "ocr.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "captura.ps1")) { . (Join-Path $PSScriptRoot "captura.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "busqueda.ps1")) { . (Join-Path $PSScriptRoot "busqueda.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "noticias.ps1")) { . (Join-Path $PSScriptRoot "noticias.ps1") }
if (Test-Path (Join-Path $PSScriptRoot "fundamentales.ps1")) { . (Join-Path $PSScriptRoot "fundamentales.ps1") }
